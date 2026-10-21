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
      return "Couldn't reach the other Mac."
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

  /// Whether the attempt failed before the peer could have acted on the
  /// request, so another route may still deliver it. A rejected key would be
  /// rejected the same way on every route.
  var permitsFallback: Bool {
    switch self {
    case .connectionFailed, .connectTimeout:
      return true
    case .handshakeFailed(.authFailed), .handshakeFailed(.decryptionFailed),
      .handshakeFailed(.replay):
      return false
    case .handshakeFailed:
      return true
    default:
      return false
    }
  }
}

/// One way to dial a peer: its TCP listener, or its `BLETransport` service.
enum PeerRoute: Hashable, CustomStringConvertible {
  case network(host: String, port: UInt16)
  case bluetooth(UUID)

  /// `host:port`, with IPv6 bracketed so the address's own colons don't run
  /// into the port number.
  var description: String {
    switch self {
    case .network(let host, let port):
      return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    case .bluetooth(let peripheral):
      return "Bluetooth \(peripheral.uuidString)"
    }
  }
}

/// Per-route outbound failure tracker. The mirror of `RateLimiter` for the
/// sending side: after `failureThreshold` failures inside `windowSeconds`,
/// further attempts over that route fail fast until the window slides forward.
/// A success clears the history immediately, so transient hiccups don't
/// permanently inflate the counter. Keyed per route, so a network that's down
/// can't throttle the Bluetooth fallback.
///
/// Lives as a singleton because `OutgoingConnection` instances are
/// short-lived (one per command); we need the counter to survive across
/// them. `CACurrentMediaTime()` matches `RateLimiter` — wall-clock changes
/// can't shorten the backoff.
final class OutboundRateLimiter {
  static let shared = OutboundRateLimiter()

  private static let windowSeconds: TimeInterval = 60
  private static let failureThreshold = 5

  private let queue = DispatchQueue(label: "com.magicswitch.outbound-ratelimiter")
  private var failuresByRoute: [PeerRoute: [CFTimeInterval]] = [:]

  private init() {}

  /// Returns true if a new attempt over `route` should proceed. Side-effect:
  /// trims stale entries out of the failure list.
  func shouldAttempt(_ route: PeerRoute) -> Bool {
    queue.sync {
      let now = CACurrentMediaTime()
      let recent = (failuresByRoute[route] ?? []).filter { $0 > now - Self.windowSeconds }
      failuresByRoute[route] = recent.isEmpty ? nil : recent
      return recent.count < Self.failureThreshold
    }
  }

  func recordFailure(_ route: PeerRoute) {
    queue.sync {
      let now = CACurrentMediaTime()
      var list = failuresByRoute[route, default: []]
      list.append(now)
      list = list.filter { $0 > now - Self.windowSeconds }
      failuresByRoute[route] = list
    }
  }

  func recordSuccess(_ route: PeerRoute) {
    queue.sync {
      failuresByRoute[route] = nil
    }
  }
}

/// Single-shot authenticated client connection to a peer Magic Switch instance.
/// Dials `routes` in order, falling back to the next while no request has been
/// sent (see `OutgoingFailure.permitsFallback`). Owns the live transport +
/// SecureChannel; tears itself down once `run` is complete (success or
/// failure).
final class OutgoingConnection {
  // MARK: - Constants

  private static let connectionTimeout: TimeInterval = 5
  /// A Bluetooth route adds a GATT connect, service discovery, and a
  /// subscription before the handshake can start.
  private static let bluetoothConnectionTimeout: TimeInterval = 10
  /// Upper bound on `body` execution after the handshake completes.
  /// Receivers that don't respond (or peers that don't recognize a newer
  /// opcode and don't reply OP_FAILED — i.e. anything older than the
  /// commit that added the default-case ack) would otherwise hang here
  /// until the peer's own idle timer (~30s) closes the socket.
  private static let defaultBodyTimeout: TimeInterval = 5

  // MARK: - State

