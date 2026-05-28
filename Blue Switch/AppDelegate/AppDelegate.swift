import Cocoa
import Combine
import CoreBluetooth
import SwiftUI

/// Application delegate handling lifecycle and UI setup
final class AppDelegate: NSObject, NSApplicationDelegate {
  // MARK: - Dependencies

  private let networkStore = NetworkDeviceStore.shared
  private let bluetoothStore = BluetoothPeripheralStore.shared

  // MARK: - UI Components

  private var statusItem: NSStatusItem!
  private var settingsWindowController: NSWindowController?
  private var bluetoothStateObserver: AnyCancellable?
  private var pairingObserver: AnyCancellable?
  private var lastBluetoothState: CBManagerState = .unknown

  // MARK: - Constants

  private let windowSize = NSSize(width: 480, height: 300)

  // MARK: - Lifecycle Methods

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupNotifications()
    setupBluetooth()
    setupStatusBar()
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

  @objc func openPreferencesWindow() {
    if settingsWindowController == nil {
      let settingsWindow = createSettingsWindow()
      settingsWindowController = NSWindowController(window: settingsWindow)
    }

    NSApp.activate(ignoringOtherApps: true)
    settingsWindowController?.showWindow(nil)
    settingsWindowController?.window?.orderFrontRegardless()
  }

  private func createSettingsWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: windowSize),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    window.center()
    window.title = "Settings"
    window.contentView = NSHostingView(rootView: SettingsView())

    return window
  }
}
