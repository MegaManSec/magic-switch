import AppKit
import Combine

/// A clickable row inside the status-bar dropdown. The key trick: `mouseDown`
/// runs the action then *consumes the mouse-up* off the window queue, so the
/// tracked `NSMenu` never sees a selection and doesn't dismiss — that's what
/// lets the dropdown stay open while a peripheral pairs. Disabled rows ignore
/// clicks (used for an unreachable Mac). Adapted from `TapControl` in the
/// wiz-light-controller reference.
final class MenuRowControl: NSControl {
  private let onClick: () -> Void
  private var hoverArea: NSTrackingArea?

  init(onClick: @escaping () -> Void) {
    self.onClick = onClick
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 5
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// Route every click in the row to `onClick`, ignoring the visual subviews.
  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(convert(point, from: superview)) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled, let window = window else { return }
    // Act on mouse-*up*, not mouse-down: track the press and fire only if the
    // pointer is still inside the row when the button is released — a press that
    // drags off cancels, like a standard button. Pulling the events off the
    // window queue also swallows the mouse-up so the tracked NSMenu never treats
    // the tap as a selection and stays open.
    setHighlighted(true)
    var inside = true
    while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
      inside = bounds.contains(convert(next.locationInWindow, from: nil))
      if next.type == .leftMouseUp { break }
      setHighlighted(inside)
    }
    setHighlighted(false)
    if inside { onClick() }
  }

  // MARK: - Hover highlight

  /// `.activeAlways` so the highlight tracks even though a menu window isn't
  /// key; `.inVisibleRect` keeps the area sized to the row across rebuilds.
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil)
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    guard isEnabled else { return }
    setHighlighted(true)
  }

  override func mouseExited(with event: NSEvent) {
    setHighlighted(false)
  }

  private func setHighlighted(_ on: Bool) {
    layer?.backgroundColor = on ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
  }
}

/// The status-bar dropdown's content, in AppKit so it can live inside a tracked
/// `NSMenu` — the only surface that keeps the macOS menu bar revealed over a
/// full-screen Space and never activates the app (a popover does neither), and
/// SwiftUI controls don't track inside a menu. Mirrors the old `MenuBarView`
/// NSMenu — optional update row, Macs, Peripherals, Settings, Quit — but the
/// rows are live (it observes the stores) and a peripheral tap keeps the menu
/// open so progress ("Pairing…") and errors show inline. Pattern adapted from
/// wiz-light-controller's `DropdownContentView`.
final class DropdownContentView: NSView {
  // MARK: - Dependencies

  private let networkStore = NetworkDeviceStore.shared
  private let bluetoothStore = BluetoothPeripheralStore.shared
  private let updateChecker = UpdateChecker.shared

  private let onSwitchMac: (NetworkDevice) -> Void
  private let onOpenSettings: () -> Void
  private let onQuit: () -> Void

  private let stack = NSStackView()
  private var cancellables: Set<AnyCancellable> = []
  private var syncScheduled = false

  private static let panelWidth: CGFloat = 260
  private static let inset: CGFloat = 12
  private static let contentWidth: CGFloat = panelWidth - inset * 2