  private let routes: [PeerRoute]
  private let pairingStore: PairingStore
  private let rateLimiter: OutboundRateLimiter
  /// When false, this connection neither consults nor feeds the outbound rate
  /// limiter. Used by the background reachability poll so its fixed-cadence
  /// probes can't trip the limiter — and thereby block a user-initiated switch —
  /// when a peer is down.
  private let countsTowardRateLimit: Bool
  private let bodyTimeout: TimeInterval
  private let queue: DispatchQueue
  /// Index into `routes` of the attempt in flight. Callbacks from an abandoned
  /// attempt see a different index and are dropped. Queue-confined, like the
  /// rest of the attempt state below.
  private var attempt: Int?
  private var transport: TransportConnection?
  private var channel: SecureChannel?
  private var selfRef: OutgoingConnection?
  private var finished = false
  private var connectTimer: DispatchSourceTimer?
  private var bodyTimer: DispatchSourceTimer?
  /// Fingerprint of the PSK snapshot the completed handshake proved.
  /// Written and read on `queue`.
  private(set) var provedFingerprint: String?
  /// The route the completed handshake ran over. Written and read on `queue`.
  private(set) var route: PeerRoute?

  // MARK: - Init

  init(
    routes: [PeerRoute],
    pairingStore: PairingStore = .shared,
    rateLimiter: OutboundRateLimiter = .shared,
    countsTowardRateLimit: Bool = true,
    bodyTimeout: TimeInterval = OutgoingConnection.defaultBodyTimeout,
    queue: DispatchQueue = DispatchQueue(label: "com.magicswitch.outgoing", qos: .userInitiated)
  ) {
    self.routes = routes
    self.pairingStore = pairingStore
    self.rateLimiter = rateLimiter
    self.countsTowardRateLimit = countsTowardRateLimit
    self.bodyTimeout = bodyTimeout
    self.queue = queue
  }

  // MARK: - Public API

  /// Runs the handshake then invokes `body` with the live secure channel.
  /// `body` must call `done(_:)` to release the connection. The completion
  /// receives a `Result` whose failure case carries a categorised reason
  /// (see `OutgoingFailure`) so the caller can render a useful notification.
  func run(
    body:
      @escaping (
        SecureChannel, @escaping (Result<Void, OutgoingFailure>) -> Void
      ) -> Void,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    selfRef = self

    guard let psk = pairingStore.currentKey() else {
      Log.network.error("OutgoingConnection: not paired, aborting send")
      completion(.failure(.notPaired))
      release()
      return
    }

    queue.async {
      guard let first = self.nextAttempt(after: nil) else {
        let failure: OutgoingFailure =
          self.routes.isEmpty ? .connectionFailed("no route to peer") : .tooManyRecentFailures
        self.finish(.failure(failure), completion: completion)
        return
      }
      self.dial(first, psk: psk, body: body, completion: completion)
    }
  }

  // MARK: - Dialing

  /// The first route after `index` the rate limiter lets us try.
  private func nextAttempt(after index: Int?) -> Int? {
    let start = index.map { $0 + 1 } ?? 0
    return routes.indices.dropFirst(start).first { index in
      guard countsTowardRateLimit, !rateLimiter.shouldAttempt(routes[index]) else { return true }
      Log.network.error(
        "OutgoingConnection: backing off — too many recent failures over \(routes[index])")
      return false
    }
  }

  private func dial(
    _ index: Int,
    psk: SymmetricKey,
    body: @escaping (SecureChannel, @escaping (Result<Void, OutgoingFailure>) -> Void) -> Void,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    attempt = index
    // Only until the handshake lands: past that the request may have reached
    // the peer, so a dropped transport surfaces through `body` instead.
    let failed: (OutgoingFailure) -> Void = { [weak self] failure in
      guard let self = self, self.attempt == index, self.route == nil, !self.finished else {
        return
      }
      self.attemptFailed(index, failure, psk: psk, body: body, completion: completion)
    }
    let connected: (TransportConnection) -> Void = { [weak self] transport in
      guard let self = self, self.attempt == index, !self.finished else { return }
      self.handshake(over: transport, index: index, psk: psk, body: body, completion: completion)
    }

    let timeout: TimeInterval
    switch routes[index] {
    case .network(let host, let port):
      timeout = Self.connectionTimeout
      let connection = NWConnection(
        host: NWEndpoint.Host(host),
        port: NWEndpoint.Port(integerLiteral: port),
        using: .tcp
      )
      transport = connection
      connection.stateUpdateHandler = { [weak connection] state in
        switch state {
        case .ready:
          if let connection = connection { connected(connection) }
        case .failed(let error):
          Log.network.error("OutgoingConnection failed: \(error)")
          failed(.connectionFailed(error.localizedDescription))
        case .waiting(let error):
          // A refused dial parks in .waiting and never reaches .failed — left
          // alone it burns the full connect timeout and is reported as a
          // timeout ("didn't respond") instead of unreachable.
          if case .posix(let code) = error, code == .ECONNREFUSED {
            Log.network.error("OutgoingConnection refused: \(error)")
            failed(.connectionFailed(error.localizedDescription))
          }
        case .cancelled:
          // No-op; finish handled explicitly.
          break
        default:
          break
        }
      }
      connection.start(queue: queue)
    case .bluetooth(let peripheral):
      timeout = Self.bluetoothConnectionTimeout
      transport = BLETransport.shared.openSession(to: peripheral, queue: queue) { result in
        switch result {
        case .success(let session):
          connected(session)
        case .failure(let error):
          Log.network.error("OutgoingConnection over Bluetooth failed: \(error)")
          failed(.connectionFailed(error.localizedDescription))
        }
      }
    }

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { failed(.connectTimeout) }
    timer.resume()
    connectTimer = timer
  }

