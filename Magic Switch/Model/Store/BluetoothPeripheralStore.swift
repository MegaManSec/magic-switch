import Foundation
import IOBluetooth
import SwiftUI

/// Protocol defining the interface for Bluetooth peripheral management operations
protocol BluetoothPeripheralManageable {
  /// Fetches and updates the list of connected peripherals
  func fetchConnectedPeripherals()

  /// Adds a new peripheral to the managed list
  func addPeripheral(_ peripheral: BluetoothPeripheral)

  /// Initiates connection to a peripheral
  func connectPeripheral(_ peripheral: BluetoothPeripheral)

  /// Disconnects from a peripheral
  func disconnectPeripheral(_ peripheral: BluetoothPeripheral)
}

/// Manages the state and operations of Bluetooth peripherals
final class BluetoothPeripheralStore: NSObject, ObservableObject, BluetoothPeripheralManageable {
  // MARK: - Singleton

  static let shared = BluetoothPeripheralStore()

  // MARK: - Constants

  private enum Constants {
    static let queueLabel = "com.magicswitch.bluetooth"
    static let invalidRSSI = 127
    /// Upper bound on how long `connectPeripheral` will leave the UI showing
    /// "Pairing…" before giving up. Magic peripherals typically pair within
    /// a couple of seconds; if the device is currently held by the other
    /// Mac, `IOBluetoothDevicePair.start()` has no built-in timeout and the
    /// state would otherwise stick forever. 60s is generous — first-time
    /// cross-Mac handoffs (peripheral arbitrating between recently-seen
    /// hosts) can legitimately take 30-45s, and a false-positive timeout
    /// is worse than waiting a beat longer.
    static let pairTimeout: TimeInterval = 60
    /// How long after wake to wait before deciding whether the peer holds a
    /// peripheral we released for sleep. Gives Wi-Fi time to reassociate so a
    /// peer that's actively using the peripheral doesn't look unreachable and
    /// get it yanked back.
    static let wakeReclaimDelay: TimeInterval = 5
    /// How often the auto-reconnect watcher probes a dropped peripheral to
    /// see whether it's back in range. The probe is just an RSSI read while
    /// the device is absent, so a short interval is cheap; it also bounds the
    /// worst-case latency between a peripheral reappearing and us reclaiming
    /// it.
    static let reconnectProbeInterval: TimeInterval = 15
    /// Upper bound on how long the watcher keeps trying to reclaim one
    /// peripheral before giving up. Generous on purpose — a stuck Magic
    /// device may not come back until the user notices and power-cycles it,
    /// which can be a while. Probes cost almost nothing while it's absent,
    /// and a fresh drop or wake re-arms it, so a long window is safe.
    static let reconnectMaxWindow: TimeInterval = 3600
  }

  // MARK: - Dependencies

  private let bluetoothQueue = DispatchQueue(label: Constants.queueLabel, qos: .userInitiated)

  /// Releases held peripherals just before this Mac sleeps. A sleeping Mac
  /// can't be asked to release over the network, so we hand them off *before*
  /// becoming unreachable.
  private let sleepMonitor = SleepMonitor()

  // MARK: - Properties

  /// `@AppStorage` key for the "release peripherals when this Mac sleeps"
  /// preference. Referenced by the Other settings tab's toggle too, so it
  /// lives here as the single source of truth for the key string.
  static let releaseOnSleepDefaultsKey = "releaseHeldPeripheralsOnSleep"

  /// `@AppStorage` key for the "keep trying to reconnect dropped peripherals"
  /// preference. Also bound by the Other settings tab, so the key string
  /// lives here as the single source of truth.
  static let autoReconnectDefaultsKey = "autoReconnectDroppedPeripherals"

  @AppStorage("peripherals") private var peripheralsData: Data = Data()

  /// When set (default), `prepareForSleep` releases held peripherals on
  /// system sleep. Off lets a user keep a peripheral bonded to a Mac that
  /// sleeps (the watcher still reclaims it on wake if it doesn't reconnect).
  @AppStorage(BluetoothPeripheralStore.releaseOnSleepDefaultsKey)
  private var releaseOnSleep: Bool = true

  /// When set (default), a peripheral that drops while it should be on this
  /// Mac is retried by the auto-reconnect watcher until it's back in range
  /// and the peer isn't using it, or the `reconnectMaxWindow` expires. Off
  /// disables the watcher entirely. Read at use-time (no observation needed):
  /// `armReconnect` refuses when off and `reconnectTick` tears itself down.
  @AppStorage(BluetoothPeripheralStore.autoReconnectDefaultsKey)
  private var autoReconnect: Bool = true

  @Published private(set) var peripherals: [BluetoothPeripheral] = [] {
    didSet {
      savePeripherals()
    }
  }

  @Published private(set) var discoveredPeripherals: [BluetoothPeripheral] = []

  /// Runtime connection state per peripheral id. Driven by pair completion and
  /// IOBluetooth disconnect notifications.
  @Published private(set) var connectionStates: [String: PeripheralConnectionState] = [:]

  /// In-flight `IOBluetoothDevicePair` instances, kept alive until
  /// `devicePairingFinished` fires. Without this, ARC frees the pair mid-op and
  /// macOS aborts pairing, dropping the peripheral seconds after it connects.
  private var pendingPairs: [String: IOBluetoothDevicePair] = [:]

  /// Disconnect notification observers, keyed by peripheral id.
  private var disconnectObservers: [String: IOBluetoothUserNotification] = [:]

  /// Watchdog timers for in-flight pair attempts, keyed by peripheral id.
  /// If the pair callback hasn't fired by `Constants.pairTimeout`, the
  /// timer flips the peripheral back to `.disconnected` so the UI unsticks.
  private var pairTimers: [String: DispatchSourceTimer] = [:]

