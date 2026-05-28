import Cocoa
import Combine
import CoreBluetooth

/// Application delegate handling lifecycle and UI setup
final class AppDelegate: NSObject, NSApplicationDelegate {
  // MARK: - Dependencies

  private let networkStore = NetworkDeviceStore.shared
  private let bluetoothStore = BluetoothPeripheralStore.shared

  // MARK: - UI Components

  private var statusItem: NSStatusItem!
  private var bluetoothStateObserver: AnyCancellable?
  private var pairingObserver: AnyCancellable?
  private var windowCloseObserver: NSObjectProtocol?
  private var lastBluetoothState: CBManagerState = .unknown

  // MARK: - Lifecycle Methods

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupNotifications()
    setupBluetooth()
    setupStatusBar()
    setupActivationPolicyTracking()
  }

  deinit {
    if let token = windowCloseObserver {
      NotificationCenter.default.removeObserver(token)
    }
  }

  // MARK: - Setup Methods

  private func setupNotifications() {
    NotificationManager.requestAuthorization()
  }

  private func setupBluetooth() {
    bluetoothStateObserver = BluetoothManager.shared.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        self?.handleBluetoothStateChange(state)
        self?.refreshStatusBarIcon()
      }
    pairingObserver = PairingStore.shared.$isPaired
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.refreshStatusBarIcon()
      }
    BluetoothManager.shared.setup()
  }

  private func handleBluetoothStateChange(_ state: CBManagerState) {
    defer { lastBluetoothState = state }
    // Only notify on transitions into a problematic state, not on every
    // delegate fire (which includes the initial .unknown → .poweredOn).
    guard state != lastBluetoothState else { return }
    switch state {
    case .poweredOff:
      NotificationManager.showNotification(
        title: "Bluetooth Off",
        body: "Blue Switch can't switch peripherals while Bluetooth is off."
      )
    case .unauthorized:
      NotificationManager.showNotification(
        title: "Bluetooth Permission Needed",
        body: "Grant Bluetooth access in System Settings to use Blue Switch."
      )
    case .unsupported:
      NotificationManager.showNotification(
        title: "Bluetooth Unsupported",
        body: "This Mac does not support the Bluetooth features Blue Switch needs."
      )
    case .poweredOn, .resetting, .unknown:
      break
    @unknown default:
      break
    }
  }

  private func setupStatusBar() {
    NSApp.setActivationPolicy(.accessory)

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = statusItem.button else { return }

    configureStatusBarButton(button)
    refreshStatusBarIcon()
  }

  private func configureStatusBarButton(_ button: NSStatusBarButton) {
    button.target = self
    button.action = #selector(handleClick(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
  }

  /// Updates the menu-bar icon based on the combined Pairing + Bluetooth
  /// state. When the app cannot function (unpaired, Bluetooth off, etc.) we
  /// show a triangle exclamation mark instead of the regular icon so the
  /// user can tell at a glance.
  private func refreshStatusBarIcon() {
    guard let button = statusItem?.button else { return }
    let needsAttention =
      !PairingStore.shared.isPaired
      || (BluetoothManager.shared.state != .poweredOn
        && BluetoothManager.shared.state != .unknown)

    if needsAttention {
      let image = NSImage(
        systemSymbolName: "exclamationmark.triangle.fill",
        accessibilityDescription: "Blue Switch needs attention")
      image?.isTemplate = true
      button.image = image
      button.toolTip = statusBarTooltip()
    } else if let normal = NSImage(named: "StatusBarIcon") {
      normal.size = NSSize(width: 24, height: 24)
      normal.isTemplate = true
      button.image = normal
      button.toolTip = "Blue Switch"
    }
    button.setAccessibilityLabel(statusBarTooltip())
  }

  private func statusBarTooltip() -> String {
    if !PairingStore.shared.isPaired {
      return "Blue Switch: not paired. Open Settings → Pairing."
    }
    switch BluetoothManager.shared.state {
    case .poweredOff:
      return "Blue Switch: Bluetooth is off."
    case .unauthorized:
      return "Blue Switch: Bluetooth permission denied."
    case .unsupported:
      return "Blue Switch: Bluetooth not supported on this Mac."
    case .resetting:
      return "Blue Switch: Bluetooth is resetting."
    case .poweredOn, .unknown:
      return "Blue Switch"
    @unknown default:
      return "Blue Switch"
    }
  }

  // MARK: - Action Handlers

  @objc private func handleClick(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }

    switch event.type {
    case .rightMouseUp:
      showMenu()
    case .leftMouseUp:
      handleLeftClick()
    default:
      break
    }
  }

  private func showMenu() {
    MenuBarView().showMenu(statusItem: statusItem)
  }

  private func handleLeftClick() {
    guard let targetDevice = networkStore.networkDevices.first else {
      NotificationManager.showNotification(
        title: "Error",
        body: "No devices connected. Please connect a device first."
      )
      return
    }

    targetDevice.checkHealth { [weak self] result in
      // `checkHealth` fires on its own queue. Hop to main before any UI or
      // store mutations, and before calling `checkActualConnectionStatusAsync`
      // (which expects to be invoked from main).
      DispatchQueue.main.async {
        guard let self = self else { return }
        switch result {
        case .success:
          self.bluetoothStore.checkActualConnectionStatusAsync { [weak self] status in
            self?.handleSwitchAction(status: status)
          }
        case .failure(let error):
          NotificationManager.showNotification(
            title: "Error",
            body: "Failed to communicate with device: \(error)"
          )
        case .timeout:
          NotificationManager.showNotification(
            title: "Error",
            body: "No response from device. Please check if the app is running."
          )
        }
      }
    }
  }

  private func handleSwitchAction(status: BluetoothPeripheralStore.ConnectionStatus) {
    switch status {
    case .allConnected:
      bluetoothStore.peripherals.forEach { peripheral in
        bluetoothStore.unregisterFromPC(peripheral)
      }
      waitForDisconnection { [weak self] allDisconnected in
        guard let self = self else { return }
        if allDisconnected {
          self.networkStore.executeCommand(.connectAll) { result in
            if case .failure(let err) = result {
              NotificationManager.showNotification(
                title: "Switch Failed",
                body: err.userMessage,
                identifier: "switch-connect-failed"
              )
            }
          }
        } else {
          NotificationManager.showNotification(
            title: "Switch Failed",
            body: "Couldn't disconnect Bluetooth peripherals from this Mac.",
            identifier: "switch-disconnect-local-failed"
          )
        }
      }
    case .allDisconnected:
      networkStore.executeCommand(.unregisterAll) { [weak self] result in
        guard let self = self else { return }
        switch result {
        case .success:
          self.bluetoothStore.peripherals.forEach { peripheral in
            self.bluetoothStore.connectPeripheral(peripheral)
          }
        case .failure(let err):
          NotificationManager.showNotification(
            title: "Switch Failed",
            body: err.userMessage,
            identifier: "switch-disconnect-remote-failed"
          )
        }
      }
    case .partial:
      NotificationManager.showNotification(
        title: "Peripherals in mixed state",
        body:
          "Some peripherals are connected to this Mac and others aren't. Open Settings → Peripheral and either connect or remove each one so they're all in the same state, then click the menu bar icon again.",
        identifier: "switch-mixed-state"
      )
    }
  }

  /// Waits for all devices to disconnect with a timeout
  /// - Parameter completion: Called with true if all devices disconnected, false if timeout occurred
  private func waitForDisconnection(completion: @escaping (Bool) -> Void) {
    var attempts = 0
    let maxAttempts = 5

    func check() {
      attempts += 1
      bluetoothStore.checkActualConnectionStatusAsync { status in
        if status == .allDisconnected {
          completion(true)
        } else if attempts < maxAttempts {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            check()
          }
        } else {
          completion(false)
        }
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      check()
    }
  }

  // MARK: - Settings Management

  /// Right-click menu's per-peripheral switch. `representedObject` carries
  /// the peripheral's MAC; we dispatch based on the current local
  /// connection state — if it's here, send it to the peer; if it's
  /// elsewhere, ask the peer to release it.
  @objc func handlePeripheralMenuClick(_ sender: NSMenuItem) {
    guard let address = sender.representedObject as? String else { return }
    let store = bluetoothStore
    guard let peripheral = store.peripherals.first(where: { $0.id == address }) else { return }
    switch store.connectionState(for: address) {
    case .connected:
      store.sendPeripheralToPeer(peripheral)
    case .disconnected:
      store.takePeripheralFromPeer(peripheral)
    case .connecting:
      break
    }
  }

  /// Open the SwiftUI `Settings` scene declared in `Blue_SwitchApp`. The
  /// previous code hosted `SettingsView` inside a manually-built `NSWindow`,
  /// which suppresses SwiftUI `.help(...)` tooltips; routing through the
  /// `Settings` scene fixes that.
  ///
  /// Bumps the activation policy to `.regular` so a Dock icon shows while
  /// Settings is visible — the close observer set up in
  /// `setupActivationPolicyTracking` flips it back to `.accessory`.
  @objc func openSettingsWindow(_ sender: Any?) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    // macOS 13 renamed the standard selector; fall back for older releases.
    let modern = Selector(("showSettingsWindow:"))
    let legacy = Selector(("showPreferencesWindow:"))
    if !NSApp.sendAction(modern, to: nil, from: nil) {
      NSApp.sendAction(legacy, to: nil, from: nil)
    }
  }

  /// Drops the app back to `.accessory` (no Dock icon) once the last normal
  /// window closes. SwiftUI's `Settings` scene typically reuses one window,
  /// but the loop is defensive against any other normal-level window we
  /// might open in the future.
  private func setupActivationPolicyTracking() {
    windowCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      // Only react when a normal-level window closes. The right-click
      // NSMenu fires willClose as soon as the user picks Settings —
      // reacting to that races against the Settings window actually
      // appearing (we'd flip back to .accessory before SwiftUI has put
      // the window on screen, killing the open). Status-item windows
      // and popovers live at non-`.normal` levels and would hit the
      // same race.
      guard let window = notification.object as? NSWindow,
        window.level == .normal
      else { return }
      // `willClose` fires while the closing window is still flagged visible;
      // defer one runloop tick so the count reflects the post-close state.
      DispatchQueue.main.async {
        guard self != nil else { return }
        let openWindows = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
        if openWindows.isEmpty {
          NSApp.setActivationPolicy(.accessory)
        }
      }
    }
  }
}
