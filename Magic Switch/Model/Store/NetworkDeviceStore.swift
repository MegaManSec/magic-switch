import Foundation
import Network
import SwiftUI

/// Protocol defining the interface for network device management operations
protocol NetworkDeviceManageable {
  /// List of registered network devices
  var networkDevices: [NetworkDevice] { get }
  /// List of discovered network devices
  var discoveredNetworkDevices: [NetworkDevice] { get }
  /// List of available network devices that can be registered
  var availableNetworkDevices: [NetworkDevice] { get }

  /// Registers a new network device
  func registerNetworkDevice(device: NetworkDevice)
  /// Removes a registered network device
  func removeNetworkDevice(device: NetworkDevice)
  /// Updates the information of a network device
  func updateNetworkDevice(_ device: NetworkDevice)
}

/// A user-initiated Device-tab operation currently in flight to a peer.
/// Tracked in `NetworkDeviceStore` (not the view) so the row can disable its
/// buttons and keep rendering progress across Settings tab switches — the
/// view's local `@State` is reset when the tab is left and re-entered.
enum DeviceOperation {
  case ping
  case sync(count: Int)
}

/// Manages the state and operations of network devices
final class NetworkDeviceStore: ObservableObject, NetworkDeviceManageable {
  // MARK: - Singleton

  static let shared = NetworkDeviceStore()

  // MARK: - Dependencies

  private let servicePublisher = ServicePublisher()
  private let serviceBrowser = ServiceBrowser()

  // MARK: - Properties

  @Published private(set) var networkDevices: [NetworkDevice] = []
  @Published private(set) var discoveredNetworkDevices: [NetworkDevice] = []
  @AppStorage("networkDevices") private var networkDevicesData: Data = Data()

  /// Last active-probe result per device id (runtime only, never persisted).
  /// Combined signal: Bonjour resolve/withdraw write it on each transition,
  /// and a repeating secure-channel probe (plus one on menu open) keeps it
  /// honest between Bonjour events — so a peer that vanished without a
  /// Bonjour goodbye flips to false within one poll interval instead of
  /// waiting out the mDNS TTL.
  @Published private(set) var deviceReachability: [String: Bool] = [:]
  private var reachabilityTimer: DispatchSourceTimer?
  private static let reachabilityInterval: TimeInterval = 30
  /// Delay before the fast off-cycle recheck that confirms a *first* missed
  /// poll (see `scheduleFastReachabilityRecheck`). Short enough to collapse the
  /// ~30s worst-case detection latency that otherwise leaves a vanished peer's
  /// peripherals unclaimed while this Mac is awake; long enough that a single
  /// dropped packet clears on the retry rather than arming adoption.
  private static let fastRecheckDelay: TimeInterval = 3

  /// Body-read timeout for the two commands whose receiver only acks after it
  /// has actually finished (re-)pairing — `CONNECT_ALL` and `CONNECT_ONE` —
  /// rather than acking on receipt. It must exceed the receiver's worst-case
  /// connect time (its pair watchdog, `pairTimeout`, is 60s) so the sender
  /// waits for the real result instead of giving up early; and the receiver's
  /// `IncomingConnection.idleTimeout` must stay >= this so it doesn't idle-kill
  /// the connection before sending that ack. Every other command acks
  /// immediately and uses `OutgoingConnection`'s 5s default.
  private static let handoffBodyTimeout: TimeInterval = 75

  /// Consecutive failed `.ping` polls per device id (runtime only). Drives
  /// the peer-vanished adoption trigger: one missed poll is routine (Wi-Fi
  /// blip, mid-transition), two in a row is a peer that's genuinely gone —
  /// asleep, shut down, off the network. The second miss is now reached in a
  /// few seconds (see `scheduleFastReachabilityRecheck`) rather than across two
  /// 30s polls. Main-only.
  private var consecutivePollFailures: [String: Int] = [:]

  /// Devices with a fast off-cycle reachability recheck already scheduled, so
  /// overlapping triggers (a missed poll and a Bonjour withdraw landing
  /// together) don't stack up multiple rechecks. Main-only.
  private var pendingFastRecheck: Set<String> = []

  /// Advertised names with a rename-migration proof ping already in flight, so
  /// a burst of resolves for the same service doesn't fan out into a burst of
  /// pings. Main-only. See `migrateRenamedPeerIfNeeded`.
  private var pendingMigrationProofs: Set<String> = []

  /// Ids that entered `discoveredNetworkDevices` via INTRODUCE. They never
  /// get a Bonjour goodbye, so `pollReachability` expires unrefreshed ones —
  /// else a stale entry blocks `renameCandidateID` forever. Main-only.
  private var introducedIDs: Set<String> = []
  private static let introducedDeviceTTL: TimeInterval = 2.5 * reachabilityInterval

  /// In-flight Ping/Sync per device id. Set when the user taps Ping/Sync on the
  /// Macs tab and cleared when the op finishes; the view both disables the
  /// buttons and renders the "Pinging…/Syncing…" line off this, so they survive
  /// leaving and re-entering the tab (the view's own `@State` wouldn't).
  @Published private(set) var inFlightOperations: [String: DeviceOperation] = [:]

  // MARK: - Computed Properties

  var availableNetworkDevices: [NetworkDevice] {
    // "Self" is recognised by address, not by name. When two Macs share a
    // device name, mDNS renames one of the advertised services, so the old
    // name-based check (`discovered.name != Host.current().localizedName`)
    // made a Mac hide its real peer (same name) while listing itself
    // (renamed). The address we resolve for our own advertised service is
    // always one of this machine's interface addresses; a peer's never is.
    let localHosts = Self.localAddresses()
    return discoveredNetworkDevices.filter { discovered in
      let isNotSelf = !localHosts.contains(Self.normalizeHost(discovered.host))
      let isNotRegistered = !networkDevices.contains(where: { $0.id == discovered.id })
      return isNotSelf && isNotRegistered
    }
  }

  // MARK: - Initialization

  private init() {
    loadNetworkDevices()
    startServices()
    startReachabilityPolling()
  }

  deinit {
    stopServices()
    reachabilityTimer?.cancel()
  }

  // MARK: - Service Management

  private func startServices() {
    servicePublisher.startPublishing()
    serviceBrowser.startBrowsing()
  }

  private func stopServices() {
    servicePublisher.stopPublishing()
    serviceBrowser.stopBrowsing()
  }