  /// MAC addresses we unpaired in `prepareForSleep` on the last sleep (the
  /// release-on-sleep subset). On wake, when auto-reconnect is off, we do the
  /// original one-shot reclaim for just these. The process stays alive across
  /// sleep, so an in-memory set is enough.
  private var peripheralsReleasedForSleep: Set<String> = []

  /// MAC addresses that were *connected to this Mac* immediately before the
  /// last sleep — a superset of `peripheralsReleasedForSleep` that also
  /// includes peripherals we left bonded because there was no peer to hand
  /// them to. On wake the watcher tries to reclaim any that didn't come back
  /// on their own, so "whatever I was using before I closed the lid" returns
  /// even when nothing was handed off. Only consulted when auto-reconnect is
  /// on.
  private var connectedBeforeSleep: Set<String> = []

  /// Global IOBluetooth connect observer. Fires for *any* device the OS
  /// pairs/connects, including ones the user connects via the system
  /// Bluetooth menu (not via Magic Switch). Used to keep the Peripheral tab
  /// live without polling.
  private var globalConnectObserver: IOBluetoothUserNotification?

  /// Peripherals the auto-reconnect watcher is trying to reclaim, keyed by
  /// id, with the time each was armed (for the `reconnectMaxWindow` bound).
  /// Main-only.
  private var reconnectWatchlist: [String: Date] = [:]

  /// Ids with a probe/reclaim chain in flight, so overlapping ticks don't
  /// fire a second `HOLDS_ONE` or pair attempt for the same peripheral while
  /// the first is still resolving. Main-only.
  private var reconnectInFlight: Set<String> = []

  /// Ids we released on purpose (handoff, "Remove from PC", sleep). The
  /// disconnect notification that follows must not arm the watcher — the
  /// peripheral is meant to leave this Mac. Consumed by
  /// `handlePeripheralDisconnected`. Main-only.
  private var intentionalReleases: Set<String> = []

  /// Repeating probe timer; runs only while `reconnectWatchlist` is non-empty.
  private var reconnectTimer: DispatchSourceTimer?

  /// Per-address flag: should a pair-watchdog timeout surface a user
  /// notification? True for interactive connects, false for watcher retries
  /// (which would otherwise spam "Pairing Timed Out" while a device is stuck).
  private var pairTimeoutShouldAnnounce: [String: Bool] = [:]

  // MARK: - Computed Properties

  var availablePeripherals: [BluetoothPeripheral] {
    discoveredPeripherals.filter { discovered in
      !peripherals.contains(where: { $0.id == discovered.id })
    }
  }

  func connectionState(for peripheralID: String) -> PeripheralConnectionState {
    connectionStates[peripheralID] ?? .disconnected
  }

  // MARK: - Initialization

  private override init() {
    super.init()
    loadPeripherals()
    fetchConnectedPeripherals()
    registerForSystemBluetoothConnects()
    setupSleepRelease()
  }

  /// Wire the sleep/wake hooks: snapshot (and, when configured, release) held
  /// peripherals just before sleep, and reclaim them on wake.
  private func setupSleepRelease() {
    sleepMonitor.onWillSleep = { [weak self] in
      self?.prepareForSleep()
    }
    sleepMonitor.onDidWake = { [weak self] in
      self?.reclaimPeripheralsAfterWake()
    }
    sleepMonitor.start()
  }

  /// Runs (on main) from `SleepMonitor` immediately before sleep, with the
  /// power transition held until it returns. Two jobs:
  ///
  /// 1. Snapshot the registered peripherals currently connected to this Mac
  ///    into `connectedBeforeSleep`, so `reclaimPeripheralsAfterWake` can try
  ///    to get *whatever we were using* back on wake — not just the subset we
  ///    actively handed off. This is what recovers a device that drops on a
  ///    lid-close with no peer to hand it to and then won't reconnect (the
  ///    macOS-side bug the watcher exists for).
  ///
  /// 2. When `releaseOnSleep` is set and a peer looks present (paired + a
  ///    registered device we're seeing on Bonjour), release each held
  ///    peripheral so the peer can take it cleanly rather than have it
  ///    stranded on a Mac that can no longer be reached to release it. With
  ///    no peer around there's no one to hand off to, so we leave them bonded.
  ///
  /// The IOBluetooth reads/removes run synchronously on `bluetoothQueue` (the
  /// only place IOBluetooth is touched) so they land before the radio powers
  /// down.
  private func prepareForSleep() {
    connectedBeforeSleep = []
    peripheralsReleasedForSleep = []

    // Snapshot `peripherals` on main before hopping to the Bluetooth queue.
    let registered = peripherals
    guard !registered.isEmpty else { return }

    let shouldRelease =
      releaseOnSleep
      && PairingStore.shared.isPaired
      && NetworkDeviceStore.shared.networkDevices.contains(where: { $0.isActive })

    // If we're neither releasing nor going to chase peripherals on wake, skip
    // the IOBluetooth scan rather than block the (held) sleep transition to
    // build a `connectedBeforeSleep` snapshot no one will read.
    guard shouldRelease || autoReconnect else { return }

    var connectedIDs: [String] = []
    var releasedIDs: [String] = []
    bluetoothQueue.sync {
      for peripheral in registered {
        guard let device = IOBluetoothDevice(addressString: peripheral.id),
          device.isConnected()
        else { continue }
        connectedIDs.append(peripheral.id)
        guard shouldRelease else { continue }
        if device.responds(to: Selector(("remove"))) {
          device.perform(Selector(("remove")))
        } else {
          _ = device.closeConnection()
        }
        releasedIDs.append(peripheral.id)
      }
    }

    // Back on main (we never left it). Record what we were holding so the
    // wake reclaim can chase it, and reflect any releases in the UI.
    connectedBeforeSleep = Set(connectedIDs)
    peripheralsReleasedForSleep = Set(releasedIDs)
    for id in releasedIDs {
      // Keep the sleep-time disconnect notifications from arming the watcher;
      // `reclaimPeripheralsAfterWake` re-arms these explicitly on wake.
      noteIntentionalRelease(id)
      setConnectionState(.disconnected, for: id)
    }
    if !connectedIDs.isEmpty {
      print("Before sleep: \(connectedIDs.count) connected, released \(releasedIDs.count)")
    }
  }

