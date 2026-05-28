import Foundation
import Network

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
}

/// Per-accept handler. Owns the NWConnection, its SecureChannel, idle/total
/// timers, and the (per-connection) decoder state. Self-retained until the
/// connection terminates so it doesn't get released mid-flight.
final class IncomingConnection {
  // MARK: - Constants

  /// Cuts off slow-talkers. Reset on every successful frame.
  private static let idleTimeout: TimeInterval = 30
  /// Hard cap on a single connection regardless of idle activity. Without it,
  /// a well-behaved-looking attacker could keep `idleTimer` happy with
  /// well-formed sealed frames indefinitely and pin a listener slot forever.
  private static let totalBudget: TimeInterval = 5 * 60

  // MARK: - Dependencies

  private let connection: NWConnection
  private let endpoint: NWEndpoint?
  private let rateLimiter: RateLimiter
  private let pairingStore: PairingStore
  private let queue: DispatchQueue
  private let bluetoothStore = BluetoothPeripheralStore.shared

  // MARK: - State

  private var channel: SecureChannel?
  private var lastReceivedCommand: DeviceCommand?
  private var idleTimer: DispatchSourceTimer?
  private var totalTimer: DispatchSourceTimer?
  private var selfRef: IncomingConnection?
  private var authenticated = false
  private var finished = false

  // MARK: - Init

  init(
    connection: NWConnection,
    endpoint: NWEndpoint?,
    rateLimiter: RateLimiter,
    pairingStore: PairingStore,
    queue: DispatchQueue
  ) {
    self.connection = connection
    self.endpoint = endpoint
    self.rateLimiter = rateLimiter
    self.pairingStore = pairingStore
    self.queue = queue
  }

  // MARK: - Lifecycle

  func start() {
    selfRef = self

    guard rateLimiter.shouldAccept(endpoint: endpoint) else {
      print("Rejecting connection from blocked endpoint")
      connection.cancel()
      release()
      return
    }

    guard let psk = pairingStore.currentKey() else {
      print("Rejecting connection: not paired")
      connection.cancel()
      release()
      return
    }

    let channel = SecureChannel(
      connection: connection, role: .server, psk: psk, queue: queue
    )
    self.channel = channel

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

    startTotalTimer()
    resetIdleTimer()

    channel.performHandshake { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .success:
        self.authenticated = true
        self.resetIdleTimer()
        self.readNext()
      case .failure(let error):
        print("Handshake failed: \(error)")
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
        self.handleIncoming(data: data)
        self.readNext()
      }
    }
  }

  // MARK: - Command Handling

  private func handleIncoming(data: Data) {
    guard let message = String(data: data, encoding: .utf8) else {
      print("Dropping non-UTF8 frame")
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
      print("Unexpected payload with no pending command")
      sendString(DeviceCommand.operationFailed.rawValue)
    }
  }

  private func handleCommand(_ command: DeviceCommand) {
    lastReceivedCommand = command
    switch command {
    case .notification, .syncPeripherals, .unregisterOne, .connectOne:
      // Two-frame commands; data frame handled in `handleCommandData`.
      break
    case .connectAll:
      let store = bluetoothStore
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .magicSwitchReceivedConnectAll, object: nil)
        store.peripherals.forEach { peripheral in
          store.connectPeripheral(peripheral)
        }
      }
      // Best-effort ack: OP_SUCCESS here means "command received and
      // dispatched," not "all peripherals successfully connected." Local
      // pair work is async and may still fail (out of range, peer never
      // released, etc.). The peer's goal ("you now hold these") is
      // satisfied as long as we attempt — tracking per-peripheral results
      // and aggregating would require holding the connection open until
      // every IOBluetooth callback lands, which isn't worth the complexity.
      sendString(DeviceCommand.operationSuccess.rawValue)
      lastReceivedCommand = nil
    case .unregisterAll:
      let store = bluetoothStore
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .magicSwitchReceivedUnregisterAll, object: nil)
        store.peripherals.forEach { peripheral in
          store.unregisterFromPC(peripheral)
        }
      }
      // See connectAll above for the best-effort-ack rationale.
      sendString(DeviceCommand.operationSuccess.rawValue)
      lastReceivedCommand = nil
    case .ping:
      // Pure no-op preflight; just acknowledge.
      sendString(DeviceCommand.operationSuccess.rawValue)
      lastReceivedCommand = nil
    default:
      print("Unsupported command: \(command.rawValue)")
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
        print("Invalid notification format received")
        sendString(DeviceCommand.operationFailed.rawValue)
      }
    case .syncPeripherals:
      guard let data = message.data(using: .utf8) else {
        print("syncPeripherals: invalid utf8")
        teardown()
        return
      }
      do {
        let peripherals = try JSONDecoder().decode([BluetoothPeripheral].self, from: data)
        bluetoothStore.updatePeripherals(peripherals)
        sendString(DeviceCommand.operationSuccess.rawValue)
      } catch {
        print("syncPeripherals decode failed: \(error)")
        sendString(DeviceCommand.operationFailed.rawValue)
        teardown()
        return
      }
    case .unregisterOne:
      guard Self.isValidMACAddress(message) else {
        print("unregisterOne: invalid MAC address: \(message)")
        sendString(DeviceCommand.operationFailed.rawValue)
        break
      }
      let store = bluetoothStore
      let address = message
      DispatchQueue.main.async {
        if let peripheral = store.peripherals.first(where: { $0.id == address }) {
          store.unregisterFromPC(peripheral)
        }
      }
      // Reply OP_SUCCESS even if the peripheral isn't in our registered
      // list — from the peer's perspective the goal ("you don't hold it
      // anymore") is satisfied either way.
      sendString(DeviceCommand.operationSuccess.rawValue)
    case .connectOne:
      guard Self.isValidMACAddress(message) else {
        print("connectOne: invalid MAC address: \(message)")
        sendString(DeviceCommand.operationFailed.rawValue)
        break
      }
      let store = bluetoothStore
      let address = message
      DispatchQueue.main.async {
        if let peripheral = store.peripherals.first(where: { $0.id == address }) {
          store.connectPeripheral(peripheral)
        }
      }
      sendString(DeviceCommand.operationSuccess.rawValue)
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
        print("Sealed send failed: \(error)")
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
    idleTimer?.cancel()
    totalTimer?.cancel()
    idleTimer = nil
    totalTimer = nil
    channel?.cancel()
    connection.cancel()
    release()
  }

  private func release() {
    queue.async { [weak self] in
      self?.selfRef = nil
    }
  }
}