  // MARK: - Public Methods

  func registerNetworkDevice(device: NetworkDevice) {
    // Don't drop from `discoveredNetworkDevices`; `availableNetworkDevices`
    // filters by `!networkDevices.contains` at read time. Dropping here
    // would mean `removeNetworkDevice` can't re-surface the Mac under
    // "Macs Found on the Network" until the next Bonjour resolution.
    networkDevices.append(device)
    saveNetworkDevices()
  }

  func removeNetworkDevice(device: NetworkDevice) {
    networkDevices.removeAll { $0.id == device.id }
    saveNetworkDevices()
  }

  func updateNetworkDevice(_ device: NetworkDevice) {
    // Never let an advertisement re-point a registered record at this Mac.
    // Our own service carries the *same* `fp` as the peer — it's a hash of the
    // shared PSK — so `update(with:)` would take it as a trusted routing
    // update. That is reachable without an attacker: when both Macs share a
    // computer name, mDNS gives one of them a "Name (2)" suffix, and if that
    // suffix is the name registered for the peer, this Mac starts sending its
    // own switch commands to itself — releasing every peripheral and
    // re-pairing it locally (a multi-second loss of keyboard and trackpad)
    // while the real peer gets nothing. Self is recognised by address, the
    // same way `availableNetworkDevices` does it.
    guard !Self.localAddresses().contains(Self.normalizeHost(device.host)) else { return }
    migrateRenamedPeerIfNeeded(for: device)
    if let index = networkDevices.firstIndex(where: { $0.id == device.id }) {
      // The poll's INTRODUCE lands here every 30s; don't rewrite AppStorage
      // and re-render observers when nothing changed.
      let prior = networkDevices[index]
      if prior.host == device.host, prior.port == device.port,
        prior.fingerprint == device.fingerprint, prior.isActive == device.isActive,
        prior.pendingFingerprint == nil
      {
        if deviceReachability[device.id] != device.isActive {
          deviceReachability[device.id] = device.isActive
        }
        return
      }
      let priorFingerprint = prior.fingerprint
      networkDevices[index].update(with: device)
      saveNetworkDevices()
      // Fold the Bonjour signal into reachability: a fresh resolve is a good
      // indication the peer is up; a mismatch (isActive == false) keeps it
      // greyed. The `.ping` poll refines this between Bonjour events.
      deviceReachability[device.id] = networkDevices[index].isActive
      if let prior = priorFingerprint,
        let incoming = device.fingerprint,
        prior != incoming
      {
        NotificationManager.showNotification(
          title: "Identity Mismatch",
          body:
            "\(device.name) is advertising a new pairing key. Open Settings → Macs and choose Trust if you re-paired the other Mac yourself.",
          identifier: "identity-mismatch-\(device.id)"
        )
      }
    }
  }

  /// A peer proved the pairing key and stated its listen endpoint
  /// (`INTRODUCE`). Runs through the same pipeline as a Bonjour resolve, so
  /// TOFU pinning, the self-address guard, and rename migration all apply —
  /// with a stronger source: the fingerprint was proved by the handshake,
  /// not read from a cleartext TXT record.
  func ingestIntroducedPeer(name: String, host: String, port: Int, provedFingerprint: String) {
    // Without Bonjour's collision rename, a same-named peer would fight this
    // Mac over one name-keyed entry. Refuse; renaming a Mac is the fix.
    guard !isLocalName(name) else {
      print("Refusing INTRODUCE from a peer using this Mac's own name: \(name)")
      return
    }
    introducedIDs.insert(name)
    let device = NetworkDevice(
      id: name,
      name: name,
      host: host,
      port: port,
      isActive: true,
      fingerprint: provedFingerprint
    )
    addDiscoveredNetworkDevice(device)
    updateNetworkDevice(device)
    // After the update: if it just parked this record pending exactly the
    // proved key, the proof supersedes the warning in the same tick (the
    // handshake-time resolve hooks fired before these frames existed).
    resolvePendingFingerprint(provedByHandshake: provedFingerprint)
  }

