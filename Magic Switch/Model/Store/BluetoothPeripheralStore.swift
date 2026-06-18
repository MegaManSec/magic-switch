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

  /// Initiates takeover from the peer Mac, refreshing stale local pairing first
  func connectPeripheralFromPeer(_ peripheral: BluetoothPeripheral)

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
    /// How often the auto-reconnect watcher probes a dropped peripheral to see
    /// whether it's back. The probe is just an RSSI read while the device is
    /// absent, so it's cheap. A short, *constant* cadence is deliberate: the
    /// watcher exists to grab a peripheral the moment it reappears after the
    /// user power-cycles a stuck device (a failed handoff can leave it bonded
    /// to both Macs but connected to neither), and that reconnect only succeeds
    /// within a brief window — so we stay prompt for the whole
    /// `reconnectMaxWindow` rather than backing off (a power-cycle tends to
    /// come late, exactly when a decayed cadence would miss it).
    static let reconnectProbeInterval: TimeInterval = 5
    /// Timer leeway for the probe — kept small so the OS can coalesce the
    /// wakeup a little without materially delaying the catch.
    static let reconnectProbeLeeway: DispatchTimeInterval = .milliseconds(500)
    /// Upper bound on how long the watcher keeps trying to reclaim one
    /// peripheral before giving up. The recovery case is a user who notices a
    /// stuck peripheral and power-cycles it, so a few minutes covers it; an
    /// hour would just burn wakeups on a device that's genuinely gone (off, out
    /// of range, carried away). A fresh drop or wake re-arms it.
    static let reconnectMaxWindow: TimeInterval = 600
    /// How long after a deliberate release (handoff / sleep / "Remove") the
    /// matching IOBluetooth disconnect is expected to arrive. A disconnect
    /// seen within this window is treated as that release and doesn't re-arm
    /// the watcher; a disconnect seen later is treated as a genuine drop. This
    /// stops a release whose disconnect notification never arrived from
    /// leaving a stale flag that suppresses a real reconnect.
    static let intentionalReleaseGrace: TimeInterval = 15
    /// Consecutive peer-absent `HOLDS_ONE` probes an *adoption* needs before
    /// it takes a peripheral. Two probes (one extra tick) give Wi-Fi that's
    /// still reassociating after wake a chance to come up — so a peer that's
    /// actually alive gets to answer and stand the adoption down — while
    /// keeping lid-open → peripheral-back under ~20s.
    static let adoptionRequiredAbsentStreak = 2
    /// Failed local pair attempts after which an adoption gives up. A free
    /// peripheral pairs on the first try; repeated failures usually mean it's
    /// still held by a peer we can't reach over the network (pairing a held
    /// Magic device just hangs), so bound the phantom "Pairing…" churn.
    /// Reclaims — a prior claim — keep the full `reconnectMaxWindow` retry.
    static let adoptionMaxPairAttempts = 3
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

  /// `@AppStorage` key for the per-peripheral icon/type overrides map.
  static let typeOverridesDefaultsKey = "peripheralTypeOverrides"

  @AppStorage("peripherals") private var peripheralsData: Data = Data()

  @AppStorage(BluetoothPeripheralStore.typeOverridesDefaultsKey)
  private var typeOverridesData: Data = Data()

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

  /// User-chosen type per peripheral address, overriding auto-detection. Local
  /// to this Mac (not synced — the peer auto-detects its own icons). Persisted.
  @Published private(set) var typeOverrides: [String: PeripheralType] = [:] {
    didSet { saveTypeOverrides() }
  }

  /// Bluetooth Class of Device per address, captured from the live paired
  /// snapshot. Feeds auto-detection (especially audio gear, whose names rarely
  /// say "headphones"). Not persisted — refreshed each `fetchConnectedPeripherals`.
  @Published private(set) var deviceClasses: [String: UInt32] = [:]

  /// Runtime connection state per peripheral id. Driven by pair completion and
  /// IOBluetooth disconnect notifications.
  @Published private(set) var connectionStates: [String: PeripheralConnectionState] = [:]

  /// One-shot waiters for handoff connect results. Incoming network commands
  /// use these so they can acknowledge "connected" instead of merely
  /// "connect attempt started".
  private var connectResultWaiters: [String: [(Bool) -> Void]] = [:]

  /// Inline per-peripheral error shown under the row in the menu-bar dropdown
  /// (so a failed switch is visible without relying on the system notification).
  /// Set on a switch failure; fades after 5s, or sooner when `setConnectionState`
  /// sees the next attempt (`.connecting`) or success (`.connected`).
  @Published private(set) var peripheralOperationError: [String: String] = [:]
  /// Per-peripheral fade timers for `peripheralOperationError`.
  private var peripheralErrorTimers: [String: DispatchSourceTimer] = [:]

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

  /// Peripherals the auto-reconnect watcher is trying to get onto this Mac,
  /// keyed by id, with the time each was armed (for the `reconnectMaxWindow`
  /// bound). An entry comes in one of two flavours: a *reclaim* (default —
  /// this Mac has a prior claim: a genuine drop, a failed handoff, or a held
  /// set being chased back after wake) or an *adoption* (no prior claim; see
  /// `adoptionProgress`). Main-only.
  private var reconnectWatchlist: [String: Date] = [:]

  /// Ids with a probe/reclaim chain in flight, so overlapping ticks don't
  /// fire a second `HOLDS_ONE` or pair attempt for the same peripheral while
  /// the first is still resolving. Main-only.
  private var reconnectInFlight: Set<String> = []

  /// Per-id bookkeeping for adoption arms; see `adoptionProgress`.
  private struct AdoptionProgress {
    /// Consecutive `HOLDS_ONE` probes that ended peer-absent (unreachable at
    /// the TCP/connect layer). Reset implicitly: any answered probe stands
    /// the adoption down instead.
    var peerAbsentStreak = 0
    /// Local pair attempts made for this adoption so far.
    var pairAttempts = 0
  }

  /// Watchlist entries armed as *adoption*: peripherals this Mac wasn't
  /// holding (they lived on the peer) whose peer has dropped off the network
  /// — slept, shut down, or left. Presence in this map is what distinguishes
  /// an adoption from a reclaim. Adoption is deliberately more polite: it
  /// takes a peripheral only from a *provably absent* peer (per
  /// `continueAdoption`), stands down the moment a live peer answers at all
  /// — "not holding" included, so a prior holder's reclaim or the user
  /// outranks it — and caps its pair attempts. Main-only.
  private var adoptionProgress: [String: AdoptionProgress] = [:]

  /// Ids we released on purpose (handoff, "Remove from PC", sleep), each with
  /// the time it was flagged. The disconnect notification that follows within
  /// `Constants.intentionalReleaseGrace` must not arm the watcher — the
  /// peripheral is meant to leave this Mac. A *later* disconnect is treated as
  /// a genuine drop, so a release whose notification never arrived can't leave
  /// a stale flag that suppresses a real reconnect. Consumed by
  /// `handlePeripheralDisconnected`. Main-only.
  private var intentionalReleases: [String: Date] = [:]

  /// Self-rescheduling one-shot probe timer; runs only while
  /// `reconnectWatchlist` is non-empty, at `Constants.reconnectProbeInterval`.
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

  /// True while any registered peripheral is mid-transition (`.connecting` or
  /// `.releasing`). The full-set switch is blocked while this holds so it can't
  /// issue a re-entrant connect/release on a peripheral that's already pairing
  /// or being handed off. Reads `connectionStates`; main-thread only.
  var isAnyPeripheralTransitioning: Bool {
    peripherals.contains { peripheral in
      let state = connectionState(for: peripheral.id)
      return state == .connecting || state == .releasing
    }
  }

  /// Resolved display type for `peripheral`: the user's manual override if set,
  /// otherwise auto-detected from the name and (when known) its Class of Device.
  func peripheralType(for peripheral: BluetoothPeripheral) -> PeripheralType {
    if let override = typeOverrides[peripheral.id] { return override }
    return PeripheralType.detect(name: peripheral.name, classOfDevice: deviceClasses[peripheral.id])
  }

  /// Set (or, with `nil`, clear → back to automatic) the icon/type override for
  /// a peripheral address. Persisted immediately via the `typeOverrides` didSet.
  func setTypeOverride(_ type: PeripheralType?, for id: String) {
    let apply: () -> Void = { [weak self] in
      guard let self = self else { return }
      if let type {
        self.typeOverrides[id] = type
      } else {
        self.typeOverrides.removeValue(forKey: id)
      }
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
  }

  // MARK: - Initialization

  private override init() {
    super.init()
    loadPeripherals()
    loadTypeOverrides()
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
  /// 2. When `releaseOnSleep` is set and a trusted peer looks present —
  ///    pinned identity, and either Bonjour-active or answering the `.ping`
  ///    reachability poll — release each held peripheral so the peer can
  ///    take it cleanly rather than have it stranded on a Mac that can no
  ///    longer be reached to release it. Either presence signal suffices:
  ///    `isActive` is event-driven and can go stale in both directions
  ///    (sleep proxies keep a sleeping peer's records alive; a missed mDNS
  ///    goodbye leaves a gone peer active), while the poll is fresh to ~30s.
  ///    With no peer around there's no one to hand off to, so we leave them
  ///    bonded.
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

    let networkStore = NetworkDeviceStore.shared
    let shouldRelease =
      releaseOnSleep
      && PairingStore.shared.isPaired
      && networkStore.networkDevices.contains(where: {
        $0.pendingFingerprint == nil && ($0.isActive || networkStore.isReachable($0.id))
      })

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
  /// so anything the peer legitimately took is left alone — and arms the
  /// polite *adoption* flavour for the rest of the registered set: the peer
  /// may have gone to sleep after this Mac did and left its peripherals
  /// behind with no one to hand them over (it can't be asked to release once
  /// it's unreachable). When off, falls back to the original one-shot reclaim
  /// of just the peripherals we released for sleep. Waits
  /// `Constants.wakeReclaimDelay` first so the network can reassociate (and
  /// bonded devices get a moment to reconnect on their own) before any
  /// unreachable-looking peer gets a peripheral grabbed back.
  private func reclaimPeripheralsAfterWake() {
    let connected = connectedBeforeSleep
    let released = peripheralsReleasedForSleep
    connectedBeforeSleep = []
    peripheralsReleasedForSleep = []
    // Even with nothing held before sleep there can be work to do: the
    // adoption sweep below picks up whatever an absent peer was holding.
    guard !connected.isEmpty || (autoReconnect && !peripherals.isEmpty) else { return }

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
          if released.contains(id) { self.intentionalReleases.removeValue(forKey: id) }
          guard self.peripherals.contains(where: { $0.id == id }) else { continue }
          self.armReconnect(id)
        }
        // The rest of the registered set lived on the peer (or nowhere). If
        // the peer is gone too, those peripherals are stranded — adopt them.
        // Already-armed reclaims above are not downgraded by this sweep.
        self.armAdoptionOfUnheldPeripherals()
        return
      }

      // Feature off: original one-shot reclaim, scoped to the peripherals we
      // released for sleep. The registered peer is not gated on `isActive`
      // (Bonjour may not have re-resolved yet, but `executeHoldsOne` actually
      // connects, so reachability is decided there).
      for id in released {
        self.intentionalReleases.removeValue(forKey: id)
        guard let peripheral = self.peripherals.first(where: { $0.id == id }) else { continue }
        guard let device = NetworkDeviceStore.shared.networkDevices.first,
          device.pendingFingerprint == nil,
          PairingStore.shared.isPaired
        else {
          // No trusted peer to ask — none registered, or one flagged as a
          // TOFU identity mismatch. Either way, reclaim locally.
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
    // Resolve the new row's live connection state (and register its disconnect
    // observer) right away. Without this the row reads `.disconnected` until
    // the next snapshot — i.e. the user has to leave and re-open the tab to
    // see an already-connected peripheral show as connected.
    fetchConnectedPeripherals()
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
      setPeripheralError("Couldn't release.", for: peripheral.id)
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
    intentionalReleases.removeValue(forKey: peripheral.id)
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
  ///
  /// If the take fails — or the peer releases but the local connect doesn't
  /// take (a stuck device needing a power-cycle) — the auto-reconnect watcher
  /// keeps trying, gated by `HOLDS_ONE` so it never grabs a device the peer is
  /// actually holding.
  func takePeripheralFromPeer(_ peripheral: BluetoothPeripheral) {
    let networkStore = NetworkDeviceStore.shared
    guard let device = networkStore.networkDevices.first,
      PairingStore.shared.isPaired,
      device.isActive
    else {
      connectPeripheral(peripheral)
      return
    }

    // Peripheral is arriving at this Mac — flash the receiving arrow, the same
    // signal the full-set take raises on the menu-bar icon.
    NotificationCenter.default.post(name: .magicSwitchPeripheralIncoming, object: nil)
    setConnectionState(.connecting, for: peripheral.id)
    schedulePairWatchdog(for: peripheral, announceTimeout: true)
    networkStore.executeUnregisterOne(address: peripheral.id, on: device) {
      [weak self] result in
      guard let self = self else { return }
      switch result {
      case .success:
        // Peer released it; grab it locally. Arm the watcher too, so a local
        // connect that fails (e.g. the device is in the stuck state and needs
        // a power-cycle) keeps retrying instead of leaving it on neither Mac.
        // It self-disarms once we're connected.
        self.connectPeripheralFromPeer(peripheral)
        self.armReconnect(peripheral.id)
      case .failure(.connectionFailed), .failure(.connectTimeout):
        // We never got a TCP connection up, so the peer's machine is
        // unreachable (asleep, off the network, app not running) and isn't
        // holding the peripheral anymore — a Mac that drops off the network
        // has already released its Bluetooth devices. Pair locally instead
        // of stranding the user with an error they can't act on, and arm the
        // watcher as the same retry safety net. We deliberately don't grab on
        // post-connect failures (next case): if the connection opened, the
        // peer's machine is awake and may still actively hold the peripheral.
        self.connectPeripheralFromPeer(peripheral)
        self.armReconnect(peripheral.id)
      case .failure(let err):
        // Reachable peer but the release errored, so we can't be sure it let
        // go. Don't grab it outright (that could yank it from a peer that did
        // take it); arm the HOLDS_ONE-gated watcher, which reclaims it only
        // once the peer confirms it isn't holding it — and recovers the case
        // where the peer released but the ack was lost.
        self.setConnectionState(.disconnected, for: peripheral.id)
        self.armReconnect(peripheral.id)
        self.setPeripheralError("Switch failed.", for: peripheral.id)
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
  /// Preflights the peer with a `.ping` *before* releasing anything: `isActive`
  /// (Bonjour) can lag reality by the mDNS TTL, so a PING that handshakes and
  /// acks is the authoritative "the peer's app is up and will accept a command"
  /// check. If it fails we keep the peripheral on this Mac untouched rather than
  /// release it into a peer that can't pick it up (stranding it on neither).
  /// Falls back to a plain local unregister only when there's no paired peer to
  /// hand to. Mirrors the full-set handoff preflight in
  /// `AppDelegate.handleSwitchAction`.
  ///
  /// If the peer dies *after* the preflight but before it takes the peripheral,
  /// it's rolled back onto this Mac rather than left stranded — via the
  /// `HOLDS_ONE`-gated watcher.
  func sendPeripheralToPeer(_ peripheral: BluetoothPeripheral) {
    let networkStore = NetworkDeviceStore.shared
    guard let device = networkStore.networkDevices.first, PairingStore.shared.isPaired else {
      // No peer to hand off to — releasing locally is the only thing we can do.
      unregisterFromPC(peripheral)
      return
    }
    // Show "Releasing…" right away so the row greys out and stops accepting
    // clicks while the preflight below runs — it can take up to 5s, and until
    // it returns the button would otherwise still read "Release". On preflight
    // failure we revert to `.connected`; on success `performSendHandoff`
    // re-asserts `.releasing` after its `unregisterFromPC` (which lands
    // `.disconnected`) in the same run-loop tick, so there's no flicker.
    setConnectionState(.releasing, for: peripheral.id)
    networkStore.executeCommand(.ping, on: device) { [weak self] preflight in
      DispatchQueue.main.async {
        guard let self = self else { return }
        switch preflight {
        case .failure(let err):
          // Peer unreachable — nothing released, peripheral stays on this Mac.
          self.setConnectionState(.connected, for: peripheral.id)
          self.setPeripheralError("Other Mac unreachable.", for: peripheral.id)
          NotificationManager.showNotification(
            title: "Switch Cancelled",
            body:
              "Couldn't reach \(device.name) (\(err.userMessage)) — keeping \(peripheral.name) on this Mac.",
            identifier: "send-preflight-failed-\(peripheral.id)"
          )
        case .success:
          self.performSendHandoff(peripheral, to: device)
        }
      }
    }
  }

  /// Release `peripheral` locally, wait for the IOBluetooth-level disconnect,
  /// then ask the peer to take it. Split out of `sendPeripheralToPeer` so the
  /// `.ping` preflight gates entry — by the time we get here the peer has just
  /// acked, but it can still die before `CONNECT_ONE`, so the failure arms
  /// re-pair this Mac rather than strand the peripheral.
  private func performSendHandoff(_ peripheral: BluetoothPeripheral, to device: NetworkDevice) {
    let networkStore = NetworkDeviceStore.shared
    // Peripheral is leaving this Mac for the peer — flash the sending arrow.
    NotificationCenter.default.post(name: .magicSwitchPeripheralOutgoing, object: nil)
    unregisterFromPC(peripheral)
    // Show "Releasing…" for the whole handoff — the mirror of the peer's
    // "Pairing…". Set *after* `unregisterFromPC` (which lands `.disconnected`)
    // so it isn't immediately clobbered; the disconnect notification and the
    // periodic fetch both skip a `.releasing` row, so it persists until a
    // terminal branch below resolves it.
    setConnectionState(.releasing, for: peripheral.id)
    waitForLocalDisconnect(of: peripheral) { [weak self] success in
      guard let self = self else { return }
      guard success else {
        // It never disconnected, so it's still on this Mac — drop back to
        // connected rather than leave it stuck "Releasing…".
        self.setConnectionState(.connected, for: peripheral.id)
        self.setPeripheralError("Didn't disconnect.", for: peripheral.id)
        NotificationManager.showNotification(
          title: "Couldn't Switch",
          body: "\(peripheral.name) didn't disconnect from this Mac.",
          identifier: "send-disconnect-failed-\(peripheral.id)"
        )
        return
      }
      networkStore.executeConnectOne(address: peripheral.id, on: device) { [weak self] result in
        guard let self = self else { return }
        switch result {
        case .success:
          // Peer took it — it now lives over there, so we're disconnected.
          self.setConnectionState(.disconnected, for: peripheral.id)
        case .failure(.connectionFailed), .failure(.connectTimeout):
          // Peer acked the preflight but dropped before CONNECT_ONE, so it
          // didn't take the peripheral. We already released it locally, so roll
          // it back onto this Mac rather than strand it on neither — the same
          // recovery the full-set handoff does — and arm the watcher in case
          // the reconnect needs a power-cycle.
          self.clearIntentionalRelease(peripheral.id)
          self.connectPeripheral(peripheral)
          self.armReconnect(peripheral.id)
          NotificationManager.showNotification(
            title: "Couldn't Switch",
            body: "Couldn't hand \(peripheral.name) to \(device.name); keeping it on this Mac.",
            identifier: "send-connect-failed-\(peripheral.id)"
          )
        case .failure(let err):
          // Reachable peer but it errored, so it may or may not have taken the
          // peripheral. Don't grab it back outright (that could yank it from a
          // peer that did take it); arm the HOLDS_ONE-gated watcher, which
          // reclaims it only if the peer confirms it isn't holding it.
          self.clearIntentionalRelease(peripheral.id)
          // We did release it locally, so we're disconnected regardless of
          // where it ended up; clear the "Releasing…" row.
          self.setConnectionState(.disconnected, for: peripheral.id)
          self.armReconnect(peripheral.id)
          self.setPeripheralError("Handoff failed.", for: peripheral.id)
          NotificationManager.showNotification(
            title: "Couldn't Switch",
            body:
              "Couldn't hand \(peripheral.name) to \(device.name): \(err.userMessage)",
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

  // MARK: - Full-Set Handoff Display

  /// Mark every registered peripheral "Releasing…" for the menu-bar full-set
  /// handoff (the per-peripheral send drives its own row in `performSendHandoff`).
  /// Call after the local releases land; pair with `finishFullSetRelease(success:)`.
  func beginFullSetRelease() {
    peripherals.forEach { setConnectionState(.releasing, for: $0.id) }
  }

  /// End the full-set "Releasing…" display. On success the peripherals now live
  /// on the peer, so they read `.disconnected`; on a non-success that didn't
  /// actually move them (e.g. the local disconnect failed), restore the live
  /// state. The `CONNECT_ALL`-failure rollback re-pairs locally via
  /// `connectPeripheral` instead, which clears the row itself — don't call this
  /// there.
  func finishFullSetRelease(success: Bool) {
    if success {
      peripherals.forEach { setConnectionState(.disconnected, for: $0.id) }
    } else {
      fetchConnectedPeripherals(overrideTransient: true)
    }
  }

  func connectPeripheral(_ peripheral: BluetoothPeripheral) {
    connectPeripheral(
      peripheral,
      announcePairTimeout: true,
      refreshPairingBeforeConnect: false,
      completion: nil
    )
  }

  func connectPeripheralFromPeer(_ peripheral: BluetoothPeripheral) {
    connectPeripheralFromPeer(peripheral, completion: nil)
  }

  func connectPeripheralFromPeer(
    _ peripheral: BluetoothPeripheral,
    completion: ((Bool) -> Void)?
  ) {
    connectPeripheral(
      peripheral,
      announcePairTimeout: true,
      refreshPairingBeforeConnect: true,
      completion: completion
    )
  }

  /// - Parameter announcePairTimeout: whether a pair-watchdog timeout should
  ///   raise a user notification. Interactive callers pass `true`; the
  ///   auto-reconnect watcher passes `false` so its retries against a stuck
  ///   device don't spam "Pairing Timed Out".
  /// - Parameter refreshPairingBeforeConnect: whether to remove a stale local
  ///   pairing record before pairing. Use this only while taking a peripheral
  ///   from the peer: Magic peripherals can sit at `paired=true` but refuse
  ///   `openConnection()` until the target Mac re-pairs.
  private func connectPeripheral(
    _ peripheral: BluetoothPeripheral,
    announcePairTimeout: Bool,
    refreshPairingBeforeConnect: Bool,
    completion: ((Bool) -> Void)?
  ) {
    if let completion = completion {
      addConnectResultWaiter(for: peripheral.id, completion)
    }
    setConnectionState(.connecting, for: peripheral.id)
    schedulePairWatchdog(for: peripheral, announceTimeout: announcePairTimeout)

    bluetoothQueue.async { [weak self] in
      guard let self = self else { return }

      guard var btDevice = IOBluetoothDevice(addressString: peripheral.id) else {
        print("\(peripheral.name) not found")
        self.setConnectionState(.disconnected, for: peripheral.id)
        return
      }

      guard IOBluetoothHostController.default().powerState != kBluetoothHCIPowerStateOFF else {
        print("Bluetooth is turned off")
        self.setConnectionState(.disconnected, for: peripheral.id)
        return
      }

      if refreshPairingBeforeConnect, btDevice.isConnected() {
        self.setConnectionState(.connected, for: peripheral.id)
        self.registerForDisconnect(device: btDevice, address: peripheral.id)
        return
      }

      if refreshPairingBeforeConnect, btDevice.isPaired() {
        if btDevice.responds(to: Selector(("remove"))) {
          btDevice.perform(Selector(("remove")))
          print("Removed stale local pairing before taking \(peripheral.name)")
          // `-remove` tears the bond down asynchronously in the Bluetooth
          // daemon; re-pairing before it settles can race the unbond and fail.
          // A short fixed settle is simpler than a poll loop here (there's no
          // condition to poll — just "give the daemon a moment"). We're on
          // `bluetoothQueue`, a background serial queue, so this briefly stalls
          // other queued BT work but never the main thread / UI.
          Thread.sleep(forTimeInterval: 0.5)
          if let refreshed = IOBluetoothDevice(addressString: peripheral.id) {
            btDevice = refreshed
          }
        } else {
          print("Cannot refresh stale pairing for \(peripheral.name): remove selector unavailable")
        }
      }

      // Already bonded to this Mac. A peripheral we're holding that merely
      // dropped — power cycle, briefly out of range, wake — keeps its link
      // key, so macOS reconnects it on its own. Running
      // `IOBluetoothDevicePair.start()` on a bonded device re-runs bonding and
      // forces a disconnect/reconnect cycle that fights that reconnect (and
      // strands the UI at "(Pairing…)" — the pair callback never fires for an
      // already-connected device, and `fetchConnectedPeripherals` won't
      // overwrite the in-flight `.connecting`). So adopt the live connection,
      // or just open one — never re-pair. For peer takeovers, a stale
      // `paired=true connected=false` record is removed above so this branch
      // does not mask the required re-pair.
      if !refreshPairingBeforeConnect, btDevice.isConnected() || btDevice.isPaired() {
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
    fetchConnectedPeripherals(overrideTransient: false)
  }

  /// - Parameter overrideTransient: when `true`, a live read replaces even an
  ///   in-flight `.connecting`/`.releasing` state. `false` (the usual path)
  ///   protects those transients from a stale snapshot (the Peripheral tab
  ///   polls this on a timer); `finishFullSetRelease(success:)` passes `true`
  ///   to restore the real state after an aborted handoff.
  private func fetchConnectedPeripherals(overrideTransient: Bool) {
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
        var classes: [String: UInt32] = [:]

        for device in pairedDevices {
          guard let address = device.addressString else { continue }
          if device.isConnected() {
            connectedAddresses.insert(address)
          }
          classes[address] = UInt32(device.classOfDevice)
          paired.append(
            BluetoothPeripheral(id: address, name: device.name ?? "Unknown Device")
          )
        }

        DispatchQueue.main.async {
          // Snapshot all paired devices; `availablePeripherals` filters out
          // registered ones at read time. Filtering here instead would mean
          // unregistering a peripheral can't immediately surface it under
          // "Available" until the next fetch (e.g. tab switch).
          // Assign only on change. The Peripheral tab polls this on a timer, so
          // an unconditional reassign would fire `objectWillChange` every tick
          // (needless re-renders, and it could dismiss an open type picker).
          if self.discoveredPeripherals != paired { self.discoveredPeripherals = paired }
          if self.deviceClasses != classes { self.deviceClasses = classes }
          // Renaming a device in System Settings → Bluetooth should propagate
          // to our stored list (and thus the dropdown / Settings), so reconcile
          // registered names against the live ones we just read.
          self.refreshRegisteredNames(from: paired)
          for id in registeredIDs {
            let isConnected = connectedAddresses.contains(id)
            // Don't overwrite an in-flight .connecting/.releasing state with a
            // stale read (unless a caller explicitly wants the live value).
            if !overrideTransient,
              self.connectionStates[id] == .connecting || self.connectionStates[id] == .releasing
            {
              continue
            }
            let newState: PeripheralConnectionState = isConnected ? .connected : .disconnected
            if self.connectionStates[id] != newState { self.connectionStates[id] = newState }
            if isConnected {
              if self.disconnectObservers[id] == nil,
                let device = IOBluetoothDevice(addressString: id)
              {
                self.registerForDisconnect(device: device, address: id)
              }
              // It's back on its own (e.g. macOS reconnected a bonded device
              // on power-on, surfaced via the global connect observer). Adopt
              // it event-driven and stop watching, instead of waiting for the
              // next probe tick to notice.
              self.disarmReconnect(id)
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
      DispatchQueue.main.async {
        self.pairTimers[address]?.cancel()
        self.pairTimers.removeValue(forKey: address)
        let announce = self.pairTimeoutShouldAnnounce.removeValue(forKey: address) ?? true
        self.setPeripheralError("Pairing failed.", for: address)
        if announce {
          let name = device.name ?? address
          NotificationManager.showNotification(
            title: "Pairing Failed",
            body:
              "Couldn't pair \(name). Turn it off and on, then try switching again.",
            identifier: "pair-failed-\(address)"
          )
        }
      }
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

  @objc func devicePairingUserConfirmationRequest(
    _ sender: Any!,
    numericValue: BluetoothNumericValue
  ) {
    guard let pair = sender as? IOBluetoothDevicePair,
      let address = pair.device()?.addressString
    else {
      return
    }
    print("Accepting Bluetooth pairing confirmation for \(address): \(numericValue)")
    pair.replyUserConfirmation(true)
  }

  @objc func devicePairingPINCodeRequest(_ sender: Any!) {
    guard let pair = sender as? IOBluetoothDevicePair,
      let address = pair.device()?.addressString
    else {
      return
    }
    print("Bluetooth pairing requested a PIN code for \(address)")
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
      // Don't clobber an in-flight transient: a fresh `.connecting` attempt
      // from a pre-empt path, or a `.releasing` handoff whose own release
      // *caused* this disconnect (the send path resolves that row itself).
      guard self.connectionStates[address] != .connecting,
        self.connectionStates[address] != .releasing
      else { return }
      self.connectionStates[address] = .disconnected
      if let releasedAt = self.intentionalReleases.removeValue(forKey: address),
        Date().timeIntervalSince(releasedAt) < Constants.intentionalReleaseGrace
      {
        // We let this one go on purpose (handoff / sleep) — don't reclaim it.
        // A flag older than the grace window is stale (its own disconnect
        // never arrived); we've cleared it above and fall through to treat
        // this as a genuine drop.
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
    let apply: () -> Void = { [weak self] in
      guard let self = self else { return }
      self.connectionStates[id] = state
      // A fresh attempt (.connecting) or a success (.connected) clears any prior
      // inline error; a failure that ends in .disconnected keeps it on screen.
      if state != .disconnected { self.clearPeripheralError(id) }
      if state == .connected {
        self.completeConnectResultWaiters(for: id, success: true)
      } else if state == .disconnected {
        self.completeConnectResultWaiters(for: id, success: false)
      }
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
  }

  private func addConnectResultWaiter(
    for id: String,
    _ completion: @escaping (Bool) -> Void
  ) {
    let apply: () -> Void = { [weak self] in
      self?.connectResultWaiters[id, default: []].append(completion)
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
  }

  private func completeConnectResultWaiters(for id: String, success: Bool) {
    guard let waiters = connectResultWaiters.removeValue(forKey: id) else { return }
    waiters.forEach { $0(success) }
  }

  /// Set the inline error for a peripheral, and fade it after 5s so it doesn't
  /// linger on the row. `setConnectionState` clears it sooner on a new attempt.
  private func setPeripheralError(_ message: String, for id: String) {
    let apply: () -> Void = { [weak self] in
      guard let self = self else { return }
      self.peripheralOperationError[id] = message
      self.peripheralErrorTimers[id]?.cancel()
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(deadline: .now() + 5)
      timer.setEventHandler { [weak self] in self?.clearPeripheralError(id) }
      timer.resume()
      self.peripheralErrorTimers[id] = timer
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
  }

  /// Clear a peripheral's inline error and cancel its fade timer (main thread).
  private func clearPeripheralError(_ id: String) {
    peripheralErrorTimers[id]?.cancel()
    peripheralErrorTimers[id] = nil
    peripheralOperationError[id] = nil
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
    setConnectionState(.disconnected, for: address)
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

  /// Arm the watcher in *adoption* mode for every registered peripheral not
  /// currently connected to this Mac. Called when the peer stops being part
  /// of the picture: this Mac just woke (the peer may have slept while we
  /// did), or the reachability poll watched the peer drop off the network.
  /// Arming broadly is safe because adoption only ever takes from a provably
  /// absent peer (see `continueAdoption`): entries against a live peer stand
  /// down on their first answered probe, and `armReconnect` never downgrades
  /// an existing reclaim entry to an adoption.
  func armAdoptionOfUnheldPeripherals() {
    // Main-only state; called from the reachability poll's completion too.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.armAdoptionOfUnheldPeripherals() }
      return
    }
    guard autoReconnect else { return }
    for peripheral in peripherals where connectionState(for: peripheral.id) == .disconnected {
      armReconnect(peripheral.id, adoption: true)
    }
  }

  /// Arm the watcher for `id`: it'll be probed on the probe cadence and
  /// reclaimed once it's back in range and the peer isn't using it. No-op when
  /// the feature is off or the peripheral isn't registered to us. Preserves the
  /// original arm time on re-arm so the `reconnectMaxWindow` bound counts from
  /// the first drop. `adoption` marks the polite no-prior-claim flavour; it
  /// only applies to a *fresh* arm — re-arming an existing reclaim as an
  /// adoption keeps the reclaim, while an explicit (non-adoption) re-arm
  /// upgrades an adoption to a full reclaim.
  private func armReconnect(_ id: String, adoption: Bool = false) {
    // The watcher dictionaries/sets and timer are main-only, but deliberate
    // releases (`unregisterFromPC` during a handoff) reach the watcher from the
    // outgoing-connection queue — hop to main so we never mutate this state
    // concurrently with `reconnectTick` / `handlePeripheralDisconnected`.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.armReconnect(id, adoption: adoption) }
      return
    }
    guard autoReconnect, peripherals.contains(where: { $0.id == id }) else { return }
    if reconnectWatchlist[id] == nil {
      reconnectWatchlist[id] = Date()
      if adoption { adoptionProgress[id] = AdoptionProgress() }
      print("Auto-reconnect: watching \(id)\(adoption ? " (adoption)" : "")")
      // If the timer is mid-interval, pull the next probe forward so this
      // newcomer is checked promptly rather than waiting out the rest of the
      // current interval.
      reconnectTimer?.schedule(deadline: .now(), leeway: Constants.reconnectProbeLeeway)
    } else if !adoption {
      // An explicit claim (genuine drop, failed handoff, wake reclaim) on an
      // entry armed as adoption upgrades it: from here on, a live peer
      // answering "not holding" no longer stands the watcher down.
      adoptionProgress.removeValue(forKey: id)
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
    adoptionProgress.removeValue(forKey: id)
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
    intentionalReleases[id] = Date()
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
    intentionalReleases.removeValue(forKey: id)
  }

  private func startReconnectTimerIfNeeded() {
    guard reconnectTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    // Fire immediately, then re-arm one-shot after each pass (see
    // `scheduleNextReconnectTick`). The immediate first tick keeps wake-time
    // reclaim and manual power-cycle recovery prompt.
    timer.schedule(deadline: .now(), leeway: Constants.reconnectProbeLeeway)
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      self.reconnectTick()
      self.scheduleNextReconnectTick()
    }
    timer.resume()
    reconnectTimer = timer
  }

  /// Re-arm the (one-shot) probe timer for the next pass at the constant probe
  /// cadence. No-op when `reconnectTick` already tore the timer down (watchlist
  /// emptied / feature off).
  private func scheduleNextReconnectTick() {
    guard let timer = reconnectTimer else { return }
    timer.schedule(
      deadline: .now() + Constants.reconnectProbeInterval,
      leeway: Constants.reconnectProbeLeeway)
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
      case .connecting, .releasing:
        continue  // an attempt / handoff is already in flight
      case .disconnected:
        probeAndReclaim(peripheral)
      }
    }
  }

  /// Checks live IOBluetooth state for `peripheral` off the main queue. If it's
  /// already connected, adopts it; if it's back in range, hands off to
  /// `reclaimIfPeerIsFree`, which consults the peer (`HOLDS_ONE`) before
  /// reclaiming — Magic devices stay bonded to *both* Macs, so being paired
  /// here does not mean the peer isn't actively using it. Marks the id
  /// in-flight so overlapping ticks skip it until this resolves.
  private func probeAndReclaim(_ peripheral: BluetoothPeripheral) {
    let id = peripheral.id
    reconnectInFlight.insert(id)
    bluetoothQueue.async { [weak self] in
      guard let self = self else { return }
      // RSSI is the "is it back?" signal — `invalidRSSI` (127) means we can't
      // see it, the same gate `connectPeripheral` uses. Cheap while absent.
      var alreadyConnected = false
      var reachable = false
      if IOBluetoothHostController.default().powerState != kBluetoothHCIPowerStateOFF,
        let device = IOBluetoothDevice(addressString: id)
      {
        alreadyConnected = device.isConnected()
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
      let device = NetworkDeviceStore.shared.networkDevices.first,
      device.pendingFingerprint == nil
    else {
      reconnectInFlight.remove(id)
      if adoptionProgress[id] != nil {
        // No trusted peer to consult and no prior claim on the peripheral —
        // stand down rather than grab one whose holder we can't even ask.
        disarmReconnect(id)
        return
      }
      // No trusted peer to consult — none registered, or one flagged as a
      // TOFU identity mismatch. Either way it's ours; reclaim locally rather
      // than auto-probing an untrusted peer with our now-stale key.
      connectPeripheral(
        peripheral,
        announcePairTimeout: false,
        refreshPairingBeforeConnect: false,
        completion: nil
      )
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
        case .failure(let failure):
          guard self.reconnectWatchlist[id] != nil,
            self.connectionState(for: id) == .disconnected
          else { return }
          if self.adoptionProgress[id] != nil {
            self.continueAdoption(of: peripheral, after: failure)
            return
          }
          print("Auto-reconnect: reclaiming \(peripheral.name)")
          self.connectPeripheral(
            peripheral,
            announcePairTimeout: false,
            refreshPairingBeforeConnect: false,
            completion: nil
          )
        }
      }
    }
  }

  /// Adoption-flavoured continuation of `reclaimIfPeerIsFree`'s failure arm
  /// (runs on main). A reclaim takes the peripheral on *any* `HOLDS_ONE`
  /// failure; an adoption — no prior claim — takes it only once the peer is
  /// provably absent: unreachable at the connect layer for
  /// `adoptionRequiredAbsentStreak` consecutive probes. A peer that answers
  /// at all — an explicit "not holding" (`.bodyFailed`) included — outranks
  /// us, so stand down and leave the move to its reclaim or to the user.
  /// Pair attempts are capped: a free peripheral pairs on the first try, so
  /// repeated failures mean it's busy with a peer we can't reach.
  private func continueAdoption(of peripheral: BluetoothPeripheral, after failure: OutgoingFailure)
  {
    let id = peripheral.id
    guard var progress = adoptionProgress[id] else { return }
    switch failure {
    case .connectionFailed, .connectTimeout:
      progress.peerAbsentStreak += 1
    default:
      // The peer's machine accepted the TCP connection even though the probe
      // failed past that point — that's a live peer, not an absent one.
      print("Adoption: \(peripheral.name) — peer is up; standing down")
      disarmReconnect(id)
      return
    }
    guard progress.peerAbsentStreak >= Constants.adoptionRequiredAbsentStreak else {
      adoptionProgress[id] = progress
      return
    }
    guard progress.pairAttempts < Constants.adoptionMaxPairAttempts else {
      print(
        "Adoption: giving up on \(peripheral.name) after \(progress.pairAttempts) pair attempts")
      disarmReconnect(id)
      return
    }
    progress.pairAttempts += 1
    adoptionProgress[id] = progress
    print("Adoption: taking \(peripheral.name) (attempt \(progress.pairAttempts))")
    connectPeripheral(
      peripheral,
      announcePairTimeout: false,
      refreshPairingBeforeConnect: false,
      completion: nil
    )
  }

  // MARK: - Private Methods

  /// Reconcile registered peripheral names against the live paired-device list,
  /// so a rename in System Settings → Bluetooth shows up in our stored list.
  /// Only rewrites a name that actually changed to a non-empty live value, and
  /// leaves alone peripherals not currently paired here (e.g. handed to the
  /// peer). Runs on main; assigning `peripherals` saves and re-renders.
  private func refreshRegisteredNames(from liveDevices: [BluetoothPeripheral]) {
    let liveNames = Dictionary(liveDevices.map { ($0.id, $0.name) }) { first, _ in first }
    var changed = false
    let refreshed = peripherals.map { peripheral -> BluetoothPeripheral in
      guard let live = liveNames[peripheral.id],
        !live.isEmpty, live != "Unknown Device", live != peripheral.name
      else { return peripheral }
      changed = true
      var updated = peripheral
      updated.name = live
      return updated
    }
    if changed { peripherals = refreshed }
  }

  private func savePeripherals() {
    do {
      let encoded = try JSONEncoder().encode(peripherals)
      peripheralsData = encoded
    } catch {
      print("Failed to save peripherals: \(error)")
    }
  }

  private func saveTypeOverrides() {
    do {
      typeOverridesData = try JSONEncoder().encode(typeOverrides)
    } catch {
      print("Failed to save type overrides: \(error)")
    }
  }

  private func loadTypeOverrides() {
    guard !typeOverridesData.isEmpty else { return }
    do {
      typeOverrides = try JSONDecoder().decode(
        [String: PeripheralType].self, from: typeOverridesData)
    } catch {
      print("Failed to load type overrides: \(error)")
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
