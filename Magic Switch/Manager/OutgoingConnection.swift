import CryptoKit
import Foundation
import Network
import QuartzCore

/// Categorised outgoing-side failure. Carries enough information for the
/// caller to render a useful user-facing notification without needing to
/// know about `SecureChannel` internals.
enum OutgoingFailure: Error {
  case notPaired
  case connectionFailed(String)
  case connectTimeout
  case handshakeFailed(SecureChannelError)
  /// The authenticated peer received the request but reported that it could
  /// not complete the operation.
  case remoteOperationFailed
  /// The authenticated peer replied with data that is not valid for the
  /// current command.
  case invalidResponse
  case bodyFailed
  /// Self-throttled because of recent repeated failures to this host.
  /// Prevents a runaway retry loop from racking up failures the peer's
  /// inbound `RateLimiter` would eventually translate into a 15-minute
  /// block — which is much worse than briefly backing off.
  case tooManyRecentFailures

  /// Short, user-facing reason. Callers prepend the device name.
  var userMessage: String {
    switch self {
    case .notPaired:
      return "This Mac isn't paired yet. Open the Pairing tab in Settings."
    case .connectionFailed:
      return "Couldn't reach the other Mac on the network or via Bluetooth."
    case .connectTimeout:
      return "The other Mac didn't respond in time."
    case .handshakeFailed(.authFailed), .handshakeFailed(.decryptionFailed):
      // A wrong code fails AEAD-open long before the MAC compare, so
      // mismatched codes surface as decryptionFailed, not authFailed.
      return "Pairing codes don't match. Re-pair both Macs with the same code."
    case .handshakeFailed(.handshakeTimeout):
      return "The other Mac didn't respond to the secure handshake."
    case .handshakeFailed(.replay):
      return "Couldn't establish a secure connection (possible tampering)."
    case .handshakeFailed:
      return "Couldn't establish a secure connection."
    case .remoteOperationFailed:
      return "The other Mac reported that it couldn't complete the operation."
    case .invalidResponse:
      return "The other Mac returned an invalid response."
    case .bodyFailed:
      return "The connection dropped mid-message."
    case .tooManyRecentFailures:
      return "Too many recent failures reaching the other Mac — backing off. Try again in a minute."
    }
  }
}

/// Per-host outbound failure tracker. The mirror of `RateLimiter` for the
/// sending side: after `failureThreshold` failures inside `windowSeconds`,
/// further attempts to that host fail fast until the window slides forward.
/// A success clears the history immediately, so transient hiccups don't
/// permanently inflate the counter.
final class OutboundRateLimiter {
  static let shared = OutboundRateLimiter()

  private static let windowSeconds: TimeInterval = 60
  private static let failureThreshold = 5

  private let queue = DispatchQueue(label: "com.magicswitch.outbound-ratelimiter")
  private var failuresByHost: [String: [CFTimeInterval]] = [:]

  private init() {}

  /// Returns true if a new attempt to `host` should proceed. Side-effect:
  /// trims stale entries out of the failure list.
  func shouldAttempt(host: String) -> Bool {
    queue.sync {
      let now = CACurrentMediaTime()
      let recent = (failuresByHost[host] ?? []).filter { $0 > now - Self.windowSeconds }
      failuresByHost[host] = recent.isEmpty ? nil : recent
      return recent.count < Self.failureThreshold
    }
  }

  func recordFailure(host: String) {
    queue.sync {
      let now = CACurrentMediaTime()
      var list = failuresByHost[host, default: []]
      list.append(now)
      list = list.filter { $0 > now - Self.windowSeconds }
      failuresByHost[host] = list
    }
  }

  func recordSuccess(host: String) {
    queue.sync {
      failuresByHost[host] = nil
    }
  }
}

/// Single-shot authenticated client connection to a peer Magic Switch instance.
/// Supports both TCP (over local LAN) and Bluetooth LE (as primary or fallback).
/// Tears itself down once `run` is complete (success or failure).
final class OutgoingConnection {
  // MARK: - Constants

  private static let connectionTimeout: TimeInterval = 5
  /// Upper bound on `body` execution after the handshake completes.
  private static let defaultBodyTimeout: TimeInterval = 5.0

  // MARK: - State