  /// A Mac's Bonjour service name follows its computer name, and `id` *is*
  /// that name — so a renamed peer advertises as a brand-new identity while
  /// its registered record (under the old name) never hears another update and
  /// sits unreachable forever. When an advertisement *proves* it holds the
  /// pairing key, and the registered record's own name has gone off the air,
  /// move that record to the new name in place.
  ///
  /// The proof is a `.ping` completed over the secure channel — deliberately
  /// not the `fp` in the TXT record. That fingerprint is the first four bytes
  /// of SHA256(PSK) published in cleartext multicast, and *both* Macs
  /// advertise the identical value, so anyone who can listen on the LAN can
  /// echo it. Gating on fp alone would let a bystander advertise under any
  /// unused name while the real peer sleeps and capture its record — and
  /// stickily, because the record would then be keyed to the impostor's name,
  /// leaving the real peer unable to win it back (its own name is no longer
  /// registered) short of a manual Remove and Add. Completing a ping requires
  /// the PSK itself, which the fingerprint does not reveal.
  ///
  /// Remaining guards: the advertised name must not already be registered; the
  /// record must not be parked behind an unresolved identity mismatch (else a
  /// migration would silently cancel a Trust the user never gave); exactly one
  /// record may match, so ambiguity never picks a victim; and never migrate
  /// toward this Mac's own advertisement.
  ///
  /// Note this can't follow a rename that also re-paired: a new pairing key
  /// matches no pin, which is the Identity Mismatch path and the user's
  /// explicit Trust. A ping also can't distinguish the same Mac renamed from a
  /// *different* Mac paired with the same code — both hold the key — which is
  /// why the notification asks the user to confirm which Mac is listed.
  private func migrateRenamedPeerIfNeeded(for discovered: NetworkDevice) {
    guard let incoming = discovered.fingerprint,
      !networkDevices.contains(where: { $0.id == discovered.id }),
      !Self.localAddresses().contains(Self.normalizeHost(discovered.host)),
      !pendingMigrationProofs.contains(discovered.id),
      let candidateID = renameCandidateID(forFingerprint: incoming)
    else { return }

    pendingMigrationProofs.insert(discovered.id)
    // `on: discovered` aims at the newly *advertised* host/port, so a success
    // proves whoever answers there holds the pairing key. Off the rate limiter
    // for the same reason the reachability poll is: this is our own probe, not
    // a user action. It only ever fires at an advertiser already echoing our
    // exact fingerprint, so it can't spray pings at unrelated Macs.
    executeCommand(.ping, on: discovered, countsTowardRateLimit: false) { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.pendingMigrationProofs.remove(discovered.id)
        guard case .success = result else {
          print(
            "Rename migration refused: \"\(discovered.id)\" advertised a matching fingerprint but couldn't prove the pairing key"
          )
          return
        }
        // Re-check every guard: the ping was async, so the record may since
        // have been removed, registered under the new name, parked by a
        // mismatch, or joined by a second candidate.
        guard !self.networkDevices.contains(where: { $0.id == discovered.id }),
          self.renameCandidateID(forFingerprint: incoming) == candidateID,
          let index = self.networkDevices.firstIndex(where: { $0.id == candidateID })
        else { return }
        self.commitRenameMigration(at: index, to: discovered, fingerprint: incoming)
      }
    }
  }

  /// The one registered record a rename could plausibly refer to: pinned to
  /// `fingerprint`, not parked behind an identity mismatch, and no longer
  /// advertising under its own name (a record whose name is still on the air
  /// isn't a rename — that Mac is alive under its original identity). Returns
  /// nil unless exactly one matches.
  private func renameCandidateID(forFingerprint fingerprint: String) -> String? {
    let advertisedNames = Set(discoveredNetworkDevices.filter { $0.isActive }.map { $0.id })
    let candidates = networkDevices.filter {
      $0.fingerprint == fingerprint
        && $0.pendingFingerprint == nil
        && !advertisedNames.contains($0.id)
    }
    guard candidates.count == 1 else { return nil }
    return candidates.first?.id
  }

  private func commitRenameMigration(
    at index: Int, to discovered: NetworkDevice, fingerprint: String
  ) {
    let old = networkDevices[index]
    networkDevices[index] = NetworkDevice(
      id: discovered.id,
      name: discovered.name,
      host: discovered.host,
      port: discovered.port,
      isActive: true,
      fingerprint: fingerprint
    )
    // Drop the runtime state keyed to the retired name so a late Bonjour
    // withdraw for it can't resurrect a stale entry, and so its failure streak
    // doesn't arm peripheral adoption against a peer that's alive under the
    // new name. `inFlightOperations` is deliberately left alone: its
    // completion clears itself by the id it captured, and re-keying it here
    // would leave the new row's buttons disabled for good.
    deviceReachability.removeValue(forKey: old.id)
    consecutivePollFailures.removeValue(forKey: old.id)
    // Seeding reachable isn't the optimism the pessimistic default guards
    // against — the ping that authorised this migration *is* a live probe.
    deviceReachability[discovered.id] = true
    consecutivePollFailures[discovered.id] = 0
    saveNetworkDevices()
    print(
      "Migrated registered Mac \"\(old.name)\" -> \"\(discovered.name)\" (proved the pairing key)")
    NotificationManager.showNotification(
      title: "Registered Mac Renamed",
      body:
        "\"\(old.name)\" now answers as \"\(discovered.name)\", so its entry in Settings → Macs was updated. If you didn't rename that Mac, open Settings → Macs and check which Mac is listed.",
      identifier: "peer-renamed-\(discovered.id)"
    )
  }

  /// Re-attempt migration against services already resolved. A resolve happens
  /// once per Bonjour `didFind` and nothing re-runs it, so when the renamed
  /// service resolves *before* the old name's goodbye arrives — a coin flip,
  /// and the likely order when a Mac reboots under a new name — the candidate
  /// check sees the old name still on the air and declines. Without this the
  /// migration would then wait for the peer's service to cycle again, or for
  /// the user to hit Refresh.
  private func retryRenameMigrationFromDiscovered() {
    for discovered in discoveredNetworkDevices where discovered.isActive {
      migrateRenamedPeerIfNeeded(for: discovered)
    }
  }

  /// Promote `pendingFingerprint` to the stored pin and re-mark the device
  /// active. Invoked from the UI when the user explicitly trusts a new key
  /// after an Identity Mismatch (e.g., they re-paired the other Mac).
  func trustPendingFingerprint(for deviceID: String) {
    guard let index = networkDevices.firstIndex(where: { $0.id == deviceID }),
      let pending = networkDevices[index].pendingFingerprint
    else { return }
    networkDevices[index].fingerprint = pending
    networkDevices[index].pendingFingerprint = nil
    networkDevices[index].isActive = true
    networkDevices[index].lastUpdated = Date()
    // Trust is a positive presence signal — the peer is on the network, which
    // is how we saw the new key — so clear the stale `false` reachability the
    // mismatch left behind rather than make the user wait for the next poll to
    // un-grey the menu row.
    deviceReachability[deviceID] = true
    saveNetworkDevices()
  }

  /// A peer just completed a secure-channel handshake, proving it holds the
  /// key whose fingerprint is `provedFingerprint` — the exact PSK snapshot
  /// that channel ran with, not whatever is current by the time this hop
  /// lands, so a handshake that raced a re-pair can't clear a warning about
  /// a key the peer never proved. If a registered device is parked behind
  /// an Identity Mismatch whose pending fingerprint is exactly the current
  /// key's fingerprint (and the proof is for that same key), the proof
  /// supersedes the warning: the handshake demonstrates the very thing
  /// Trust would have taken on faith from a cleartext TXT record. That is
  /// the "both Macs were re-paired" state — the pin predates the re-pair
  /// while both sides already share the new key — and without this the
  /// warning sticks (and outgoing switching stays paused) until the user
  /// manually Trusts on each Mac, even though incoming commands from the
  /// peer were honored the whole time, making the warning read like an
  /// enforcement it never was.
  ///
  /// Deliberately narrow: a pending fingerprint that matches anything
  /// *other* than the current key stays parked for the user to judge — the
  /// handshake says nothing about a key this Mac doesn't hold.
  ///
  /// Called from both connection directions — the responder side on an
  /// incoming handshake, the initiator side on an outgoing one (the
  /// handshake is mutual, each side verifies the other's transcript MAC
  /// before reporting success) — so whichever Mac's reachability poll fires
  /// first heals both ends of a symmetric mutual-re-pair park.
  func resolvePendingFingerprint(provedByHandshake provedFingerprint: String) {
    guard let currentFingerprint = PairingStore.shared.fingerprint,
      provedFingerprint == currentFingerprint
    else { return }
    var changed = false
    for index in networkDevices.indices
    where networkDevices[index].pendingFingerprint == currentFingerprint {
      networkDevices[index].fingerprint = currentFingerprint
      networkDevices[index].pendingFingerprint = nil
      networkDevices[index].isActive = true
      networkDevices[index].lastUpdated = Date()
      // Same positive presence signal as a manual Trust: the proof arrived
      // over a live connection from the peer.
      deviceReachability[networkDevices[index].id] = true
      changed = true
      // Mirror the rename self-heal's announcement so the warning doesn't
      // just silently vanish on a user who saw it appear. Reusing the
      // mismatch identifier replaces the stale "choose Trust" alert in
      // Notification Center instead of stacking next to it.
      print(
        "Resolved identity mismatch for \"\(networkDevices[index].name)\" (peer proved the current pairing key)"
      )
      NotificationManager.showNotification(
        title: "Identity Mismatch Resolved",
        body:
          "\(networkDevices[index].name) proved it holds this Mac's current pairing key, so the identity warning was cleared and switching resumed. If you didn't re-pair both Macs yourself, re-pair them with a fresh code.",
        identifier: "identity-mismatch-\(networkDevices[index].id)"
      )
    }
    if changed {
      saveNetworkDevices()
    }
  }

  /// Tear down and re-start Bonjour browsing. Used by the "Refresh" button
  /// when the discovered list goes stale (network change, sleep/wake).
  func refreshDiscovery() {
    discoveredNetworkDevices = []
    serviceBrowser.refresh()
    // Introduced entries only repopulate via an exchange; kick one now.
    pollReachability()
  }

  /// The port this Mac accepts peer connections on. Shown in Add by Address
  /// so the value can be read off this screen when setting up the other Mac.
  var localListeningPort: UInt16? { servicePublisher.currentIdentity()?.port }

  /// Both names this Mac answers to: its device name and (when mDNS renamed
  /// a collision) the name actually advertised.
  private func isLocalName(_ name: String) -> Bool {
    name == Host.current().localizedName || name == servicePublisher.currentIdentity()?.name
  }

  /// Adds a newly discovered network device
  func addDiscoveredNetworkDevice(_ device: NetworkDevice) {
    if let index = discoveredNetworkDevices.firstIndex(where: { $0.id == device.id }) {
      discoveredNetworkDevices[index].update(with: device)
    } else {
      discoveredNetworkDevices.append(device)
    }
  }

  /// Removes a discovered network device by name
  func removeDiscoveredNetworkDevice(named name: String) {
    discoveredNetworkDevices.removeAll { $0.name == name }
  }

  /// Updates the active state of a device
  func updateDeviceIsActive(id: String, isActive: Bool) {
    if let index = networkDevices.firstIndex(where: { $0.id == id }) {
      networkDevices[index].isActive = isActive
      saveNetworkDevices()
    }
    if let index = discoveredNetworkDevices.firstIndex(where: { $0.id == id }) {
      discoveredNetworkDevices[index].isActive = isActive
    }
    // Mirror Bonjour's verdict into reachability (a withdraw is a valid, if
    // slow, offline signal); the `.ping` poll provides the fast path.
    deviceReachability[id] = isActive

    // A Bonjour withdraw is a *hint* the peer left, not proof — it can be an
    // mDNS flap while the peer is still reachable, and (behind a Bonjour sleep
    // proxy) a genuinely sleeping peer may not withdraw at all. So don't wait
    // out a full poll interval: confirm now. If the peer answers, the probe
    // re-marks it reachable; if it doesn't, this lands as the first miss and
    // the fast-recheck path arms adoption within seconds — closing the gap
    // where a peer that vanished while this Mac was awake left its peripherals
    // unclaimed for ~a minute. Guard `isPaired` so the probe can't book a
    // spurious `.notPaired` failure into the streak.
    if !isActive, PairingStore.shared.isPaired,
      let device = networkDevices.first(where: {
        // Same probe-eligibility rule as `pollReachability`, including the
        // parked-but-current self-heal exception.
        $0.id == id
          && ($0.pendingFingerprint == nil
            || $0.pendingFingerprint == PairingStore.shared.fingerprint)
      })
    {
      probeReachability(of: device)
    }

    // This withdraw may be the missing half of a rename: the new name often
    // resolves before the old one says goodbye, and that earlier resolve is
    // never repeated. Now that the old name is off the air, re-test the
    // services already in hand.
    if !isActive {
      retryRenameMigrationFromDiscovered()
    }
  }

  // MARK: - Reachability

  /// Pessimistic default: until a Bonjour resolve or a `.ping` has actually
  /// confirmed the peer, treat it as unreachable. The probe is async, so it
  /// can't gate the first (synchronous) menu build — an optimistic default
  /// would show an offline peer's row enabled on a cold start until the first
  /// probe lands. An online peer un-greys within ~1s: a Bonjour resolve writes
  /// `true`, and the first poll confirms it.
  func isReachable(_ id: String) -> Bool { deviceReachability[id] ?? false }

  /// A device is switchable when it's reachable *and* not parked behind a
  /// pending TOFU identity mismatch (which the user must Trust first). Drives
  /// the menu's Mac-row enablement and tooltip.
  func isSwitchable(_ device: NetworkDevice) -> Bool {
    device.pendingFingerprint == nil && isReachable(device.id)
  }

  /// Repeating background probe — runs every `reachabilityInterval` for the
  /// life of the app, independent of whether the menu is ever opened.
  private func startReachabilityPolling() {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    // First fire soon after launch so an online peer is confirmed quickly
    // (it starts greyed under the pessimistic default); then settle into the
    // steady interval.
    timer.schedule(
      deadline: .now() + 1, repeating: Self.reachabilityInterval, leeway: .seconds(5))
    timer.setEventHandler { [weak self] in self?.pollReachability() }
    timer.resume()
    reachabilityTimer = timer
  }

  /// Kick an immediate probe — called when the menu opens so the *next* render
  /// is fresh (the probe is async and can't update an already-built menu). The
  /// background timer keeps running on its own cadence regardless.
  func refreshReachability() { pollReachability() }

  private func pollReachability() {
    // The probe rides the secure channel, so it's meaningless unpaired — skip
    // (leaving the pessimistic default) rather than spam `.notPaired` failures.
    // Skip mismatched peers too — a probe against a peer whose key genuinely
    // differs would just auth-fail and feed its inbound rate limiter — EXCEPT
    // when the pending fingerprint is exactly our current key's: then the probe
    // authenticates (we hold the very key being advertised), and its handshake
    // is what lets both sides self-heal the stale mismatch a mutual re-pair
    // leaves behind (see `resolvePendingFingerprint(provedByHandshake:)`).
    // Without the exception, two Macs parked symmetrically would never
    // initiate a connection in either direction and the "proves it over the
    // secure channel" resolution could never actually fire.
    expireStaleIntroducedDevices()
    guard PairingStore.shared.isPaired else { return }
    let currentFingerprint = PairingStore.shared.fingerprint
    for device in networkDevices
    where device.pendingFingerprint == nil || device.pendingFingerprint == currentFingerprint {
      probeReachability(of: device)
    }
  }

  /// Introduced entries get no Bonjour goodbye; expire the ones no exchange
  /// has refreshed so they don't read as "still on the air" forever.
  private func expireStaleIntroducedDevices() {
    let cutoff = Date().addingTimeInterval(-Self.introducedDeviceTTL)
    for index in discoveredNetworkDevices.indices
    where introducedIDs.contains(discoveredNetworkDevices[index].id)
      && discoveredNetworkDevices[index].isActive
      && discoveredNetworkDevices[index].lastUpdated < cutoff
    {
      discoveredNetworkDevices[index].isActive = false
    }
  }

  /// One reachability probe against `device`: updates `deviceReachability`
  /// (which greys the menu/Device-tab rows) and advances the
  /// `consecutivePollFailures` streak that triggers peer-vanished adoption.
  /// The probe is an INTRODUCE, so every successful poll also refreshes the
  /// peer's endpoint on both ends — the app's only routing source when
  /// Bonjour advertising is unavailable.
  /// `countsTowardRateLimit: false` keeps these fixed-cadence probes from
  /// tripping our own outbound limiter. Factored out of `pollReachability` so a
  /// single device can be re-probed off-cycle — by the fast confirming recheck
  /// below, and by a Bonjour withdraw — without waiting out the 30s interval.
  private func probeReachability(of device: NetworkDevice) {
    executeIntroduce(on: device, countsTowardRateLimit: false) { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if case .success(.peer(let identity, let proved)) = result {
          self.ingestIntroducedPeer(
            name: identity.name, host: device.host, port: Int(identity.port),
            provedFingerprint: proved)
        }
        // `.legacy` still counts: the handshake completed.
        let reachable: Bool
        if case .success = result { reachable = true } else { reachable = false }
        // Publish only on change — a steady-state poll would otherwise fire
        // objectWillChange every interval and needlessly re-render observers.
        if self.deviceReachability[device.id] != reachable {
          self.deviceReachability[device.id] = reachable
        }
        if reachable {
          self.consecutivePollFailures[device.id] = 0
        } else {
          let failures = (self.consecutivePollFailures[device.id] ?? 0) + 1
          self.consecutivePollFailures[device.id] = failures
          if failures == 1 {
            // First miss of a new outage. The peer may have just left (slept,
            // unplugged, quit); confirm with one quick re-probe rather than
            // waiting a full ~30s interval for the next scheduled poll. A
            // one-off dropped packet is cleared when the confirm succeeds and
            // resets the streak. This is what makes a peer that vanishes *while
            // this Mac is already awake* get its peripherals adopted within
            // seconds instead of ~a minute — the wake path already covers the
            // case where this Mac was itself asleep.
            self.scheduleFastReachabilityRecheck(of: device)
          } else if failures == 2 {
            // Second consecutive miss: the peer has genuinely gone away, and
            // whatever it was holding is stranded — let the adoption watcher
            // pick it up. Exactly-two (not ≥) fires once per outage, so a
            // long-dark peer doesn't re-arm the watcher every poll forever;
            // a recovery resets the streak and re-arms it for the next one.
            BluetoothPeripheralStore.shared.armAdoptionOfUnheldPeripherals()
          }
        }
      }
    }
  }

  /// Schedule a single off-cycle reachability re-probe of `device` a few
  /// seconds out, to *confirm* a first missed poll (or a Bonjour withdraw)
  /// quickly. Deduplicated per device so overlapping triggers don't stack
  /// rechecks; the probe's own failure counting decides whether to arm
  /// adoption. Runs on main.
  private func scheduleFastReachabilityRecheck(of device: NetworkDevice) {
    guard !pendingFastRecheck.contains(device.id) else { return }
    pendingFastRecheck.insert(device.id)
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.fastRecheckDelay) { [weak self] in
      guard let self = self else { return }
      self.pendingFastRecheck.remove(device.id)
      // Re-probe only if it's still a registered, paired peer that the poll
      // itself would probe (not mismatched — or pending exactly our current
      // key, the self-heal exception in `pollReachability`).
      guard PairingStore.shared.isPaired,
        let current = self.networkDevices.first(where: {
          $0.id == device.id
            && ($0.pendingFingerprint == nil
              || $0.pendingFingerprint == PairingStore.shared.fingerprint)
        })
      else { return }
      self.probeReachability(of: current)
    }
  }

  func sendNotification(
    to device: NetworkDevice,
    completion: ((Result<Void, OutgoingFailure>) -> Void)? = nil
  ) {
    guard PairingStore.shared.isPaired else {
      completion?(.failure(.notPaired))
      return
    }

    beginOperation(.ping, for: device.id)
    let senderName = Host.current().localizedName ?? "another Mac"
    // Put the sender's name in the title so the receiver's Notification
    // Center entry is informative at a glance.
    let title = "Notification from \(senderName)"
    let body = "Sent via Magic Switch."
    sendNotificationOverSecure(to: device, title: title, message: body) { [weak self] result in
      DispatchQueue.main.async {
        self?.endOperation(for: device.id)
        completion?(result)
      }
    }
  }

  // MARK: - In-Flight Operation Tracking

  /// Marks a Device-tab operation as running for `deviceID`. Main-thread only.
  private func beginOperation(_ op: DeviceOperation, for deviceID: String) {
    inFlightOperations[deviceID] = op
  }

  /// Clears the in-flight marker for `deviceID`. Main-thread only.
  private func endOperation(for deviceID: String) {
    inFlightOperations.removeValue(forKey: deviceID)
  }

  // MARK: - Private Methods

  /// This Mac's active IPv4/IPv6 interface addresses, used by
  /// `availableNetworkDevices` to recognise its own advertised service in
  /// discovery results (robust to an mDNS rename of a duplicate device name).
  /// Recomputed each call — `getifaddrs` is cheap and interface addresses
  /// change (Wi-Fi reconnect, VPN, sleep/wake).
  private static func localAddresses() -> Set<String> {
    var result: Set<String> = []
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0 else { return result }
    defer { freeifaddrs(ifaddrPtr) }
    var cursor = ifaddrPtr
    while let current = cursor {
      defer { cursor = current.pointee.ifa_next }
      guard let sa = current.pointee.ifa_addr else { continue }
      let family = sa.pointee.sa_family
      guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else { continue }
      var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let status = getnameinfo(
        sa, socklen_t(sa.pointee.sa_len),
        &hostBuffer, socklen_t(hostBuffer.count),
        nil, 0, NI_NUMERICHOST)
      guard status == 0 else { continue }
      result.insert(Self.normalizeHost(String(cString: hostBuffer)))
    }
    return result
  }

  /// Drop an IPv6 zone id (`fe80::1%en0` → `fe80::1`) so addresses compare
  /// equal regardless of how the scope is formatted on each side.
  private static func normalizeHost(_ host: String) -> String {
    guard let pct = host.firstIndex(of: "%") else { return host }
    return String(host[..<pct])
  }

  private func saveNetworkDevices() {
    do {
      let encoded = try JSONEncoder().encode(networkDevices)
      networkDevicesData = encoded
    } catch {
      print("Failed to save devices: \(error)")
    }
  }

  private func loadNetworkDevices() {
    do {
      networkDevices = try JSONDecoder().decode([NetworkDevice].self, from: networkDevicesData)
    } catch {
      print("Failed to load devices: \(error)")
    }
  }

}