  private func handshake(
    over transport: TransportConnection,
    index: Int,
    psk: SymmetricKey,
    body: @escaping (SecureChannel, @escaping (Result<Void, OutgoingFailure>) -> Void) -> Void,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    let channel = SecureChannel(transport: transport, role: .client, psk: psk, queue: queue)
    self.channel = channel
    channel.performHandshake { [weak self] result in
      guard let self = self, self.attempt == index, !self.finished else { return }
      switch result {
      case .success:
        self.connectTimer?.cancel()
        self.connectTimer = nil
        // The handshake is mutual — the responder proved possession of
        // this key before our `.success` fired — so feed the
        // identity-mismatch self-heal from the initiating side too:
        // the reachability poll's own ping is what creates this proof
        // for a parked-but-current peer, and without this arm the
        // initiator would stay parked until the peer happened to dial
        // back. Fingerprint the PSK snapshot this channel actually ran
        // with (see `resolvePendingFingerprint`).
        let provedFingerprint = PairingStore.fingerprint(forKey: psk)
        self.provedFingerprint = provedFingerprint
        self.route = self.routes[index]
        // The peer will see this address as our source and dial it back.
        if let connection = transport as? NWConnection {
          DialbackAddresses.shared.noteProven(path: connection.currentPath)
        }
        DispatchQueue.main.async {
          NetworkDeviceStore.shared.resolvePendingFingerprint(
            provedByHandshake: provedFingerprint)
        }
        self.startBodyTimer(completion: completion)
        body(channel) { result in
          self.finish(result, completion: completion)
        }
      case .failure(let err):
        Log.network.error("OutgoingConnection handshake failed: \(err)")
        self.attemptFailed(
          index, .handshakeFailed(err), psk: psk, body: body, completion: completion)
      }
    }
  }

  /// Moves on to the next route if `failure` allows it, else finishes with it.
  private func attemptFailed(
    _ index: Int,
    _ failure: OutgoingFailure,
    psk: SymmetricKey,
    body: @escaping (SecureChannel, @escaping (Result<Void, OutgoingFailure>) -> Void) -> Void,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    guard failure.permitsFallback, let next = nextAttempt(after: index) else {
      finish(.failure(failure), completion: completion)
      return
    }
    Log.network.notice(
      "OutgoingConnection: \(routes[index]) failed (\(failure)); trying \(routes[next])")
    if countsTowardRateLimit {
      rateLimiter.recordFailure(routes[index])
    }
    tearDownAttempt()
    dial(next, psk: psk, body: body, completion: completion)
  }

  // MARK: - Helpers

  private func tearDownAttempt() {
    connectTimer?.cancel()
    connectTimer = nil
    channel?.cancel()
    channel = nil
    transport?.cancel()
    transport = nil
  }

  private func finish(
    _ result: Result<Void, OutgoingFailure>,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    guard !finished else { return }
    finished = true
    bodyTimer?.cancel()
    bodyTimer = nil
    tearDownAttempt()
    // Feed the outbound rate limiter so a series of transport/protocol
    // failures throttles future attempts, and a healthy authenticated reply
    // clears the counter immediately. OP_FAILED is an operation failure, not
    // a network failure: the peer received and answered the request. Skip
    // `tooManyRecentFailures` — that's the limiter's own refusal and would
    // double-count. Background reachability probes opt out entirely.
    if countsTowardRateLimit, let attempt = attempt {
      switch result {
      case .success, .failure(.remoteOperationFailed):
        rateLimiter.recordSuccess(routes[attempt])
      case .failure(.tooManyRecentFailures):
        break
      case .failure:
        rateLimiter.recordFailure(routes[attempt])
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