  private var connection: NWConnection?
  private var transport: TransportConnection?
  private let host: String
  private let port: UInt16
  private let bluetoothID: UUID?
  private let pairingStore: PairingStore
  private let rateLimiter: OutboundRateLimiter
  private let countsTowardRateLimit: Bool
  private let bodyTimeout: TimeInterval
  private let queue: DispatchQueue
  private var channel: SecureChannel?
  private var selfRef: OutgoingConnection?
  private var finished = false
  private var connectTimer: DispatchSourceTimer?
  private var bodyTimer: DispatchSourceTimer?

  /// Fingerprint of the PSK snapshot the completed handshake proved.
  /// Written and read on `queue`.
  private(set) var provedFingerprint: String?

  // MARK: - Init

  init(
    host: String,
    port: UInt16,
    bluetoothID: UUID? = nil,
    pairingStore: PairingStore = .shared,
    rateLimiter: OutboundRateLimiter = .shared,
    countsTowardRateLimit: Bool = true,
    bodyTimeout: TimeInterval = OutgoingConnection.defaultBodyTimeout,
    queue: DispatchQueue = DispatchQueue(label: "com.magicswitch.outgoing", qos: .userInitiated)
  ) {
    self.host = host
    self.port = port
    self.bluetoothID = bluetoothID
    self.pairingStore = pairingStore
    self.rateLimiter = rateLimiter
    self.countsTowardRateLimit = countsTowardRateLimit
    self.bodyTimeout = bodyTimeout
    self.queue = queue
  }

  convenience init(
    device: NetworkDevice,
    pairingStore: PairingStore = .shared,
    rateLimiter: OutboundRateLimiter = .shared,
    countsTowardRateLimit: Bool = true,
    bodyTimeout: TimeInterval = OutgoingConnection.defaultBodyTimeout,
    queue: DispatchQueue = DispatchQueue(label: "com.magicswitch.outgoing", qos: .userInitiated)
  ) {
    self.init(
      host: device.host,
      port: UInt16(device.port),
      bluetoothID: device.bluetoothID,
      pairingStore: pairingStore,
      rateLimiter: rateLimiter,
      countsTowardRateLimit: countsTowardRateLimit,
      bodyTimeout: bodyTimeout,
      queue: queue
    )
  }

  // MARK: - Public API

  /// Runs the handshake then invokes `body` with the live secure channel.
  /// Automatically tries LAN first and falls back to Bluetooth if available.
  func run(
    body:
      @escaping (
        SecureChannel, @escaping (Result<Void, OutgoingFailure>) -> Void
      ) -> Void,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    selfRef = self

    guard !countsTowardRateLimit || rateLimiter.shouldAttempt(host: host) else {
      Log.network.error("OutgoingConnection: backing off — too many recent failures to \(host)")
      completion(.failure(.tooManyRecentFailures))
      release()
      return
    }

    guard let psk = pairingStore.currentKey() else {
      Log.network.error("OutgoingConnection: not paired, aborting send")
      completion(.failure(.notPaired))
      release()
      return
    }

    // If host is empty or port 0, go straight to Bluetooth
    if (host.isEmpty || port == 0) && bluetoothID != nil {
      runViaBluetooth(psk: psk, body: body, completion: completion)
      return
    }

    // Try LAN first
    runViaLAN(psk: psk, body: body) { [weak self] lanResult in
      guard let self = self else { return }
      switch lanResult {
      case .success:
        self.finish(.success(()), completion: completion)
      case .failure(let err):
        // If LAN failed with connection error/timeout and Bluetooth is available, try Bluetooth fallback
        if self.bluetoothID != nil && self.canFallbackToBluetooth(error: err) {
          Log.network.notice(
            "OutgoingConnection: LAN failed to \(self.host) (\(err)), attempting Bluetooth fallback..."
          )
          self.runViaBluetooth(psk: psk, body: body, completion: completion)
        } else {
          self.finish(.failure(err), completion: completion)
        }
      }
    }
  }

  private func canFallbackToBluetooth(error: OutgoingFailure) -> Bool {
    switch error {
    case .connectionFailed, .connectTimeout, .tooManyRecentFailures:
      return true
    default:
      return false
    }
  }

  // MARK: - LAN Transport (TCP)

  private func runViaLAN(
    psk: SymmetricKey,
    body:
      @escaping (
        SecureChannel, @escaping (Result<Void, OutgoingFailure>) -> Void
      ) -> Void,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    let nwConn = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(integerLiteral: port),
      using: .tcp
    )
    self.connection = nwConn