/// Failure surface of `addPeerManually`, rendered inline in the Add by
/// Address sheet.
enum ManualAddError: Error {
  case selfDial
  case legacyPeer
  case anotherMacRegistered(String)
  case outgoing(OutgoingFailure)

  var userMessage: String {
    switch self {
    case .selfDial:
      return "That address is this Mac."
    case .legacyPeer:
      return "The other Mac runs an older version of Magic Switch that can't be added by address. Update it first."
    case .anotherMacRegistered(let name):
      return "Only one Mac can be connected at a time. Remove \(name) first."
    case .outgoing(let failure):
      return failure.userMessage
    }
  }
}

/// Represents different types of device commands
enum DeviceCommand: String, Codable {
  case unregisterAll = "UNREGISTER_ALL"
  case connectAll = "CONNECT_ALL"
  case operationSuccess = "OP_SUCCESS"
  case operationFailed = "OP_FAILED"
  case notification = "NOTIFICATION"
  case syncPeripherals = "SYNC_PERIPHERALS"
  /// Two-frame: opcode then a single peripheral's MAC address. The peer
  /// releases just that peripheral (used by per-peripheral switch flows).
  case unregisterOne = "UNREGISTER_ONE"
  /// Two-frame: opcode then a single peripheral's MAC address. The peer
  /// connects just that peripheral.
  case connectOne = "CONNECT_ONE"
  /// Two-frame: opcode then a single peripheral's MAC address. The peer acks
  /// `OP_SUCCESS` if it currently holds (has a live Bluetooth connection to)
  /// that peripheral, `OP_FAILED` otherwise. Read-only — used by the
  /// wake-time reclaim to avoid grabbing a peripheral the peer is actively
  /// using.
  case holdsOne = "HOLDS_ONE"
  /// Single-frame no-op the peer immediately acks. Used as a secure-channel
  /// preflight: a TCP-open `checkHealth` doesn't prove the peer's app will
  /// accept commands, but a PING that handshakes + receives OP_SUCCESS
  /// does. Lets the switch action bail out before touching local Bluetooth
  /// state if the peer can't actually take a command right now.
  case ping = "PING"
  /// Two-frame: opcode then a comma-separated list of MAC addresses the
  /// *sender* just released as it goes to sleep. The receiver acks on receipt
  /// (like `UNREGISTER_ALL`, not after pairing — the sleeping sender can't wait
  /// that long) and then takes those peripherals. A proactive handoff, so a
  /// peripheral lands on the awake Mac immediately instead of waiting for the
  /// sleeping peer to be detected gone. Best-effort: the sender has already
  /// released locally, so a dropped push just falls back to reactive adoption.
  case adoptReleased = "ADOPT_RELEASED"
  /// Two-frame: opcode then the sender's identity (`<listenPort>|<name>`).
  /// The receiver learns the sender's routing (source IP + stated listen
  /// port) over the authenticated channel and replies with its *own*
  /// identity instead of OP_SUCCESS; legacy builds reply OP_FAILED, which
  /// still proves the handshake. Keeps endpoints fresh without Bonjour.
  case introduce = "INTRODUCE"
}

