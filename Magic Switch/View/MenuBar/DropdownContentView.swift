import AppKit
import Combine

/// A native menu item whose action is shared by mouse and keyboard selection.
private final class ActionMenuItem: NSMenuItem {
  var onSelect: () -> Void

  init(title: String, onSelect: @escaping () -> Void) {
    self.onSelect = onSelect
    super.init(title: title, action: #selector(selectItem(_:)), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func selectItem(_ sender: Any?) {
    guard isEnabled else { return }
    onSelect()
  }
}

/// Builds native device rows. Preserve their identity while the menu is open so
/// asynchronous reachability and Bluetooth updates do not reset keyboard focus.
final class DropdownContentView {
  private let networkStore = NetworkDeviceStore.shared
  private let bluetoothStore = BluetoothPeripheralStore.shared
  private let updateChecker = UpdateChecker.shared
  private weak var menu: NSMenu?
  private let onSwitchMac: (NetworkDevice) -> Void
  private var cancellables: Set<AnyCancellable> = []
  private var rows: [(key: String, item: NSMenuItem)] = []
  private var tracking = false
  private var refreshScheduled = false

  init(menu: NSMenu, onSwitchMac: @escaping (NetworkDevice) -> Void) {
    self.menu = menu
    self.onSwitchMac = onSwitchMac
    refreshRows()
    networkStore.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &cancellables)
    bluetoothStore.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &cancellables)
    updateChecker.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &cancellables)
  }

  func menuWillOpen() {
    tracking = false
    refreshRows()
    tracking = true
  }

  func menuDidClose() {
    tracking = false
    scheduleRefresh()
  }

  private func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.refreshScheduled = false
      self.refreshRows()
    }
  }

  private func refreshRows() {
    guard let menu = menu else { return }
    let desired = makeRows()
    if tracking {
      // Defer structural changes until close. Update status in place without
      // removing the highlighted item beneath the keyboard or pointer.
      let byKey = Dictionary(uniqueKeysWithValues: desired.map { ($0.key, $0.item) })
      for row in rows {
        guard let newItem = byKey[row.key] else {
          row.item.isEnabled = false
          continue
        }
        row.item.title = newItem.title
        row.item.image = newItem.image
        row.item.state = newItem.state
        row.item.isEnabled = newItem.isEnabled
        row.item.toolTip = newItem.toolTip
        if let item = row.item as? ActionMenuItem,
          let replacement = newItem as? ActionMenuItem {
          item.onSelect = replacement.onSelect
        }
      }
    } else {
      for row in rows { menu.removeItem(row.item) }
      rows = desired
      for (index, row) in rows.enumerated() { menu.insertItem(row.item, at: index) }
    }
  }

  private func makeRows() -> [(key: String, item: NSMenuItem)] {
    var result: [(key: String, item: NSMenuItem)] = []
    if updateChecker.updateAvailable, let latest = updateChecker.latestVersion {
      let item = ActionMenuItem(title: "Update Available: v\(latest)") {
        if let url = UpdateChecker.shared.releasePageURL { NSWorkspace.shared.open(url) }
      }
      item.image = symbol("arrow.down.circle.fill")
      result.append(("update", item))
      result.append(("update-separator", .separator()))
    }
    if !networkStore.networkDevices.isEmpty {
      result.append(("macs-heading", heading("Macs")))
      for device in networkStore.networkDevices {
        let item = ActionMenuItem(title: device.name) { [weak self] in
          guard let self = self,
            self.networkStore.isSwitchable(device),
            !self.bluetoothStore.isAnyPeripheralTransitioning else { return }
          self.onSwitchMac(device)
        }
        let reachable = networkStore.isSwitchable(device)
        item.isEnabled = reachable && !bluetoothStore.isAnyPeripheralTransitioning
        item.image = symbol("desktopcomputer")
        item.toolTip = reachable
          ? "Switch peripherals between this Mac and \(device.name)."
          : "\(device.name) isn't reachable on the network right now."
        result.append(("mac-\(device.id)", item))
      }
      result.append(("macs-separator", .separator()))
    }
    if !bluetoothStore.peripherals.isEmpty {
      result.append(("peripherals-heading", heading("Peripherals")))
      for peripheral in bluetoothStore.peripherals {
        result.append(("peripheral-\(peripheral.id)", peripheralItem(peripheral)))
      }
    }
    return result
  }

  private func peripheralItem(_ peripheral: BluetoothPeripheral) -> NSMenuItem {
    let state = bluetoothStore.connectionState(for: peripheral.id)
    let canSend = networkStore.networkDevices.contains { networkStore.isSwitchable($0) }
    var title = peripheral.name
    switch state {
    case .connected:
      if let battery = PeripheralBattery.percent(forAddress: peripheral.id) {
        title += " — \(battery)%"
      }
    case .connecting: title += " — Pairing… (Cancel)"
    case .releasing: title += " — Releasing…"
    case .disconnected: break
    }
    if let error = bluetoothStore.peripheralOperationError[peripheral.id] {
      title += " — \(error)"
    }
    let item = ActionMenuItem(title: title) { [weak self] in
      guard let self = self,
        self.bluetoothStore.peripherals.contains(where: { $0.id == peripheral.id }),
        self.bluetoothStore.connectionState(for: peripheral.id) == state else { return }
      switch state {
      case .releasing: return
      case .connecting: self.bluetoothStore.cancelConnect(peripheral)
      case .connected:
        guard self.networkStore.networkDevices.contains(where: {
          self.networkStore.isSwitchable($0)
        }) else { return }
        self.bluetoothStore.switchPeripheral(peripheral, direction: .toggle)
      case .disconnected:
        self.bluetoothStore.switchPeripheral(peripheral, direction: .toggle)
      }
    }
    item.image = symbol(bluetoothStore.peripheralType(for: peripheral).symbolName)
    item.state = state == .connected ? .on : .off
    switch state {
    case .releasing:
      item.isEnabled = false
      item.toolTip = "Releasing \(peripheral.name) to the other Mac…"
    case .connecting:
      item.toolTip = "Pairing \(peripheral.name)… Select to cancel."
    case .connected:
      item.isEnabled = canSend
      item.toolTip = canSend
        ? "On this Mac — select to hand \(peripheral.name) to the other Mac."
        : "On this Mac. No other Mac is reachable to hand it to."
    case .disconnected:
      item.toolTip = canSend
        ? "Select to bring \(peripheral.name) to this Mac."
        : "Select to connect \(peripheral.name) to this Mac over Bluetooth."
    }
    return item
  }

  private func heading(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private func symbol(_ name: String) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    image?.isTemplate = true
    image?.size = NSSize(width: 16, height: 16)
    return image
  }
}
