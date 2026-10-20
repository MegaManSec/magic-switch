import Foundation
import Network
import QuartzCore

extension Notification.Name {
  /// Posted on the main queue when this Mac receives a `.notification`
  /// command from a peer. The AppDelegate observes it and briefly flashes
  /// the status-bar icon — system notifications are unreliable on
  /// ad-hoc-signed sandboxed builds, so this is the only visible signal
  /// the user is guaranteed to see.
  static let magicSwitchReceivedPing = Notification.Name("magicSwitchReceivedPing")
  /// Posted when this Mac is being handed peripherals by a peer (we just
  /// received `.connectAll`). AppDelegate switches the status-bar icon to
  /// the "receiving peripherals" state.
  static let magicSwitchReceivedConnectAll = Notification.Name(
    "magicSwitchReceivedConnectAll")
  /// Posted when this Mac is being asked to release peripherals back to a
  /// peer (we just received `.unregisterAll`). AppDelegate switches the
  /// status-bar icon to the "sending peripherals" state.
  static let magicSwitchReceivedUnregisterAll = Notification.Name(
    "magicSwitchReceivedUnregisterAll")
  /// Per-peripheral counterparts of the `…ConnectAll` / `…UnregisterAll`
  /// signals above: the same status-bar arrows, but for a single-device
  /// switch. Posted both by this Mac's per-peripheral senders
  /// (`takePeripheralFromPeer` / `sendPeripheralToPeer`) and by the incoming
  /// `.connectOne` / `.unregisterOne` handlers, so both Macs show arrows
  /// pointing the same physical way during a one-peripheral handoff.
  static let magicSwitchPeripheralIncoming = Notification.Name(
    "magicSwitchPeripheralIncoming")
  static let magicSwitchPeripheralOutgoing = Notification.Name(
    "magicSwitchPeripheralOutgoing")
}

/// Per-accept handler. Owns the NWConnection, its SecureChannel, idle/total
/// timers, and the (per-connection) decoder state. Self-retained until the
/// connection terminates so it doesn't get released mid-flight.
final class IncomingConnection {
  // MARK: - Constants

  /// Cuts off slow-talkers. Reset on every successful frame. Held above the
  /// peer's worst-case handoff connect time (its pair watchdog is 60s) because
  /// a `CONNECT_ALL`/`CONNECT_ONE` receiver only acks after pairing finishes —
  /// no frames are exchanged meanwhile — so a tighter idle cap would kill the
  /// connection before it could reply. Must stay >= `NetworkDeviceStore`'s
  /// `handoffBodyTimeout` (the sender's matching wait).
  private static let idleTimeout: TimeInterval = 75
  /// How long a `currentlyAuthorized()` result may be reused. See its doc.
  private static let authorizationTTL: CFTimeInterval = 1
  /// Hard cap on a single connection regardless of idle activity. Without it,
  /// a well-behaved-looking attacker could keep `idleTimer` happy with
  /// well-formed sealed frames indefinitely and pin a listener slot forever.
  private static let totalBudget: TimeInterval = 5 * 60

  // MARK: - Dependencies

  private let transport: TransportConnection
  private let connection: NWConnection?
  private let endpoint: NWEndpoint?
  private let endpointDesc: String?
  private let rateLimiter: RateLimiter
  private let pairingStore: PairingStore
  private let queue: DispatchQueue
  /// This Mac's identity for INTRODUCE replies. Called on `queue`.
  private let localIdentity: () -> IntroducedIdentity?
  private let bluetoothStore = BluetoothPeripheralStore.shared

  // MARK: - State

  private var channel: SecureChannel?
  private var lastReceivedCommand: DeviceCommand?
  private var idleTimer: DispatchSourceTimer?
  private var totalTimer: DispatchSourceTimer?
  private var selfRef: IncomingConnection?
  private var authenticated = false
  private var finished = false
  private var pendingCounted = false
  /// Fingerprint of the accept-time PSK snapshot the handshake proved.
  private var provedFingerprint: String?
  private var lastAuthorizationCheck: CFTimeInterval = -.greatestFiniteMagnitude
  private var lastAuthorizationResult = false

  // MARK: - Init