/// Identity carried by `INTRODUCE` frames: `<listenPort>|<name>`, port first
/// so the name may contain `|`.
struct IntroducedIdentity {
  let name: String
  let port: UInt16

  var encoded: String { "\(port)|\(name)" }

  init(name: String, port: UInt16) {
    self.name = name
    self.port = port
  }

  init?(payload: String) {
    let parts = payload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, let port = UInt16(parts[0]), port > 0 else { return nil }
    let name = String(parts[1]).trimmingCharacters(in: .whitespaces)
    // 63 bytes is Bonjour's instance-name limit; introduced ids key the same
    // store entries as advertised ones.
    guard !name.isEmpty, name.utf8.count <= 63,
      name.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    self.name = name
    self.port = port
  }
}

// MARK: - Health Check Extension

extension NetworkDeviceStore {
  /// Performs a health check on the specified device
  func performHealthCheck(
    for device: NetworkDevice, completion: @escaping (HealthCheckResult) -> Void
  ) {
    device.checkHealth { result in
      DispatchQueue.main.async {
        switch result {
        case .success:
          print("Health check successful with \(device.name)")
          completion(result)
        case .failure(let error):
          print("Health check failed with \(device.name): \(error)")
          completion(result)
        case .timeout:
          print("Health check timed out with \(device.name)")
          completion(result)
        }
      }
    }
  }

