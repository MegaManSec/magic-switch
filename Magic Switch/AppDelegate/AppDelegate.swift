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
  private var bluetoothStateObserver: AnyCancellable?
  private var pairingObserver: AnyCancellable?
  private var windowCloseObserver: NSObjectProtocol?
  private var lastBluetoothState: CBManagerState = .unknown
  /// Cached Settings window controller. We host `SettingsView` in a manual
  /// `NSWindow` rather than going through SwiftUI's `Settings` scene because
  /// the scene's `showSettingsWindow:` action silently fails to produce a
  /// visible window in this app (LSUIElement + `.accessory`).
  private var settingsWindowController: NSWindowController?
  /// Set true by `quitFromStatusBar(_:)` immediately before invoking
  /// `terminate(_:)`. `applicationShouldTerminate(_:)` checks this to
  /// distinguish "user picked Quit from our menu-bar menu" (real exit)
  /// from "user pressed Cmd+Q with Settings focused or chose Quit from
  /// the Dock" (just close the window, keep running).
  private var quitFromStatusBarMenu = false
  /// Token for the `.magicSwitchReceivedPing` observer registered in
  /// `setupPingFlashObserver`.
  private var pingObserver: NSObjectProtocol?
  /// Resets the status-bar icon back to its real state after a Ping flash.
  private var pingFlashTimer: DispatchSourceTimer?
  /// Observers for inbound peripheral-handoff posts from `IncomingConnection`.
  private var transferReceiveObserver: NSObjectProtocol?
  private var transferReleaseObserver: NSObjectProtocol?
  /// Direction the status-bar icon should currently advertise. `idle` falls
  /// through to the normal/needs-attention logic in `refreshStatusBarIcon`.
  private enum TransferState {
    case idle
    case sending  // peripherals are leaving this Mac
    case receiving  // peripherals are arriving at this Mac
  }
  private var transferState: TransferState = .idle
  /// Auto-clears the transfer state on the receiver side (the receiver
  /// only knows "I just got CONNECT_ALL"; it doesn't have a clean "all
  /// peripherals settled" signal, so we revert after a fixed window).
  private var transferAutoEndTimer: DispatchSourceTimer?

  // MARK: - Lifecycle Methods

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupNotifications()
    setupBluetooth()
    setupStatusBar()
    setupActivationPolicyTracking()
    setupPingFlashObserver()
    setupTransferObservers()
  }

  /// Fires when the user clicks the Dock icon. If a window is already
  /// visible AppKit will bring it forward (return true). If not, the Dock
  /// icon only exists because Settings was open recently — reopen it,
  /// since that's the only useful action there is for this menu-bar app.
  func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      openSettingsWindow(sender)
      return false
    }
    return true
  }

  /// Decide whether a `terminate(_:)` request should actually exit.
  ///
  /// - Status-bar menu → Quit: real exit (the flag is set in `quitFromStatusBar`).
  /// - System-initiated (logout / shutdown / restart): real exit.
  /// - Anything else (Cmd+Q while Settings focused, right-click Dock → Quit,
  ///   etc.): cancel the terminate, just close Settings and drop the Dock
  ///   icon. This is the "Magic Switch lives in the menu bar; the Dock entry
  ///   is only there while Settings is open" mental model the user wants.
  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    if quitFromStatusBarMenu { return .terminateNow }
    if Self.isSystemInitiatedQuit() { return .terminateNow }
    // Close any visible normal-level windows (the Settings window is the
    // only one this app ever has). The willClose observer in
    // `setupActivationPolicyTracking` will demote the activation policy
    // back to `.accessory` shortly after; setting it here too just makes
    // the Dock-icon disappearance feel immediate.
    for window in NSApp.windows where window.isVisible && window.level == .normal {
      window.close()
    }
    NSApp.setActivationPolicy(.accessory)
    return .terminateCancel
  }

  /// True when the current AppleEvent reason is logout / shutdown / restart.
  /// Without this check we'd block the system from quitting us during
  /// shutdown, which can hang the logout flow.
  private static func isSystemInitiatedQuit() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?
        .enumCodeValue
    else { return false }
    return reason == kAELogOut
      || reason == kAEReallyLogOut
      || reason == kAEShowRestartDialog
      || reason == kAEShowShutdownDialog
      || reason == kAERestart
      || reason == kAEShutDown
  }

  /// Status-bar menu's Quit handler. Sets the "real quit" flag so
  /// `applicationShouldTerminate` lets us exit.
  @objc func quitFromStatusBar(_ sender: Any?) {
    quitFromStatusBarMenu = true
    NSApp.terminate(sender)
  }

  deinit {
    if let token = windowCloseObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = pingObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = transferReceiveObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = transferReleaseObserver {
      NotificationCenter.default.removeObserver(token)
    }
  }

  // MARK: - Setup Methods

  private func setupNotifications() {
    NotificationManager.requestAuthorizationIfNeeded()
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
        body: "Magic Switch can't switch peripherals while Bluetooth is off."
      )
    case .unauthorized:
      NotificationManager.showNotification(
        title: "Bluetooth Permission Needed",
        body: "Grant Bluetooth access in System Settings to use Magic Switch."
      )
    case .unsupported:
      NotificationManager.showNotification(
        title: "Bluetooth Unsupported",
        body: "This Mac does not support the Bluetooth features Magic Switch needs."
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

  /// Updates the menu-bar icon based on transfer state (highest priority),
  /// then Pairing + Bluetooth state. Transfer state shows arrow icons so
  /// the user can tell at a glance that peripherals are moving, and in
  /// which direction. When the app cannot function (unpaired, Bluetooth
  /// off, etc.) we show a triangle exclamation mark instead.
  private func refreshStatusBarIcon() {
    guard let button = statusItem?.button else { return }

    switch transferState {
    case .sending:
      let img = NSImage(
        systemSymbolName: "arrow.up.right.circle.fill",
        accessibilityDescription: "Sending peripherals to the other Mac")
      img?.isTemplate = true
      button.image = img
      button.toolTip = "Sending peripherals to the other Mac…"
      button.setAccessibilityLabel(button.toolTip ?? "")
      return
    case .receiving:
      let img = NSImage(
        systemSymbolName: "arrow.down.left.circle.fill",
        accessibilityDescription: "Receiving peripherals from the other Mac")
      img?.isTemplate = true
      button.image = img
      button.toolTip = "Receiving peripherals from the other Mac…"
      button.setAccessibilityLabel(button.toolTip ?? "")
      return
    case .idle:
      break
    }

    let needsAttention =
      !PairingStore.shared.isPaired
      || (BluetoothManager.shared.state != .poweredOn
        && BluetoothManager.shared.state != .unknown)

    if needsAttention {
      let image = NSImage(
        systemSymbolName: "exclamationmark.triangle.fill",
        accessibilityDescription: "Magic Switch needs attention")
      image?.isTemplate = true
      button.image = image
      button.toolTip = statusBarTooltip()
    } else if let normal = NSImage(named: "StatusBarIcon") {
      normal.size = NSSize(width: 24, height: 24)
      normal.isTemplate = true
      button.image = normal
      button.toolTip = "Magic Switch"
    }
    button.setAccessibilityLabel(statusBarTooltip())
  }

  /// Set the transfer-direction icon for the duration of a transfer.
  /// Sender uses this directly and clears it via `endTransfer()` when the
  /// secure-channel exchange completes (success or failure-with-rollback).
  private func beginTransfer(_ state: TransferState) {
    transferAutoEndTimer?.cancel()
    transferAutoEndTimer = nil
    transferState = state
    refreshStatusBarIcon()
  }

  /// Same as `beginTransfer` but auto-reverts after 5s. Used by the
  /// receiver side, which can't tell when "all peripherals settled."
  private func beginTransferAutoEnd(_ state: TransferState) {
    transferState = state
    refreshStatusBarIcon()
    transferAutoEndTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    timer.schedule(deadline: .now() + 5.0)
    timer.setEventHandler { [weak self] in self?.endTransfer() }
    timer.resume()
    transferAutoEndTimer = timer
  }

  private func endTransfer() {
    transferAutoEndTimer?.cancel()
    transferAutoEndTimer = nil
    transferState = .idle
    refreshStatusBarIcon()
  }

  /// Observes `IncomingConnection`'s transfer-direction posts so the
  /// receiving Mac's status bar reflects what's happening to it.
  private func setupTransferObservers() {
    transferReceiveObserver = NotificationCenter.default.addObserver(
      forName: .magicSwitchReceivedConnectAll, object: nil, queue: .main
    ) { [weak self] _ in
      self?.beginTransferAutoEnd(.receiving)
    }
    transferReleaseObserver = NotificationCenter.default.addObserver(
      forName: .magicSwitchReceivedUnregisterAll, object: nil, queue: .main
    ) { [weak self] _ in
      self?.beginTransferAutoEnd(.sending)
    }
  }

  private func statusBarTooltip() -> String {
    if !PairingStore.shared.isPaired {
      return "Magic Switch: not paired. Open Settings → Pairing."
    }
    switch BluetoothManager.shared.state {
    case .poweredOff:
      return "Magic Switch: Bluetooth is off."
    case .unauthorized:
      return "Magic Switch: Bluetooth permission denied."
    case .unsupported:
      return "Magic Switch: Bluetooth not supported on this Mac."
    case .resetting:
      return "Magic Switch: Bluetooth is resetting."
    case .poweredOn, .unknown:
      return "Magic Switch"
    @unknown default:
      return "Magic Switch"
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
            self?.handleSwitchAction(status: status, device: targetDevice)
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

  private func handleSwitchAction(
    status: BluetoothPeripheralStore.ConnectionStatus,
    device: NetworkDevice
  ) {
    switch status {
    case .allConnected:
      // Show "sending" immediately on the click — feedback before the
      // secure-channel round trip. Preflight the secure channel BEFORE we
      // touch local Bluetooth state. `checkHealth` earlier proved the TCP
      // port is open, but not that the peer's app will accept commands —
      // if the peer's app isn't actually running or the secure channel
      // can't be established, we'd otherwise disconnect locally and then
      // fail to hand peripherals over, leaving them paired nowhere.
      beginTransfer(.sending)
      networkStore.executeCommand(.ping, on: device) { [weak self] preflight in
        guard let self = self else { return }
        switch preflight {
        case .failure(let err):
          self.endTransfer()
          NotificationManager.showNotification(
            title: "Switch Cancelled",
            body:
              "Couldn't reach the other Mac (\(err.userMessage)) — peripherals stay on this Mac.",
            identifier: "switch-preflight-failed"
          )
        case .success:
          self.performHandoffToPeer(device: device)
        }
      }
    case .allDisconnected:
      // Show "receiving" immediately. No preflight needed here:
      // `executeCommand(.unregisterAll)` *is* the preflight — if it fails,
      // nothing has changed locally yet.
      beginTransfer(.receiving)
      networkStore.executeCommand(.unregisterAll, on: device) { [weak self] result in
        guard let self = self else { return }
        switch result {
        case .success:
          self.bluetoothStore.peripherals.forEach { peripheral in
            self.bluetoothStore.connectPeripheral(peripheral)
          }
          self.endTransfer()
        case .failure(let err):
          self.endTransfer()
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
          "Some peripherals are on this Mac, others aren't. Right-click the menu bar icon to switch each peripheral individually, then left-click to handle them all at once.",
        identifier: "switch-mixed-state"
      )
    }
  }

  /// Disconnect peripherals locally then hand them to the peer. Called only
  /// after a successful preflight, but the peer can still die between the
  /// preflight and `CONNECT_ALL` — if it does, re-connect peripherals
  /// locally rather than leave them stranded.
  private func performHandoffToPeer(device: NetworkDevice) {
    bluetoothStore.peripherals.forEach { peripheral in
      bluetoothStore.unregisterFromPC(peripheral)
    }
    waitForDisconnection { [weak self] allDisconnected in
      guard let self = self else { return }
      guard allDisconnected else {
        self.endTransfer()
        NotificationManager.showNotification(
          title: "Switch Failed",
          body: "Couldn't disconnect Bluetooth peripherals from this Mac.",
          identifier: "switch-disconnect-local-failed"
        )
        return
      }
      self.networkStore.executeCommand(.connectAll, on: device) { [weak self] result in
        guard let self = self else { return }
        if case .failure(let err) = result {
          // Rollback: peer didn't take the peripherals, so re-pair them
          // locally. Without this the user is left with peripherals paired
          // nowhere.
          self.bluetoothStore.peripherals.forEach { peripheral in
            self.bluetoothStore.connectPeripheral(peripheral)
          }
          self.endTransfer()
          NotificationManager.showNotification(
            title: "Switch Failed",
            body: "\(err.userMessage) Peripherals reconnected to this Mac.",
            identifier: "switch-connect-failed"
          )
        } else {
          self.endTransfer()
        }
      }
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

    // First check fires immediately — `unregisterFromPC` issues the
    // IOBluetooth disconnect synchronously, so the device is often already
    // disconnected by the time we get here. Falls through to the polled
    // retry loop if not.
    check()
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

  /// Right-click menu's Mac entry. Switches the persisted Settings tab to
  /// Device and opens Settings, so the row has an actual affordance instead
  /// of just being a greyed-out label.
  @objc func handleMacMenuClick(_ sender: NSMenuItem) {
    // Tag matches `SettingsView`'s Device tab — kept in sync via this constant.
    UserDefaults.standard.set(Self.deviceTabIndex, forKey: "settings-selected-tab")
    openSettingsWindow(sender)
  }

  /// Tag of the Device tab in `SettingsView`. Keep in sync if tabs reorder.
  private static let deviceTabIndex = 1

  /// Observes `.magicSwitchReceivedPing` (posted by `IncomingConnection`
  /// when this Mac handles a `.notification` command) and flashes the
  /// status-bar icon. This is the fallback signal for the case where
  /// `UNUserNotificationCenter` silently drops the alert — which it does
  /// reliably on ad-hoc-signed sandboxed builds where notification
  /// authorization can't be granted.
  private func setupPingFlashObserver() {
    pingObserver = NotificationCenter.default.addObserver(
      forName: .magicSwitchReceivedPing,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.flashStatusBarIcon()
    }
  }

  /// Briefly swap the status-bar icon to a "bell" symbol, then restore
  /// the real state via `refreshStatusBarIcon()`. If a subsequent
  /// state-change (pairing flip, Bluetooth state) triggers a refresh
  /// during the flash window, the flash gets cut short — that's fine,
  /// the state change is more important to surface.
  private func flashStatusBarIcon() {
    guard let button = statusItem?.button else { return }
    let flash = NSImage(
      systemSymbolName: "bell.badge.fill",
      accessibilityDescription: "Received a ping from the other Mac"
    )
    flash?.isTemplate = true
    button.image = flash
    pingFlashTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    timer.schedule(deadline: .now() + 3.0)
    timer.setEventHandler { [weak self] in self?.refreshStatusBarIcon() }
    timer.resume()
    pingFlashTimer = timer
  }

  /// AppKit's auto-validation routes through here for menu items targeting
  /// this delegate. Mac entries are enabled only when the peer is currently
  /// reachable on the network (`device.isActive`); everything else passes
  /// through.
  @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(handleMacMenuClick(_:)) {
      guard let id = menuItem.representedObject as? String,
        let device = networkStore.networkDevices.first(where: { $0.id == id })
      else { return false }
      return device.isActive
    }
    return true
  }

  /// Opens the Settings window. We deliberately don't route through the
  /// SwiftUI `Settings { ... }` scene + `sendAction(showSettingsWindow:)`
  /// here — that path produces a Dock icon and an active app but no
  /// visible window on this codebase (LSUIElement + `.accessory` default),
  /// likely because the scene isn't fully wired up when invoked from a
  /// status-menu action handler. We host `SettingsView` in a plain
  /// `NSWindow` instead. Tooltips (`.help(...)`) need the window to be
  /// properly key under `.regular` to fire — hence the policy bump +
  /// `makeKeyAndOrderFront(_:)`.
  @objc func openSettingsWindow(_ sender: Any?) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    if settingsWindowController == nil {
      settingsWindowController = makeSettingsWindowController()
    }
    settingsWindowController?.showWindow(nil)
    settingsWindowController?.window?.makeKeyAndOrderFront(nil)
  }

  private func makeSettingsWindowController() -> NSWindowController {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 600, height: 400)),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.center()
    window.title = "Settings"
    // Keep the window object around after the user closes it so re-opening
    // is just `makeKeyAndOrderFront`, not a full reconstruct.
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: SettingsView())
    return NSWindowController(window: window)
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