    let channel = SecureChannel(
      connection: nwConn, role: .client, psk: psk, queue: queue
    )
    self.channel = channel

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + Self.connectionTimeout)
    timer.setEventHandler { [weak self] in
      guard self != nil else { return }
      completion(.failure(.connectTimeout))
    }
    timer.resume()
    connectTimer = timer

    nwConn.stateUpdateHandler = { [weak self] state in
      guard let self = self else { return }
      switch state {
      case .ready:
        channel.performHandshake { result in
          switch result {
          case .success:
            self.connectTimer?.cancel()
            self.connectTimer = nil
            let provedFingerprint = PairingStore.fingerprint(forKey: psk)
            self.provedFingerprint = provedFingerprint
            DialbackAddresses.shared.noteProven(path: nwConn.currentPath)
            DispatchQueue.main.async {
              NetworkDeviceStore.shared.resolvePendingFingerprint(
                provedByHandshake: provedFingerprint)
            }
            self.startBodyTimer(completion: completion)
            body(channel) { bodyResult in
              completion(bodyResult)
            }
          case .failure(let err):
            Log.network.error("OutgoingConnection handshake failed: \(err)")
            completion(.failure(.handshakeFailed(err)))
          }
        }
      case .failed(let error):
        Log.network.error("OutgoingConnection failed: \(error)")
        completion(.failure(.connectionFailed(error.localizedDescription)))
      case .waiting(let error):
        if case .posix(let code) = error, code == .ECONNREFUSED {
          Log.network.error("OutgoingConnection refused: \(error)")
          completion(.failure(.connectionFailed(error.localizedDescription)))
        } else if case .dns = error {
          Log.network.error("OutgoingConnection DNS error: \(error)")
          completion(.failure(.connectionFailed(error.localizedDescription)))
        }
      case .cancelled:
        break
      default:
        break
      }
    }
    nwConn.start(queue: queue)
  }

  // MARK: - Bluetooth LE Transport

  private func runViaBluetooth(
    psk: SymmetricKey,
    body:
      @escaping (
        SecureChannel, @escaping (Result<Void, OutgoingFailure>) -> Void
      ) -> Void,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    guard let btID = bluetoothID else {
      finish(
        .failure(.connectionFailed("Bluetooth peer identifier not available")),
        completion: completion)
      return
    }

    let connectTimeout = max(MagicSwitchBLE.bleConnectTimeout, bodyTimeout)
    BLETransportManager.shared.connect(to: btID, timeout: connectTimeout) { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .failure(let error):
        Log.network.error("OutgoingConnection: Bluetooth connect failed: \(error)")
        self.finish(
          .failure(.connectionFailed("Bluetooth: \(error.localizedDescription)")),
          completion: completion)
      case .success(let bleTransport):
        self.transport = bleTransport
        let channel = SecureChannel(
          transport: bleTransport, role: .client, psk: psk, queue: self.queue
        )
        self.channel = channel
        channel.performHandshake { handshakeResult in
          switch handshakeResult {
          case .success:
            let provedFingerprint = PairingStore.fingerprint(forKey: psk)
            self.provedFingerprint = provedFingerprint
            DispatchQueue.main.async {
              NetworkDeviceStore.shared.resolvePendingFingerprint(
                provedByHandshake: provedFingerprint)
            }
            self.startBodyTimer(completion: completion)
            body(channel) { bodyResult in
              self.finish(bodyResult, completion: completion)
            }
          case .failure(let err):
            Log.network.error("OutgoingConnection (BT) handshake failed: \(err)")
            self.finish(.failure(.handshakeFailed(err)), completion: completion)
          }
        }
      }
    }
  }

  // MARK: - Helpers

  private func finish(
    _ result: Result<Void, OutgoingFailure>,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    guard !finished else { return }
    finished = true
    connectTimer?.cancel()
    connectTimer = nil
    bodyTimer?.cancel()
    bodyTimer = nil
    channel?.cancel()
    transport?.cancel()
    connection?.cancel()

    if countsTowardRateLimit {
      switch result {
      case .success, .failure(.remoteOperationFailed):
        rateLimiter.recordSuccess(host: host)
      case .failure(.tooManyRecentFailures):
        break
      case .failure:
        rateLimiter.recordFailure(host: host)
      }
    }
    completion(result)
    release()
  }

  private func startBodyTimer(
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + bodyTimeout)
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      self.finish(.failure(.bodyFailed), completion: completion)
    }
    timer.resume()
    bodyTimer = timer
  }

  private func release() {
    queue.async { [weak self] in
      self?.selfRef = nil
    }
  }
}