  /// Executes a command on `device` through a secure channel. The caller
  /// must pick the target device — keeping this explicit matches the per-
  /// peripheral senders (`executeUnregisterOne` / `executeConnectOne`) and
  /// avoids burying the single-device assumption inside this function.
  func executeCommand(
    _ command: DeviceCommand,
    on device: NetworkDevice,
    countsTowardRateLimit: Bool = true,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    guard PairingStore.shared.isPaired else {
      completion(.failure(.notPaired))
      return
    }

    let bodyTimeout: TimeInterval = command == .connectAll ? Self.handoffBodyTimeout : 5
    let outgoing = OutgoingConnection(
      host: device.host,
      port: UInt16(device.port),
      countsTowardRateLimit: countsTowardRateLimit,
      bodyTimeout: bodyTimeout
    )
    outgoing.run(
      body: { channel, done in
        channel.send(Data(command.rawValue.utf8)) { sendErr in
          if let sendErr = sendErr {
            print("Failed to send command: \(sendErr)")
            done(false)
            return
          }
          channel.receive { result in
            switch result {
            case .failure(let err):
              print("Failed to receive response: \(err)")
              done(false)
            case .success(let data):
              let response = String(data: data, encoding: .utf8) ?? ""
              if let resp = DeviceCommand(rawValue: response) {
                done(resp == .operationSuccess)
              } else {
                done(false)
              }
            }
          }
        }
      },
      completion: completion
    )
  }

