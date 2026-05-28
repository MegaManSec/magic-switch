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
  }

  private func configureStatusBarButton(_ button: NSStatusBarButton) {
    if let customImage = NSImage(named: "StatusBarIcon") {
      customImage.size = NSSize(width: 24, height: 24)
      customImage.isTemplate = true
      button.image = customImage
    }
    button.target = self
    button.action = #selector(handleClick(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
          self.networkStore.executeCommand(.connectAll) { success in
            if !success {
              NotificationManager.showNotification(
                title: "Error",
                body: "Connection process failed on target device"
              )
            }
          }
        } else {
          NotificationManager.showNotification(
            title: "Error",
            body: "Failed to disconnect devices"
          )
        }
      }
    case .allDisconnected:
      networkStore.executeCommand(.unregisterAll) { [weak self] success in
        guard let self = self else { return }
        if success {
          self.bluetoothStore.peripherals.forEach { peripheral in
            self.bluetoothStore.connectPeripheral(peripheral)
          }
        } else {
          NotificationManager.showNotification(
            title: "Error",
            body: "Failed to request device disconnection from peer"
          )
        }
      }
    case .partial:
      NotificationManager.showNotification(
        title: "Warning",
        body:
          "Some devices are connected while others are disconnected. Please ensure all devices are in the same state."
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