  init(
    transport: TransportConnection,
    endpointDesc: String? = nil,
    rateLimiter: RateLimiter,
    pairingStore: PairingStore,
    queue: DispatchQueue,
    localIdentity: @escaping () -> IntroducedIdentity?
  ) {
    self.transport = transport
    self.connection = nil
    self.endpoint = nil
    self.endpointDesc = endpointDesc
    self.rateLimiter = rateLimiter
    self.pairingStore = pairingStore
    self.queue = queue
    self.localIdentity = localIdentity
  }

  convenience init(
    connection: NWConnection,
    endpoint: NWEndpoint?,
    rateLimiter: RateLimiter,
    pairingStore: PairingStore,
    queue: DispatchQueue,
    localIdentity: @escaping () -> IntroducedIdentity?
  ) {
    self.init(
      transport: NWTransportConnection(connection: connection),
      endpointDesc: endpoint?.debugDescription,
      rateLimiter: rateLimiter,
      pairingStore: pairingStore,
      queue: queue,
      localIdentity: localIdentity
    )
  }

  // MARK: - Lifecycle

  func start() {
    selfRef = self

    if let endpoint = endpoint, !rateLimiter.shouldAccept(endpoint: endpoint) {
      Log.network.error("Rejecting connection from blocked endpoint")
      transport.cancel()
      release()
      return
    }

    guard let psk = pairingStore.currentKey() else {
      Log.network.error("Rejecting connection: not paired")
      transport.cancel()
      release()
      return
    }

    if let endpoint = endpoint {
      guard rateLimiter.beginPending(endpoint: endpoint) else {
        Log.network.error("Rejecting connection: too many concurrent unauthenticated handshakes")
        transport.cancel()
        release()
        return
      }
      pendingCounted = true
    }

    let channel = SecureChannel(
      transport: transport, role: .server, psk: psk, queue: queue
    )
    self.channel = channel

    if let connection = connection {
      connection.stateUpdateHandler = { [weak self] state in
        guard let self = self else { return }
        switch state {
        case .failed, .cancelled:
          self.teardown()
        default:
          break
        }
      }
      connection.start(queue: queue)
    }

    startTotalTimer()
    resetIdleTimer()

    channel.performHandshake { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .success:
        self.authenticated = true
        self.endPendingIfNeeded()
        // The peer has proved possession of the pairing key this handshake
        // ran with — strictly stronger evidence than the fingerprint it
        // advertises over cleartext mDNS. If a registered device is stuck
        // behind an Identity Mismatch that pends exactly the current key
        // (both Macs re-paired), resolve it now instead of honoring commands
        // while the Macs tab claims switching is paused. Fingerprint the
        // accept-time PSK snapshot, not the live key, so a re-pair racing
        // this hop can't count a stale proof against the new key.
        let provedFingerprint = PairingStore.fingerprint(forKey: psk)
        self.provedFingerprint = provedFingerprint
        // The peer dialed this address, which proves it dialable.
        if let path = self.connection?.currentPath {
          DialbackAddresses.shared.noteProven(path: path)
        }
        DispatchQueue.main.async {
          NetworkDeviceStore.shared.resolvePendingFingerprint(
            provedByHandshake: provedFingerprint)
          NetworkDeviceStore.shared.markPeerReachable(
            provedFingerprint: provedFingerprint)
        }
        self.resetIdleTimer()
        self.readNext()
      case .failure(let error):
        Log.network.error("Handshake failed: \(error)")
        // Only AEAD/auth failures indicate a credential-probe attempt.
        // Framing, timeout, and network errors are flaky-network noise; if we
        // count them we lock out the legitimate peer.
        switch error {
        case .decryptionFailed, .authFailed:
          self.rateLimiter.recordFailure(endpoint: self.endpoint)
        default:
          break
        }
        self.teardown()
      }
    }
  }

  // MARK: - Read Loop

  private func readNext() {
    guard let channel = channel else { return }
    channel.receive { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .failure:
        // Post-auth: any error is either network failure or peer misbehavior,
        // neither helps a brute-force attacker. Just tear down.
        self.teardown()
      case .success(let data):
        self.resetIdleTimer()
        guard self.currentlyAuthorized() else {
          Log.network.error("Dropping frame: pairing key changed or removed since handshake")
          self.teardown()
          return
        }
        self.handleIncoming(data: data)
        self.readNext()
      }
    }
  }

  /// Whether the pairing key the handshake proved is still the current one.
  ///
  /// Re-read at most once per `authorizationTTL`: the underlying
  /// `SecItemCopyMatching` is a securityd round trip, and this runs per frame
  /// on the queue that also accepts new connections. The TTL is therefore the
  /// upper bound on how long a revoked key keeps a live session.
  private func currentlyAuthorized() -> Bool {
    let now = CACurrentMediaTime()
    if now - lastAuthorizationCheck < Self.authorizationTTL { return lastAuthorizationResult }
    let current = pairingStore.currentKey().map { PairingStore.fingerprint(forKey: $0) }
    lastAuthorizationCheck = now
    lastAuthorizationResult = current != nil && current == provedFingerprint
    return lastAuthorizationResult
  }

  // MARK: - Command Handling

  private func handleIncoming(data: Data) {
    if let proved = provedFingerprint {
      DispatchQueue.main.async {
        NetworkDeviceStore.shared.markPeerReachable(provedFingerprint: proved)
      }
    }
    guard let message = String(data: data, encoding: .utf8) else {
      Log.network.error("Dropping non-UTF8 frame")
      return
    }
    // Order matters: if a command is awaiting its data frame, this is that
    // data — even if the payload happens to be parseable as a `DeviceCommand`
    // raw value (e.g. an attacker sending `OP_SUCCESS` as a notification body).
    if let pending = lastReceivedCommand {
      handleCommandData(message, for: pending)
    } else if let command = DeviceCommand(rawValue: message) {
      handleCommand(command)
    } else {
      // Unknown opcode (or garbled payload). Reply OP_FAILED so a newer peer
      // that introduces opcodes we don't recognize gets a fast, clean
      // failure instead of hanging on a receive that never comes.
      Log.network.error("Unexpected payload with no pending command")
      sendString(DeviceCommand.operationFailed.rawValue)
    }
  }

  private func handleCommand(_ command: DeviceCommand) {
    lastReceivedCommand = command
    switch command {
    case .notification, .syncPeripherals, .unregisterOne, .connectOne, .holdsOne, .adoptReleased,
      .introduce:
      // Two-frame commands; data frame handled in `handleCommandData`.
      break
    case .connectAll:
      let store = bluetoothStore
      lastReceivedCommand = nil
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        NotificationCenter.default.post(name: .magicSwitchReceivedConnectAll, object: nil)
        let peripherals = store.peripherals
        guard !peripherals.isEmpty else {
          self.queue.async {
            self.sendString(DeviceCommand.operationFailed.rawValue)
          }
          return
        }
        var remaining = peripherals.count
        var allSucceeded = true
        peripherals.forEach { peripheral in
          store.connectPeripheralFromPeer(peripheral) { success in
            self.queue.async {
              allSucceeded = allSucceeded && success
              remaining -= 1
              if remaining == 0 {
                self.sendString(
                  (allSucceeded ? DeviceCommand.operationSuccess : DeviceCommand.operationFailed)
                    .rawValue
                )
              }
            }
          }
        }
      }
    case .unregisterAll:
      let store = bluetoothStore
      lastReceivedCommand = nil
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        NotificationCenter.default.post(name: .magicSwitchReceivedUnregisterAll, object: nil)
        let peripherals = store.peripherals
        let releases = DispatchGroup()
        peripherals.forEach { peripheral in
          releases.enter()
          store.unregisterFromPC(peripheral) { releases.leave() }
        }
        releases.notify(queue: .main) {
          self.replyOnceDisconnected(peripherals.map(\.id))
        }
      }
    case .ping:
      // Pure no-op preflight; just acknowledge.
      sendString(DeviceCommand.operationSuccess.rawValue)
      lastReceivedCommand = nil
    default:
      Log.network.error("Unsupported command: \(command.rawValue)")
      sendString(DeviceCommand.operationFailed.rawValue)
      lastReceivedCommand = nil
    }
  }

  private func handleCommandData(_ message: String, for command: DeviceCommand) {
    switch command {
    case .notification:
      let components = message.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
      if components.count == 2 {
        NotificationManager.showNotification(
          title: String(components[0]),
          body: String(components[1])
        )
        // Even if `UNUserNotificationCenter` silently drops the alert (it
        // does on ad-hoc-signed sandboxed builds), the menu-bar flash
        // observed in AppDelegate gives the user *some* visible signal.
        DispatchQueue.main.async {
          NotificationCenter.default.post(name: .magicSwitchReceivedPing, object: nil)
        }
        // Ack before the sender tears down the connection. Without this,
        // `NWConnection.cancel()` on the sender side can drop the in-flight
        // payload before TCP delivers it.
        sendString(DeviceCommand.operationSuccess.rawValue)
      } else {
        Log.network.error("Invalid notification format received")
        sendString(DeviceCommand.operationFailed.rawValue)
      }
    case .syncPeripherals:
      guard let data = message.data(using: .utf8) else {
        Log.network.error("syncPeripherals: invalid utf8")
        teardown()
        return
      }
      do {
        let peripherals = try JSONDecoder().decode([BluetoothPeripheral].self, from: data)
        bluetoothStore.updatePeripherals(peripherals)
        sendString(DeviceCommand.operationSuccess.rawValue)
      } catch {
        Log.network.error("syncPeripherals decode failed: \(error)")
        sendString(DeviceCommand.operationFailed.rawValue)
        teardown()
        return
      }
    case .unregisterOne:
      guard Self.isValidMACAddress(message) else {
        Log.network.error("unregisterOne: invalid MAC address: \(message)")
        sendString(DeviceCommand.operationFailed.rawValue)
        break
      }
      let store = bluetoothStore
      let address = message
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        // Peripheral is leaving this Mac for the peer — flash the sending arrow.
        NotificationCenter.default.post(name: .magicSwitchPeripheralOutgoing, object: nil)
        // A peripheral missing from our registered list isn't released, but
        // the reply still reflects whether we're connected to it.
        guard let peripheral = store.peripherals.first(where: { $0.id == address }) else {
          self.replyOnceDisconnected([address])
          return
        }
        store.unregisterFromPC(peripheral) {
          self.replyOnceDisconnected([address])
        }
      }
    case .connectOne:
      guard Self.isValidMACAddress(message) else {
        Log.network.error("connectOne: invalid MAC address: \(message)")
        sendString(DeviceCommand.operationFailed.rawValue)
        break
      }
      let store = bluetoothStore
      let address = message
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        // Peripheral is arriving at this Mac — flash the receiving arrow.
        NotificationCenter.default.post(name: .magicSwitchPeripheralIncoming, object: nil)
        guard let peripheral = store.peripherals.first(where: { $0.id == address }) else {
          self.queue.async {
            self.sendString(DeviceCommand.operationFailed.rawValue)
          }
          return
        }
        store.connectPeripheralFromPeer(peripheral) { success in
          self.queue.async {
            self.sendString(
              (success ? DeviceCommand.operationSuccess : DeviceCommand.operationFailed).rawValue)
          }
        }
      }
    case .holdsOne:
      guard Self.isValidMACAddress(message) else {
        Log.network.error("holdsOne: invalid MAC address: \(message)")
        sendString(DeviceCommand.operationFailed.rawValue)
        break
      }
      let store = bluetoothStore
      let address = message
      // Read-only query: OP_SUCCESS only if we have a live connection to it,
      // so the peer's wake-time reclaim won't grab a peripheral we're using.
      // Answered from live Bluetooth state, not the registered list: the two
      // lists only converge on a manual Sync, and a peripheral missing from
      // ours is still one the peer must not pair away from us.
      // The BT check completes on the Bluetooth queue; hop back to the
      // connection queue so all sealed sends stay serialized there (the send
      // counter isn't synchronized across queues).
      store.isHoldingPeripheral(address: address) { [weak self] held in
        guard let self = self else { return }
        self.queue.async {
          self.sendString(
            (held ? DeviceCommand.operationSuccess : DeviceCommand.operationFailed).rawValue)
        }
      }
    case .adoptReleased:
      // Comma-separated MACs the peer released as it went to sleep. Take the
      // ones we have registered — a proactive handoff, so they arrive here at
      // once instead of via reactive adoption. Validate every entry before
      // touching the store with peer-supplied input, and cap the list. Ack on
      // receipt (we don't make the sleeping peer wait out pairing) and run the
      // grab async; `connectPeripheralFromPeer` no-ops on anything we already
      // hold, and the watcher (`armReconnectForTakeover`) covers a device
      // that's briefly stuck and needs a power-cycle.
      let macs = message.split(separator: ",").map(String.init)
      guard !macs.isEmpty, macs.count <= 64, macs.allSatisfy(Self.isValidMACAddress) else {
        Log.network.error("adoptReleased: empty, oversized, or malformed address list")
        sendString(DeviceCommand.operationFailed.rawValue)
        break
      }
      let store = bluetoothStore
      DispatchQueue.main.async {
        let toTake = macs.compactMap { mac in store.peripherals.first(where: { $0.id == mac }) }
        guard !toTake.isEmpty else { return }
        // One arrow flash for the batch (receiving direction).
        NotificationCenter.default.post(name: .magicSwitchPeripheralIncoming, object: nil)
        for peripheral in toTake {
          store.connectPeripheralFromPeer(peripheral)
          store.armReconnectForTakeover(peripheral.id)
        }
      }
      // Acked on receipt: the goal ("you now own these") is recorded even if a
      // given peripheral isn't registered here or needs a retry to connect.
      sendString(DeviceCommand.operationSuccess.rawValue)
    case .introduce:
      guard let identity = IntroducedIdentity(payload: message) else {
        Log.network.error("introduce: malformed identity payload")
        sendString(DeviceCommand.operationFailed.rawValue)
        break
      }
      // Reply on this queue (sealed sends stay serialized here), then hand
      // the peer's identity — with its source IP — off to the store.
      if let local = localIdentity() {
        sendString(local.encoded)
      } else {
        sendString(DeviceCommand.operationFailed.rawValue)
      }
      if let proved = provedFingerprint {
        let host = DialbackAddresses.hostString(from: endpoint) ?? ""
        DispatchQueue.main.async {
          NetworkDeviceStore.shared.ingestIntroducedPeer(
            name: identity.name, host: host, port: Int(identity.port),
            provedFingerprint: proved)
        }
      }
    default:
      break
    }
    lastReceivedCommand = nil
  }

  /// Same shape as `IOBluetoothDevice.addressString`: six hex octets
  /// separated by `-`. Used to validate per-peripheral opcodes' MAC frame
  /// before we touch the store with peer-supplied input.
  private static func isValidMACAddress(_ value: String) -> Bool {
    let pattern = "^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$"
    return value.range(of: pattern, options: .regularExpression) != nil
  }

  // MARK: - Sending

  private func sendString(_ message: String) {
    guard let channel = channel else { return }
    channel.send(Data(message.utf8)) { error in
      if let error = error {
        Log.network.error("Sealed send failed: \(error)")
      }
    }
  }

  /// Release reply: OP_SUCCESS once none of `ids` is connected to this Mac,
  /// OP_FAILED if one still is when the wait gives up. Call on main.
  private func replyOnceDisconnected(_ ids: [String]) {
    bluetoothStore.waitForLocalDisconnect(of: ids) { released in
      self.queue.async {
        self.sendString(
          (released ? DeviceCommand.operationSuccess : DeviceCommand.operationFailed).rawValue)
      }
    }
  }

  // MARK: - Timers

  private func resetIdleTimer() {
    idleTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + Self.idleTimeout)
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      if !self.authenticated {
        self.rateLimiter.recordFailure(endpoint: self.endpoint)
      }
      self.teardown()
    }
    timer.resume()
    idleTimer = timer
  }

  private func startTotalTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + Self.totalBudget)
    timer.setEventHandler { [weak self] in
      self?.teardown()
    }
    timer.resume()
    totalTimer = timer
  }

  // MARK: - Teardown

  private func teardown() {
    guard !finished else { return }
    finished = true
    endPendingIfNeeded()
    idleTimer?.cancel()
    totalTimer?.cancel()
    idleTimer = nil
    totalTimer = nil
    channel?.cancel()
    transport.cancel()
    connection?.cancel()
    release()
  }

  private func endPendingIfNeeded() {
    guard pendingCounted else { return }
    pendingCounted = false
    rateLimiter.endPending(endpoint: endpoint)
  }

  private func release() {
    queue.async { [weak self] in
      self?.selfRef = nil
    }
  }
}