  /// Sends a notification through a secure channel.
  func sendNotificationOverSecure(
    to device: NetworkDevice,
    title: String,
    message: String,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    guard PairingStore.shared.isPaired else {
      completion(.failure(.notPaired))
      return
    }

    let outgoing = OutgoingConnection(host: device.host, port: UInt16(device.port))
    outgoing.run(
      body: { channel, done in
        channel.send(Data(DeviceCommand.notification.rawValue.utf8)) { err in
          if let err = err {
            print("Notification command send failed: \(err)")
            done(false)
            return
          }
          let payload = "\(title)|\(message)"
          channel.send(Data(payload.utf8)) { err2 in
            if let err2 = err2 {
              print("Notification payload send failed: \(err2)")
              done(false)
              return
            }
            // Wait for the receiver's OP_SUCCESS/OP_FAILED before tearing
            // down. `NWConnection.send(.contentProcessed)` only confirms
            // local buffering, and the subsequent cancel() can drop frames
            // still in flight — without an ack, the peer often never sees
            // the payload.
            channel.receive { result in
              switch result {
              case .failure(let err):
                print("Notification ack receive failed: \(err)")
                done(false)
              case .success(let data):
                let response = String(data: data, encoding: .utf8) ?? ""
                done(DeviceCommand(rawValue: response) == .operationSuccess)
              }
            }
          }
        }
      },
      completion: completion
    )
  }
}

extension NetworkDeviceStore {
  /// Push this Mac's registered peripheral list to `device`. Completion
  /// receives the categorised outgoing result so the caller can render
  /// inline UI feedback (the Macs tab does this under each row). The
  /// store no longer surfaces its own notifications for sync — callers
  /// decide how to report success/failure.
  func sendPeripheralSync(
    peripherals: [BluetoothPeripheral],
    to device: NetworkDevice,
    completion: ((Result<Void, OutgoingFailure>) -> Void)? = nil
  ) {
    guard PairingStore.shared.isPaired else {
      completion?(.failure(.notPaired))
      return
    }

    guard let data = try? JSONEncoder().encode(peripherals),
      let jsonString = String(data: data, encoding: .utf8)
    else {
      print("sendPeripheralSync: failed to encode peripherals")
      completion?(.failure(.connectionFailed("encode failed")))
      return
    }

    beginOperation(.sync(count: peripherals.count), for: device.id)
    let outgoing = OutgoingConnection(host: device.host, port: UInt16(device.port))
    outgoing.run(
      body: { channel, done in
        channel.send(Data(DeviceCommand.syncPeripherals.rawValue.utf8)) { err in
          if let err = err {
            print("syncPeripherals command send failed: \(err)")
            done(false)
            return
          }
          channel.send(Data(jsonString.utf8)) { err2 in
            if let err2 = err2 {
              print("syncPeripherals payload send failed: \(err2)")
              done(false)
              return
            }
            // Same rationale as the notification path: wait for the
            // receiver's OP_SUCCESS so we don't cancel() before the peer
            // actually processes the payload.
            channel.receive { result in
              switch result {
              case .failure(let err):
                print("syncPeripherals ack receive failed: \(err)")
                done(false)
              case .success(let data):
                let response = String(data: data, encoding: .utf8) ?? ""
                done(DeviceCommand(rawValue: response) == .operationSuccess)
              }
            }
          }
        }
      },
      completion: { [weak self] result in
        DispatchQueue.main.async {
          self?.endOperation(for: device.id)
          completion?(result)
        }
      }
    )
  }

  // MARK: - Per-Peripheral Switch Opcodes

  /// Asks `device` to release the peripheral with the given MAC address.
  /// Two-frame protocol: opcode + MAC, then OP_SUCCESS/OP_FAILED.
  func executeUnregisterOne(
    address: String,
    on device: NetworkDevice,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    sendTwoFrameCommand(.unregisterOne, payload: address, to: device, completion: completion)
  }

  /// Asks `device` to take ownership of the peripheral with the given MAC
  /// address. Two-frame protocol mirroring `executeUnregisterOne`.
  func executeConnectOne(
    address: String,
    on device: NetworkDevice,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    sendTwoFrameCommand(.connectOne, payload: address, to: device, completion: completion)
  }

  /// Asks `device` whether it currently holds the peripheral with the given
  /// MAC. `.success` means the peer holds it (so leave it alone); any
  /// `.failure` — an explicit "no" or an unreachable peer — means it's free
  /// for us to reclaim. Two-frame protocol mirroring `executeUnregisterOne`.
  func executeHoldsOne(
    address: String,
    on device: NetworkDevice,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    // `HOLDS_ONE` is only ever a background watcher/reclaim probe, never a user
    // action — opt out of the outbound limiter so its fixed cadence can't trip
    // the limiter that gates real switches (mirrors the reachability poll).
    sendTwoFrameCommand(
      .holdsOne, payload: address, to: device, countsTowardRateLimit: false,
      completion: completion)
  }