  /// Runs (on main) from `SleepMonitor` after wake. When auto-reconnect is on,
  /// arms the watcher for *everything this Mac was holding before sleep*
  /// (`connectedBeforeSleep`) so it chases back whatever didn't return on its
  /// own — the watcher's probe applies the read-only `HOLDS_ONE` peer check,
  /// so anything the peer legitimately took is left alone. When off, falls
  /// back to the original one-shot reclaim of just the peripherals we released
  /// for sleep. Waits `Constants.wakeReclaimDelay` first so the network can
  /// reassociate (and bonded devices get a moment to reconnect on their own)
  /// before any unreachable-looking peer gets a peripheral grabbed back.
  private func reclaimPeripheralsAfterWake() {
    let connected = connectedBeforeSleep
    let released = peripheralsReleasedForSleep
    connectedBeforeSleep = []
    peripheralsReleasedForSleep = []
    guard !connected.isEmpty else { return }

    // Connection states are stale across sleep — a peripheral we left bonded
    // still reads `.connected`. Refresh from live IOBluetooth so the watcher
    // (and the Peripheral tab) see reality before we act on it.
    fetchConnectedPeripherals()

    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.wakeReclaimDelay) {
      [weak self] in
      guard let self = self else { return }

      if self.autoReconnect {
        for id in connected {
          // Anything we unpaired for sleep is no longer "intentionally
          // released" now that we're awake and want it back.
          if released.contains(id) { self.intentionalReleases.remove(id) }
          guard self.peripherals.contains(where: { $0.id == id }) else { continue }
          self.armReconnect(id)
        }
        return
      }

      // Feature off: original one-shot reclaim, scoped to the peripherals we
      // released for sleep. The registered peer is not gated on `isActive`
      // (Bonjour may not have re-resolved yet, but `executeHoldsOne` actually
      // connects, so reachability is decided there).
      for id in released {
        self.intentionalReleases.remove(id)
        guard let peripheral = self.peripherals.first(where: { $0.id == id }) else { continue }
        guard let device = NetworkDeviceStore.shared.networkDevices.first,
          PairingStore.shared.isPaired
        else {
          // No peer to ask — these are ours; take them back.
          self.connectPeripheral(peripheral)
          continue
        }
        NetworkDeviceStore.shared.executeHoldsOne(address: id, on: device) {
          [weak self] result in
          guard let self = self else { return }
          // `.success` = peer holds it (in use over there) → leave it.
          // Any `.failure` (peer says no, or unreachable) → take it back.
          if case .failure = result {
            self.connectPeripheral(peripheral)
          }
        }
      }
    }
  }

  /// Whether this Mac currently has a live Bluetooth connection to the
  /// peripheral with `address`. Answered off the live IOBluetooth state on
  /// `bluetoothQueue`; the completion fires on that queue. Used by the peer's
  /// `HOLDS_ONE` query so its wake-time reclaim skips peripherals we hold.
  func isHoldingPeripheral(address: String, completion: @escaping (Bool) -> Void) {
    bluetoothQueue.async {
      let connected = IOBluetoothDevice(addressString: address)?.isConnected() ?? false
      completion(connected)
    }
  }

  /// Register for every Bluetooth connect the OS sees, so the Peripheral
  /// tab updates immediately when the user pairs/connects a device via the
  /// system Bluetooth menu instead of via Magic Switch. The handler just
  /// re-snapshots state; that's cheap and avoids us trying to keep our
  /// own model in sync incrementally.
  private func registerForSystemBluetoothConnects() {
    globalConnectObserver = IOBluetoothDevice.register(
      forConnectNotifications: self,
      selector: #selector(handleSystemBluetoothConnect(_:fromDevice:))
    )
  }

  @objc private func handleSystemBluetoothConnect(
    _ notification: IOBluetoothUserNotification,
    fromDevice device: IOBluetoothDevice
  ) {
    fetchConnectedPeripherals()
  }

  // MARK: - Public Methods

  /// Adds a peripheral to the managed list in connected state
  /// - Parameter peripheral: The peripheral to add
  func addPeripheral(_ peripheral: BluetoothPeripheral) {
    guard validateBluetoothState() else { return }
    guard validateDeviceExists(peripheral) else { return }

    var newPeripheral = peripheral
    peripherals.append(newPeripheral)
  }

  /// Removes peripheral information from the system while maintaining it in the list
  /// - Parameter peripheral: The peripheral to unregister
  func unregisterFromPC(_ peripheral: BluetoothPeripheral) {
    guard validateBluetoothState() else { return }
    guard let btDevice = getBluetoothDevice(for: peripheral) else { return }

    // Deliberate release: stop any auto-reconnect attempt for it.
    disarmReconnect(peripheral.id)

    if !btDevice.isConnected() {
      print("Device is already disconnected: \(peripheral.name)")
      setConnectionState(.disconnected, for: peripheral.id)
      return
    }

    if btDevice.responds(to: Selector(("remove"))) {
      // Suppress the imminent disconnect notification from re-arming the
      // watcher — we're handing this peripheral away on purpose.
      noteIntentionalRelease(peripheral.id)
      btDevice.perform(Selector(("remove")))
      print("Device information removed: \(peripheral.name)")
      setConnectionState(.disconnected, for: peripheral.id)
      return
    }

    // Fallback path: a future macOS that renames or removes the private
    // `-remove` selector lands here. `closeConnection` doesn't fully
    // unpair (the device stays in System Settings → Bluetooth's list), but
    // it breaks the active session so the peer can take ownership.
    noteIntentionalRelease(peripheral.id)
    let result = btDevice.closeConnection()
    if result == kIOReturnSuccess {
      print("Fell back to closeConnection() for \(peripheral.name)")
      setConnectionState(.disconnected, for: peripheral.id)
    } else {
      // The release didn't happen, so no disconnect notification will arrive
      // to consume the flag — clear it so it can't suppress a later genuine
      // drop's auto-reconnect.
      clearIntentionalRelease(peripheral.id)
      print("Failed to release \(peripheral.name): closeConnection returned \(result)")
      NotificationManager.showNotification(
        title: "Couldn't Release Peripheral",
        body:
          "Magic Switch couldn't release \(peripheral.name) from this Mac. Try Forget This Device in System Settings → Bluetooth.",
        identifier: "unregister-failed-\(peripheral.id)"
      )
    }
  }

  /// Completely remove device from list
  func removeFromList(_ peripheral: BluetoothPeripheral) {
    guard peripherals.contains(where: { $0.id == peripheral.id }) else {
      print("\(peripheral.name) does not exist in the list")
      return
    }
    peripherals.removeAll { $0.id == peripheral.id }
    // No longer ours — stop watching and forget any pending release flag.
    disarmReconnect(peripheral.id)
    intentionalReleases.remove(peripheral.id)
    print("\(peripheral.name) has been removed from the list")
  }

  /// Asks the peer to release just this peripheral, then pairs it
  /// locally. Used by the Peripheral tab's "Connect to PC" button and by
  /// the right-click menu's per-peripheral switch. Apple's Magic devices
  /// only honor one host at a time, so `IOBluetoothDevicePair.start()`
  /// would hang otherwise.
  ///
  /// Falls back to a plain local pair if there's no paired peer, we're not
  /// paired ourselves, or the peer can't be reached — whether Bonjour
  /// already marked it inactive or it only turns out to be unreachable when
  /// we try to send (e.g. the other laptop's lid just closed).
  func takePeripheralFromPeer(_ peripheral: BluetoothPeripheral) {
    let networkStore = NetworkDeviceStore.shared
    guard let device = networkStore.networkDevices.first,
      PairingStore.shared.isPaired,
      device.isActive
    else {
      connectPeripheral(peripheral)
      return
    }

    setConnectionState(.connecting, for: peripheral.id)
    schedulePairWatchdog(for: peripheral, announceTimeout: true)
    networkStore.executeUnregisterOne(address: peripheral.id, on: device) {
      [weak self] result in
      guard let self = self else { return }
      switch result {
      case .success:
        self.connectPeripheral(peripheral)
      case .failure(.connectionFailed), .failure(.connectTimeout):
        // We never got a TCP connection up, so the peer's machine is
        // unreachable (asleep, off the network, app not running) and isn't
        // holding the peripheral anymore — a Mac that drops off the network
        // has already released its Bluetooth devices. Pair locally instead
        // of stranding the user with an error they can't act on. We
        // deliberately don't do this for post-connect failures: if the
        // connection opened, the peer's machine is awake and may still
        // actively hold the peripheral, so a local grab would yank it out
        // from under the peer and leave it in a stale state.
        self.connectPeripheral(peripheral)
      case .failure(let err):
        self.setConnectionState(.disconnected, for: peripheral.id)
        NotificationManager.showNotification(
          title: "Couldn't Switch",
          body:
            "Couldn't ask \(device.name) to release \(peripheral.name): \(err.userMessage)",
          identifier: "take-failed-\(peripheral.id)"
        )
      }
    }
  }

  /// The inverse direction: release the peripheral locally, wait for the
  /// IOBluetooth-level disconnect to land, then ask the peer to take it.
  /// Used by the Peripheral tab's "Remove from PC" button and by the
  /// right-click menu's per-peripheral switch when the peripheral is
  /// currently on this Mac.
  ///
  /// Falls back to a plain local unregister if there's no paired peer.
  func sendPeripheralToPeer(_ peripheral: BluetoothPeripheral) {
    let networkStore = NetworkDeviceStore.shared
    guard let device = networkStore.networkDevices.first,
      PairingStore.shared.isPaired,
      device.isActive
    else {
      unregisterFromPC(peripheral)
      return
    }
    unregisterFromPC(peripheral)
    waitForLocalDisconnect(of: peripheral) { success in
      guard success else {
        NotificationManager.showNotification(
          title: "Couldn't Switch",
          body: "\(peripheral.name) didn't disconnect from this Mac.",
          identifier: "send-disconnect-failed-\(peripheral.id)"
        )
        return
      }
      networkStore.executeConnectOne(address: peripheral.id, on: device) { result in
        if case .failure(let err) = result {
          NotificationManager.showNotification(
            title: "Couldn't Switch",
            body:
              "Couldn't ask \(device.name) to take \(peripheral.name): \(err.userMessage)",
            identifier: "send-connect-failed-\(peripheral.id)"
          )
        }
      }
    }
  }

  /// Polls IOBluetooth (not the cached `connectionStates`) every 0.5s up
  /// to 5 times, waiting for the device to actually disconnect. Same
  /// pattern as `AppDelegate.waitForDisconnection`, but for a single
  /// peripheral instead of the full set.
  private func waitForLocalDisconnect(
    of peripheral: BluetoothPeripheral,
    completion: @escaping (Bool) -> Void
  ) {
    var attempts = 0
    let maxAttempts = 5
    func check() {
      attempts += 1
      bluetoothQueue.async {
        let connected = IOBluetoothDevice(addressString: peripheral.id)?.isConnected() ?? false
        DispatchQueue.main.async {
          if !connected {
            completion(true)
          } else if attempts < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check() }
          } else {
            completion(false)
          }
        }
      }
    }
    // First check fires immediately; the IOBluetooth disconnect issued by
    // `unregisterFromPC` is synchronous, so the peripheral is often
    // already gone. Polled retry covers the few cases where it isn't.
    check()
  }

  func connectPeripheral(_ peripheral: BluetoothPeripheral) {
    connectPeripheral(peripheral, announcePairTimeout: true)
  }

  /// - Parameter announcePairTimeout: whether a pair-watchdog timeout should
  ///   raise a user notification. Interactive callers pass `true`; the
  ///   auto-reconnect watcher passes `false` so its retries against a stuck
  ///   device don't spam "Pairing Timed Out".
  private func connectPeripheral(_ peripheral: BluetoothPeripheral, announcePairTimeout: Bool) {
    setConnectionState(.connecting, for: peripheral.id)
    schedulePairWatchdog(for: peripheral, announceTimeout: announcePairTimeout)

    bluetoothQueue.async { [weak self] in
      guard let self = self else { return }

      guard let btDevice = IOBluetoothDevice(addressString: peripheral.id) else {
        print("\(peripheral.name) not found")
        self.setConnectionState(.disconnected, for: peripheral.id)
        return
      }

      guard IOBluetoothHostController.default().powerState != kBluetoothHCIPowerStateOFF else {
        print("Bluetooth is turned off")
        self.setConnectionState(.disconnected, for: peripheral.id)
        return
      }

      // Already bonded to this Mac. A peripheral we're holding that merely
      // dropped — power cycle, briefly out of range, wake — keeps its link
      // key, so macOS reconnects it on its own. Running
      // `IOBluetoothDevicePair.start()` on a bonded device re-runs bonding and
      // forces a disconnect/reconnect cycle that fights that reconnect (and
      // strands the UI at "(Pairing…)" — the pair callback never fires for an
      // already-connected device, and `fetchConnectedPeripherals` won't
      // overwrite the in-flight `.connecting`). So adopt the live connection,
      // or just open one — never re-pair. A peripheral handed to the peer was
      // `-remove`d (see `unregisterFromPC`), so it isn't bonded here and falls
      // through to the pairing path below: that's the take-from-peer case.
      if btDevice.isConnected() || btDevice.isPaired() {
        if !btDevice.isConnected() {
          _ = btDevice.openConnection()
        }
        if btDevice.isConnected() {
          self.setConnectionState(.connected, for: peripheral.id)
          self.registerForDisconnect(device: btDevice, address: peripheral.id)
        } else {
          // Bonded but didn't come up (still booting / out of range). Leave it
          // disconnected; macOS or the watcher's next probe will bring it back.
          self.setConnectionState(.disconnected, for: peripheral.id)
        }
        return
      }

      if btDevice.rssi() == Constants.invalidRSSI {
        print("\(peripheral.name) is out of range or not responding")
        self.setConnectionState(.disconnected, for: peripheral.id)
        return
      }

      guard let devicePair = IOBluetoothDevicePair(device: btDevice) else {
        print("Failed to initialize pairing for \(peripheral.name)")
        self.setConnectionState(.disconnected, for: peripheral.id)
        return
      }

      devicePair.delegate = self
      DispatchQueue.main.async {
        self.pendingPairs[peripheral.id]?.stop()
        self.pendingPairs[peripheral.id] = devicePair
      }

      let pairResult = devicePair.start()
      if pairResult != kIOReturnSuccess {
        print("Failed to start pairing with \(peripheral.name). Error code: \(pairResult)")
        DispatchQueue.main.async {
          self.pendingPairs.removeValue(forKey: peripheral.id)
        }
        self.setConnectionState(.disconnected, for: peripheral.id)
      }
      // Success path continues in `devicePairingFinished(_:error:)`.
    }
  }

  /// Disconnect device
  func disconnectPeripheral(_ peripheral: BluetoothPeripheral) {
    guard IOBluetoothHostController.default().powerState != kBluetoothHCIPowerStateOFF else {
      print("Bluetooth is turned off")
      return
    }

    guard let btDevice = IOBluetoothDevice(addressString: peripheral.id) else {
      print("\(peripheral.name) not found")
      return
    }

    if !btDevice.isConnected() {
      print("\(peripheral.name) is already disconnected")
      setConnectionState(.disconnected, for: peripheral.id)
      return
    }

    // Deliberate disconnect: stop watching it and keep the resulting
    // disconnect notification from re-arming the watcher.
    disarmReconnect(peripheral.id)
    noteIntentionalRelease(peripheral.id)
    let result = btDevice.closeConnection()
    if result == kIOReturnSuccess {
      print("Disconnected from \(peripheral.name)")
      setConnectionState(.disconnected, for: peripheral.id)
    } else {
      print("Failed to disconnect from \(peripheral.name). Error code: \(result)")
    }
  }

  func fetchConnectedPeripherals() {
    let runSnapshot: ([String]) -> Void = { [weak self] registeredIDs in
      guard let self = self else { return }
      self.bluetoothQueue.async {
        guard IOBluetoothHostController.default().powerState != kBluetoothHCIPowerStateOFF else {
          print("Bluetooth is turned off")
          return
        }

        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
          print("No paired peripherals found")
          return
        }

        var paired: [BluetoothPeripheral] = []
        var connectedAddresses: Set<String> = []

        for device in pairedDevices {
          guard let address = device.addressString else { continue }
          if device.isConnected() {
            connectedAddresses.insert(address)
          }
          paired.append(
            BluetoothPeripheral(id: address, name: device.name ?? "Unknown Device")
          )
        }

        DispatchQueue.main.async {
          // Snapshot all paired devices; `availablePeripherals` filters out
          // registered ones at read time. Filtering here instead would mean
          // unregistering a peripheral can't immediately surface it under
          // "Available" until the next fetch (e.g. tab switch).
          self.discoveredPeripherals = paired
          for id in registeredIDs {
            let isConnected = connectedAddresses.contains(id)
            // Don't overwrite an in-flight .connecting state with a stale read.
            if self.connectionStates[id] == .connecting { continue }
            self.connectionStates[id] = isConnected ? .connected : .disconnected
            if isConnected, self.disconnectObservers[id] == nil,
              let device = IOBluetoothDevice(addressString: id)
            {
              self.registerForDisconnect(device: device, address: id)
            }
          }
        }
      }
    }

    if Thread.isMainThread {
      runSnapshot(peripherals.map { $0.id })
    } else {
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        runSnapshot(self.peripherals.map { $0.id })
      }
    }
  }

  /// Updates the peripheral list with new data from sync
  /// - Parameter newPeripherals: Array of peripherals to update with
  func updatePeripherals(_ newPeripherals: [BluetoothPeripheral]) {
    // Cap inbound list size; reject larger payloads outright.
    guard newPeripherals.count <= 64 else {
      print("Rejecting peripheral sync: list exceeds cap of 64")
      return
    }

    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.updatePeripherals(newPeripherals)
      }
      return
    }

    peripherals = newPeripherals
  }

  // MARK: - Pair Delegate & Connection Tracking

  /// `IOBluetoothDevicePairDelegate` callback. Open the actual connection here
  /// once pairing has actually completed (the pre-rewrite code called
  /// `openConnection()` synchronously after `start()` and lost the device).
  @objc func devicePairingFinished(_ sender: Any!, error: IOReturn) {
    guard let pair = sender as? IOBluetoothDevicePair,
      let device = pair.device(),
      let address = device.addressString
    else {
      return
    }

    DispatchQueue.main.async {
      self.pendingPairs.removeValue(forKey: address)
    }

    guard error == kIOReturnSuccess else {
      print("Pairing failed for \(address): \(error)")
      setConnectionState(.disconnected, for: address)
      return
    }

    bluetoothQueue.async { [weak self] in
      guard let self = self else { return }
      if !device.isConnected() {
        let result = device.openConnection()
        if result != kIOReturnSuccess {
          print("openConnection failed after pair: \(result)")
        }
      }
      if device.isConnected() {
        self.setConnectionState(.connected, for: address)
        self.registerForDisconnect(device: device, address: address)
      } else {
        self.setConnectionState(.disconnected, for: address)
      }
    }
  }

  /// Selector target for `IOBluetoothDevice.register(forDisconnectNotification:...)`.
  /// Signature must be `(IOBluetoothUserNotification, IOBluetoothDevice)`.
  @objc private func handlePeripheralDisconnected(
    _ notification: IOBluetoothUserNotification,
    fromDevice device: IOBluetoothDevice
  ) {
    notification.unregister()
    let address = device.addressString ?? ""
    DispatchQueue.main.async {
      self.disconnectObservers.removeValue(forKey: address)
      // Don't clobber a fresh .connecting attempt from a pre-empt path.
      guard self.connectionStates[address] != .connecting else { return }
      self.connectionStates[address] = .disconnected
      if self.intentionalReleases.remove(address) != nil {
        // We let this one go on purpose (handoff / sleep) — don't reclaim it.
        return
      }
      // Genuine drop of a peripheral that should be on this Mac: start trying
      // to get it back. `armReconnect` no-ops when the feature is off or the
      // peripheral isn't registered to us.
      self.armReconnect(address)
    }
  }

  private func registerForDisconnect(device: IOBluetoothDevice, address: String) {
    guard
      let observer = device.register(
        forDisconnectNotification: self,
        selector: #selector(handlePeripheralDisconnected(_:fromDevice:))
      )
    else {
      return
    }
    DispatchQueue.main.async {
      self.disconnectObservers[address]?.unregister()
      self.disconnectObservers[address] = observer
    }
  }

  private func setConnectionState(_ state: PeripheralConnectionState, for id: String) {
    if Thread.isMainThread {
      connectionStates[id] = state
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.connectionStates[id] = state
      }
    }
  }

  // MARK: - Pair Watchdog

  /// Schedules a watchdog that flips the peripheral back to `.disconnected`
  /// if `devicePairingFinished` hasn't fired within `Constants.pairTimeout`.
  /// We don't explicitly cancel from the success / pre-flight-failure paths;
  /// the handler no-ops if the state has already moved on.
  private func schedulePairWatchdog(for peripheral: BluetoothPeripheral, announceTimeout: Bool) {
    let address = peripheral.id
    let name = peripheral.name
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.pairTimers[address]?.cancel()
      self.pairTimeoutShouldAnnounce[address] = announceTimeout
      let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
      timer.schedule(deadline: .now() + Constants.pairTimeout)
      timer.setEventHandler { [weak self] in
        self?.handlePairTimeout(address: address, name: name)
      }
      timer.resume()
      self.pairTimers[address] = timer
    }
  }

  private func handlePairTimeout(address: String, name: String) {
    // Timer fires on the main queue.
    guard connectionStates[address] == .connecting else {
      pairTimers.removeValue(forKey: address)
      pairTimeoutShouldAnnounce.removeValue(forKey: address)
      return
    }
    pendingPairs[address]?.stop()
    pendingPairs.removeValue(forKey: address)
    pairTimers.removeValue(forKey: address)
    let announce = pairTimeoutShouldAnnounce.removeValue(forKey: address) ?? true
    connectionStates[address] = .disconnected
    // A silent watcher retry just tries again on the next probe; only
    // interactive connects surface the timeout to the user.
    guard announce else { return }
    NotificationManager.showNotification(
      title: "Pairing Timed Out",
      body:
        "Couldn't pair \(name). It may currently be connected to your other Mac — try the menu-bar switch action instead.",
      identifier: "pair-timeout-\(address)"
    )
  }

  // MARK: - Auto-Reconnect Watcher

  /// Arm the watcher for `id`: it'll be probed every
  /// `Constants.reconnectProbeInterval` and reclaimed once it's back in range
  /// and the peer isn't using it. No-op when the feature is off or the
  /// peripheral isn't registered to us. Preserves the original arm time on
  /// re-arm so the `reconnectMaxWindow` bound counts from the first drop.
  private func armReconnect(_ id: String) {
    // The watcher dictionaries/sets and timer are main-only, but deliberate
    // releases (`unregisterFromPC` during a handoff) reach the watcher from the
    // outgoing-connection queue — hop to main so we never mutate this state
    // concurrently with `reconnectTick` / `handlePeripheralDisconnected`.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.armReconnect(id) }
      return
    }
    guard autoReconnect, peripherals.contains(where: { $0.id == id }) else { return }
    if reconnectWatchlist[id] == nil {
      reconnectWatchlist[id] = Date()
      print("Auto-reconnect: watching \(id)")
    }
    startReconnectTimerIfNeeded()
  }

  /// Stop watching `id` — it connected, moved to the peer, was removed, or
  /// timed out. Tears the timer down once nothing is left to watch.
  private func disarmReconnect(_ id: String) {
    // Main-only state; see `armReconnect`.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.disarmReconnect(id) }
      return
    }
    reconnectInFlight.remove(id)
    guard reconnectWatchlist.removeValue(forKey: id) != nil else { return }
    if reconnectWatchlist.isEmpty { stopReconnectTimer() }
  }

  /// Note that `id` is being released on purpose, so the disconnect
  /// notification that follows doesn't re-arm the watcher. Consumed by
  /// `handlePeripheralDisconnected`.
  private func noteIntentionalRelease(_ id: String) {
    // Main-only state; see `armReconnect`.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.noteIntentionalRelease(id) }
      return
    }
    intentionalReleases.insert(id)
  }

  /// Undo a `noteIntentionalRelease` when the release didn't actually happen
  /// (e.g. `closeConnection` failed), so a stale flag can't suppress the
  /// reconnect of a later genuine drop.
  private func clearIntentionalRelease(_ id: String) {
    // Main-only state; see `armReconnect`.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.clearIntentionalRelease(id) }
      return
    }
    intentionalReleases.remove(id)
  }

  private func startReconnectTimerIfNeeded() {
    guard reconnectTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    // Fire immediately, then on the probe interval — an immediate first tick
    // makes wake-time reclaim and manual power-cycle recovery feel prompt.
    timer.schedule(deadline: .now(), repeating: Constants.reconnectProbeInterval)
    timer.setEventHandler { [weak self] in self?.reconnectTick() }
    timer.resume()
    reconnectTimer = timer
  }

  private func stopReconnectTimer() {
    reconnectTimer?.cancel()
    reconnectTimer = nil
  }

  /// One probe pass over the watchlist (runs on main). Drops entries that are
  /// connected, no longer ours, or past the window; otherwise probes whether
  /// the device is back and, if so, reclaims it. Iterates a snapshot because
  /// `disarmReconnect` mutates `reconnectWatchlist`.
  private func reconnectTick() {
    guard autoReconnect else {
      // Toggled off mid-flight — stand down.
      reconnectWatchlist.removeAll()
      reconnectInFlight.removeAll()
      stopReconnectTimer()
      return
    }
    let now = Date()
    for (id, armedAt) in reconnectWatchlist {
      if reconnectInFlight.contains(id) { continue }
      guard let peripheral = peripherals.first(where: { $0.id == id }) else {
        disarmReconnect(id)
        continue
      }
      if now.timeIntervalSince(armedAt) > Constants.reconnectMaxWindow {
        print("Auto-reconnect: giving up on \(peripheral.name)")
        disarmReconnect(id)
        continue
      }
      switch connectionState(for: id) {
      case .connected:
        disarmReconnect(id)
      case .connecting:
        continue  // an attempt is already in flight
      case .disconnected:
        probeAndReclaim(peripheral)
      }
    }
  }

  /// Checks live IOBluetooth state for `peripheral` off the main queue. If it's
  /// already connected, adopts it; if it's back in range and still bonded here,
  /// reconnects locally (it's ours); otherwise hands off to
  /// `reclaimIfPeerIsFree` to consult the peer before pairing. Marks the id
  /// in-flight so overlapping ticks skip it until this resolves.
  private func probeAndReclaim(_ peripheral: BluetoothPeripheral) {
    let id = peripheral.id
    reconnectInFlight.insert(id)
    bluetoothQueue.async { [weak self] in
      guard let self = self else { return }
      // RSSI is the "is it back?" signal — `invalidRSSI` (127) means we can't
      // see it, the same gate `connectPeripheral` uses. Cheap while absent.
      var alreadyConnected = false
      var bondedHere = false
      var reachable = false
      if IOBluetoothHostController.default().powerState != kBluetoothHCIPowerStateOFF,
        let device = IOBluetoothDevice(addressString: id)
      {
        alreadyConnected = device.isConnected()
        bondedHere = device.isPaired()
        reachable = device.rssi() != Constants.invalidRSSI
      }
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        // Bail if it left the watchlist or changed state while we probed.
        guard self.reconnectWatchlist[id] != nil,
          self.connectionState(for: id) == .disconnected
        else {
          self.reconnectInFlight.remove(id)
          return
        }
        if alreadyConnected {
          // It came back on its own (e.g. macOS reconnected a bonded device
          // on wake) — record it and stop; no need to re-pair. The genuine
          // drop unregistered the old disconnect observer, so re-register one
          // here, otherwise the *next* drop wouldn't re-arm the watcher.
          self.reconnectInFlight.remove(id)
          self.setConnectionState(.connected, for: id)
          if self.disconnectObservers[id] == nil,
            let device = IOBluetoothDevice(addressString: id)
          {
            self.registerForDisconnect(device: device, address: id)
          }
          self.disarmReconnect(id)
          return
        }
        guard reachable else {
          // Still gone — wait for the next tick.
          self.reconnectInFlight.remove(id)
          return
        }
        if bondedHere {
          // Still bonded to this Mac, so it's ours: the peer can't hold a
          // device whose link key lives here. Skip the HOLDS_ONE query and
          // reconnect locally — `connectPeripheral` opens the connection
          // without re-pairing (re-pairing a bonded device forces a
          // disconnect/reconnect cycle and fights macOS's own reconnect).
          self.reconnectInFlight.remove(id)
          self.connectPeripheral(peripheral, announcePairTimeout: false)
          return
        }
        self.reclaimIfPeerIsFree(peripheral)
      }
    }
  }

  /// `peripheral` is back in range. Ask the peer (read-only `HOLDS_ONE`)
  /// whether it's using it: if so, stop watching (it's legitimately theirs);
  /// otherwise — peer says no, or is unreachable — reconnect locally. This is
  /// the same guard the wake-reclaim uses: we never yank a peripheral the
  /// peer is actively using, and we never tell the peer to disconnect.
  private func reclaimIfPeerIsFree(_ peripheral: BluetoothPeripheral) {
    let id = peripheral.id
    guard PairingStore.shared.isPaired,
      let device = NetworkDeviceStore.shared.networkDevices.first
    else {
      // No peer to consult — it's ours; take it.
      reconnectInFlight.remove(id)
      connectPeripheral(peripheral, announcePairTimeout: false)
      return
    }
    NetworkDeviceStore.shared.executeHoldsOne(address: id, on: device) { [weak self] result in
      // `executeHoldsOne`'s completion fires on the connection queue, not
      // main — hop back before touching watcher state.
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.reconnectInFlight.remove(id)
        switch result {
        case .success:
          // Peer is actively holding it — leave it there.
          print("Auto-reconnect: \(peripheral.name) held by \(device.name); leaving it")
          self.disarmReconnect(id)
        case .failure:
          guard self.reconnectWatchlist[id] != nil,
            self.connectionState(for: id) == .disconnected
          else { return }
          print("Auto-reconnect: reclaiming \(peripheral.name)")
          self.connectPeripheral(peripheral, announcePairTimeout: false)
        }
      }
    }
  }

  // MARK: - Private Methods

  private func savePeripherals() {
    do {
      let encoded = try JSONEncoder().encode(peripherals)
      peripheralsData = encoded
    } catch {
      print("Failed to save peripherals: \(error)")
    }
  }

  private func loadPeripherals() {
    do {
      peripherals = try JSONDecoder().decode([BluetoothPeripheral].self, from: peripheralsData)
    } catch {
      print("Failed to load peripherals: \(error)")
    }
  }

  // MARK: - Helper Methods

  private func validateBluetoothState() -> Bool {
    let powerState = IOBluetoothHostController.default().powerState
    guard powerState != kBluetoothHCIPowerStateOFF else {
      print("Bluetooth is turned off")
      return false
    }
    return true
  }

  private func validateDeviceExists(_ peripheral: BluetoothPeripheral) -> Bool {
    guard IOBluetoothDevice(addressString: peripheral.id) != nil else {
      print("Device not found: \(peripheral.name)")
      return false
    }
    return true
  }

  private func getBluetoothDevice(for peripheral: BluetoothPeripheral) -> IOBluetoothDevice? {
    guard let device = IOBluetoothDevice(addressString: peripheral.id) else {
      print("Device not found: \(peripheral.name)")
      return nil
    }
    return device
  }
}

extension BluetoothPeripheralStore {
  /// Aggregate connection state across all registered peripherals.
  enum ConnectionStatus {
    case allConnected
    case allDisconnected
    case partial
  }

  /// Queries the live IOBluetooth state on `bluetoothQueue` and returns on
  /// main. Snapshots `peripherals` on main before hopping so we never read
  /// the `@Published` array from a background thread.
  func checkActualConnectionStatusAsync(completion: @escaping (ConnectionStatus) -> Void) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.checkActualConnectionStatusAsync(completion: completion)
      }
      return
    }

    let snapshot = peripherals
    bluetoothQueue.async {
      var connectedCount = 0
      var totalCount = 0
      for peripheral in snapshot {
        if let device = IOBluetoothDevice(addressString: peripheral.id) {
          totalCount += 1
          if device.isConnected() { connectedCount += 1 }
        }
      }
      let status: ConnectionStatus
      if totalCount == 0 || connectedCount == 0 {
        status = .allDisconnected
      } else if connectedCount == totalCount {
        status = .allConnected
      } else {
        status = .partial
      }
      DispatchQueue.main.async { completion(status) }
    }
  }
}