  init(
    onSwitchMac: @escaping (NetworkDevice) -> Void,
    onOpenSettings: @escaping () -> Void,
    onQuit: @escaping () -> Void
  ) {
    self.onSwitchMac = onSwitchMac
    self.onOpenSettings = onOpenSettings
    self.onQuit = onQuit
    super.init(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 80))

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 3, left: Self.inset, bottom: 2, right: Self.inset)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    rebuild()

    // Live updates: rebuild when any source store changes. Menu tracking drains
    // the main queue, so these fire and re-render even while the dropdown is open.
    networkStore.objectWillChange
      .sink { [weak self] _ in self?.scheduleSync() }.store(in: &cancellables)
    bluetoothStore.objectWillChange
      .sink { [weak self] _ in self?.scheduleSync() }.store(in: &cancellables)
    updateChecker.objectWillChange
      .sink { [weak self] _ in self?.scheduleSync() }.store(in: &cancellables)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  // MARK: - Live updates

  /// Coalesce a burst of `objectWillChange` into one rebuild on the next tick —
  /// which also lands *after* the publishers commit, so we read fresh values.
  private func scheduleSync() {
    guard !syncScheduled else { return }
    syncScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.syncScheduled = false
      self.rebuild()
    }
  }

  // MARK: - Build

  private func rebuild() {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    if updateChecker.updateAvailable, let latest = updateChecker.latestVersion {
      stack.addArrangedSubview(makeUpdateRow(latest))
      stack.addArrangedSubview(makeDivider())
    }

    let macs = networkStore.networkDevices
    if !macs.isEmpty {
      stack.addArrangedSubview(makeSectionHeader("Macs"))
      for device in macs { stack.addArrangedSubview(makeMacRow(device)) }
      stack.addArrangedSubview(makeDivider())
    }

    let peripherals = bluetoothStore.peripherals
    if !peripherals.isEmpty {
      stack.addArrangedSubview(makeSectionHeader("Peripherals"))
      var previousRow: NSView?
      for peripheral in peripherals {
        let row = makePeripheralRow(peripheral)
        stack.addArrangedSubview(row)
        // Sit consecutive peripherals flush (0 gap) against each other; the
        // section's normal spacing still applies after the header and before
        // the divider below.
        if let previousRow { stack.setCustomSpacing(0, after: previousRow) }
        previousRow = row
      }
      stack.addArrangedSubview(makeDivider())
    }

    // A hair more space above the Settings row than the default inter-row gap.
    if let last = stack.arrangedSubviews.last {
      stack.setCustomSpacing(stack.spacing + 1, after: last)
    }
    let settingsRow = makeActionRow(title: "Settings…") { [weak self] in
      self?.dismissThen { self?.onOpenSettings() }
    }
    stack.addArrangedSubview(settingsRow)
    // Sit Quit flush against Settings, like consecutive peripheral rows.
    stack.setCustomSpacing(0, after: settingsRow)
    stack.addArrangedSubview(
      makeActionRow(title: "Quit") { [weak self] in
        self?.dismissThen { self?.onQuit() }
      })

    updateFrameToFit()
  }

  /// Resize to fit the current content at the fixed width, so the menu measures
  /// the right item size (it changes as peripherals pair / errors appear). Width
  /// is pinned, not taken from `fittingSize`, because AppKit reports widths lazily.
  func updateFrameToFit() {
    setFrameSize(NSSize(width: Self.panelWidth, height: max(1, fittingSize.height)))
    layoutSubtreeIfNeeded()
    setFrameSize(NSSize(width: Self.panelWidth, height: max(1, fittingSize.height)))
    invalidateIntrinsicContentSize()
  }

  /// Close the tracked menu, then run `action` on the next tick — after the
  /// menu's modal tracking loop has ended, so activating a window (Settings) or
  /// terminating behaves. Switch rows skip this so the menu stays open.
  private func dismissThen(_ action: @escaping () -> Void) {
    enclosingMenuItem?.menu?.cancelTracking()
    DispatchQueue.main.async(execute: action)
  }

  // MARK: - Rows

  private func makeSectionHeader(_ title: String) -> NSView {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 10, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    // A little space above the header so it's clear of the section before it,
    // and flush below so it groups with its own rows underneath.
    let container = NSView()
    container.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      label.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
      label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return fullWidth(container)
  }

  private func makeDivider() -> NSView {
    let box = NSBox()
    box.boxType = .separator
    return fullWidth(box)
  }

  private func makeMacRow(_ device: NetworkDevice) -> NSView {
    let switchable = networkStore.isSwitchable(device)
    let row = MenuRowControl { [weak self] in self?.onSwitchMac(device) }
    row.isEnabled = switchable

    let color: NSColor = switchable ? .labelColor : .tertiaryLabelColor
    let content = NSStackView()
    content.orientation = .horizontal
    content.distribution = .fill
    content.spacing = 8
    content.alignment = .centerY
    content.addArrangedSubview(symbolView("desktopcomputer", color: color))
    content.addArrangedSubview(textLabel(device.name, color: color))
    content.addArrangedSubview(spacer())

    row.toolTip =
      switchable
      ? "Switch peripherals between this Mac and \(device.name)."
      : "\(device.name) isn't reachable on the network right now."
    return clickableRow(row, content: content)
  }

  private func makePeripheralRow(_ peripheral: BluetoothPeripheral) -> NSView {
    let state = bluetoothStore.connectionState(for: peripheral.id)
    let canSwitch = networkStore.networkDevices.contains { networkStore.isSwitchable($0) }
    let row = MenuRowControl { [weak self] in self?.togglePeripheral(peripheral) }
    // A disconnected peripheral is always clickable — take it (locally over
    // Bluetooth if there's no peer to ask). A connected one can only be *sent*,
    // so it greys out when no Mac is reachable to hand it to. A pairing row is
    // disabled while in flight.
    let enabled: Bool
    switch state {
    case .connecting, .releasing: enabled = false
    case .connected: enabled = canSwitch
    case .disconnected: enabled = true
    }
    row.isEnabled = enabled
    // Dim only the "nowhere to send it" case; a pairing row keeps its normal
    // colour alongside the "Pairing…" label.
    let dimmed = state == .connected && !canSwitch
    let textColor: NSColor = dimmed ? .tertiaryLabelColor : .labelColor

    let top = NSStackView()
    top.orientation = .horizontal
    top.distribution = .fill
    top.spacing = 8
    top.alignment = .centerY
    top.addArrangedSubview(
      symbolView(bluetoothStore.peripheralType(for: peripheral).symbolName, color: textColor))
    top.addArrangedSubview(textLabel(peripheral.name, color: textColor))
    top.addArrangedSubview(spacer())
    switch state {
    case .connected:
      top.addArrangedSubview(symbolView("checkmark", color: .controlAccentColor))
    case .connecting:
      top.addArrangedSubview(caption("Pairing…", color: .secondaryLabelColor))
    case .releasing:
      top.addArrangedSubview(caption("Releasing…", color: .secondaryLabelColor))
    case .disconnected:
      break
    }

    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 2
    column.addArrangedSubview(top)
    top.translatesAutoresizingMaskIntoConstraints = false
    top.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    if let error = bluetoothStore.peripheralOperationError[peripheral.id] {
      // Wrapping label pinned to the column width, so it wraps (instead of
      // truncating) without depending on a hand-computed max-layout width.
      let errorLabel = NSTextField(wrappingLabelWithString: error)
      errorLabel.font = .systemFont(ofSize: 11)
      errorLabel.textColor = .systemRed
      errorLabel.translatesAutoresizingMaskIntoConstraints = false
      column.addArrangedSubview(errorLabel)
      errorLabel.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    switch state {
    case .connecting:
      row.toolTip = "Pairing \(peripheral.name)…"
    case .releasing:
      row.toolTip = "Releasing \(peripheral.name) to the other Mac…"
    case .connected:
      row.toolTip =
        canSwitch
        ? "On this Mac — click to hand \(peripheral.name) to the other Mac."
        : "On this Mac. No other Mac is reachable to hand it to."
    case .disconnected:
      row.toolTip =
        canSwitch
        ? "Click to bring \(peripheral.name) to this Mac."
        : "Click to connect \(peripheral.name) to this Mac over Bluetooth."
    }
    return clickableRow(row, content: column)
  }

  private func makeActionRow(
    title: String, onClick: @escaping () -> Void
  ) -> NSView {
    let row = MenuRowControl(onClick: onClick)
    let content = NSStackView()
    content.orientation = .horizontal
    content.distribution = .fill
    content.spacing = 8
    content.alignment = .centerY
    content.addArrangedSubview(textLabel(title, color: .labelColor))
    content.addArrangedSubview(spacer())
    return clickableRow(row, content: content)
  }

  private func makeUpdateRow(_ latest: String) -> NSView {
    let row = MenuRowControl { [weak self] in
      self?.dismissThen {
        if let url = UpdateChecker.shared.releasePageURL { NSWorkspace.shared.open(url) }
      }
    }
    let content = NSStackView()
    content.orientation = .horizontal
    content.distribution = .fill
    content.spacing = 8
    content.alignment = .centerY
    content.addArrangedSubview(symbolView("arrow.down.circle.fill", color: .controlAccentColor))
    content.addArrangedSubview(textLabel("Update Available: v\(latest)", color: .labelColor))
    content.addArrangedSubview(spacer())
    row.toolTip = "A newer version of Magic Switch is available. Opens the release page."
    return clickableRow(row, content: content)
  }

  // MARK: - Actions

  private func togglePeripheral(_ peripheral: BluetoothPeripheral) {
    let canSwitch = networkStore.networkDevices.contains { networkStore.isSwitchable($0) }
    switch bluetoothStore.connectionState(for: peripheral.id) {
    case .connected:
      bluetoothStore.sendPeripheralToPeer(peripheral)
    case .disconnected:
      if canSwitch {
        bluetoothStore.takePeripheralFromPeer(peripheral)
      } else {
        // No peer to ask — pair it to this Mac directly over Bluetooth.
        bluetoothStore.connectPeripheral(peripheral)
      }
    case .connecting, .releasing:
      break  // handoff in flight
    }
  }

  // MARK: - Building blocks

  /// Pin a row to the fixed content width so every row lines up under the insets.
  private func fullWidth(_ view: NSView) -> NSView {
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
    return view
  }

  /// Drop `content` inside a clickable row with a little vertical padding.
  private func clickableRow(_ control: MenuRowControl, content: NSView) -> NSView {
    content.translatesAutoresizingMaskIntoConstraints = false
    control.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: 6),
      content.trailingAnchor.constraint(equalTo: control.trailingAnchor, constant: -6),
      content.topAnchor.constraint(equalTo: control.topAnchor, constant: 4),
      content.bottomAnchor.constraint(equalTo: control.bottomAnchor, constant: -4),
    ])
    return fullWidth(control)
  }

  private func symbolView(_ name: String, color: NSColor) -> NSImageView {
    let view = NSImageView()
    view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    view.contentTintColor = color
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: 18).isActive = true
    view.setContentHuggingPriority(.required, for: .horizontal)
    return view
  }

  private func textLabel(_ string: String, color: NSColor) -> NSTextField {
    let label = NSTextField(labelWithString: string)
    label.font = .systemFont(ofSize: 13)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  private func caption(_ string: String, color: NSColor) -> NSTextField {
    let label = NSTextField(labelWithString: string)
    label.font = .systemFont(ofSize: 11)
    label.textColor = color
    return label
  }

  /// A flexible spacer that pushes trailing accessories to the right edge.
  private func spacer() -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    return view
  }
}