  /// Tells `device` to take the peripherals the sender just released on its way
  /// to sleep — the proactive handoff `prepareForSleep` fires. The peer acks on
  /// receipt, so the sleeping sender only has to wait a moment before sleeping.
  /// `countsTowardRateLimit: false` — this is a system-triggered push, not a
  /// user action, and shouldn't feed the limiter that gates real switches.
  func executeAdoptReleased(
    addresses: [String],
    on device: NetworkDevice,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    sendTwoFrameCommand(
      .adoptReleased, payload: addresses.joined(separator: ","), to: device,
      countsTowardRateLimit: false, completion: completion)
  }

  /// The peer's answer to an INTRODUCE: its identity plus the fingerprint of
  /// the key the channel proved, or `legacy` from a build that predates the
  /// opcode (it replied OP_FAILED — still a completed handshake).
  enum IntroduceReply {
    case peer(IntroducedIdentity, provedFingerprint: String)
    case legacy
  }

  /// Exchanges identities with `device` over the secure channel. Doubles as
  /// the reachability probe: unlike `.ping`, each successful exchange also
  /// refreshes routing on both ends, with or without Bonjour.
  func executeIntroduce(
    on device: NetworkDevice,
    countsTowardRateLimit: Bool = true,
    completion: @escaping (Result<IntroduceReply, OutgoingFailure>) -> Void
  ) {
    guard PairingStore.shared.isPaired else {
      completion(.failure(.notPaired))
      return
    }
    guard let local = servicePublisher.currentIdentity() else {
      completion(.failure(.connectionFailed("listener not ready")))
      return
    }
    let outgoing = OutgoingConnection(
      host: device.host, port: UInt16(device.port),
      countsTowardRateLimit: countsTowardRateLimit)
    var reply: IntroduceReply?
    outgoing.run(
      body: { channel, done in
        channel.send(Data(DeviceCommand.introduce.rawValue.utf8)) { err in
          if let err = err {
            print("INTRODUCE command send failed: \(err)")
            done(false)
            return
          }
          channel.send(Data(local.encoded.utf8)) { err2 in
            if let err2 = err2 {
              print("INTRODUCE payload send failed: \(err2)")
              done(false)
              return
            }
            channel.receive { result in
              switch result {
              case .failure(let err):
                print("INTRODUCE reply receive failed: \(err)")
                done(false)
              case .success(let data):
                let response = String(data: data, encoding: .utf8) ?? ""
                if let identity = IntroducedIdentity(payload: response),
                  let proved = outgoing.provedFingerprint
                {
                  reply = .peer(identity, provedFingerprint: proved)
                  done(true)
                } else if DeviceCommand(rawValue: response) == .operationFailed {
                  reply = .legacy
                  done(true)
                } else {
                  done(false)
                }
              }
            }
          }
        }
      },
      completion: { result in
        switch result {
        case .success:
          completion(reply.map { .success($0) } ?? .failure(.bodyFailed))
        case .failure(let err):
          completion(.failure(err))
        }
      }
    )
  }

  /// Registers a peer from just a dialable endpoint — the bootstrap for
  /// networks where Bonjour can't carry advertisements in either direction.
  /// The INTRODUCE reply supplies the name, and the exchange lands this Mac
  /// in the peer's discovered list, so only one side ever needs to do this.
  func addPeerManually(
    host: String, port: UInt16,
    completion: @escaping (Result<NetworkDevice, ManualAddError>) -> Void
  ) {
    let target = NetworkDevice(id: host, name: host, host: host, port: Int(port))
    executeIntroduce(on: target) { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self else { return }
        switch result {
        case .failure(let failure):
          completion(.failure(.outgoing(failure)))
        case .success(.legacy):
          completion(.failure(.legacyPeer))
        case .success(.peer(let identity, let proved)):
          // The handshake happily completes against our own listener (same
          // key, both roles), and `registerNetworkDevice` has no self-guard.
          guard !self.isLocalName(identity.name),
            !Self.localAddresses().contains(Self.normalizeHost(host))
          else {
            completion(.failure(.selfDial))
            return
          }
          self.ingestIntroducedPeer(
            name: identity.name, host: host, port: Int(identity.port),
            provedFingerprint: proved)
          if let registered = self.networkDevices.first(where: { $0.id == identity.name }) {
            completion(.success(registered))
          } else if let other = self.networkDevices.first {
            completion(.failure(.anotherMacRegistered(other.name)))
          } else if let discovered = self.discoveredNetworkDevices.first(
            where: { $0.id == identity.name })
          {
            self.registerNetworkDevice(device: discovered)
            self.deviceReachability[identity.name] = true
            self.consecutivePollFailures[identity.name] = 0
            self.resolvePendingFingerprint(provedByHandshake: proved)
            completion(.success(discovered))
          } else {
            completion(.failure(.outgoing(.bodyFailed)))
          }
        }
      }
    }
  }

  /// Shared helper for "opcode + single payload frame, await OP_SUCCESS".
  /// Kept private to this extension; the older two-frame call sites
  /// (`sendNotificationOverSecure`, `sendPeripheralSync`) still have their
  /// own inline copies because their failure surfaces differ.
  private func sendTwoFrameCommand(
    _ command: DeviceCommand,
    payload: String,
    to device: NetworkDevice,
    countsTowardRateLimit: Bool = true,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    guard PairingStore.shared.isPaired else {
      completion(.failure(.notPaired))
      return
    }
    let bodyTimeout: TimeInterval = command == .connectOne ? Self.handoffBodyTimeout : 5
    let outgoing = OutgoingConnection(
      host: device.host, port: UInt16(device.port),
      countsTowardRateLimit: countsTowardRateLimit,
      bodyTimeout: bodyTimeout)
    outgoing.run(
      body: { channel, done in
        channel.send(Data(command.rawValue.utf8)) { err in
          if let err = err {
            print("\(command.rawValue) command send failed: \(err)")
            done(false)
            return
          }
          channel.send(Data(payload.utf8)) { err2 in
            if let err2 = err2 {
              print("\(command.rawValue) payload send failed: \(err2)")
              done(false)
              return
            }
            channel.receive { result in
              switch result {
              case .failure(let err):
                print("\(command.rawValue) ack receive failed: \(err)")
                done(false)
              case .success(let data):
                let response = String(data: data, encoding: .utf8) ?? ""
                done(DeviceCommand(rawValue: response) == .operationSuccess)
              }
            }
          }
        }
      },
      completion: completion
    )
  }
}
