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
      return "Couldn't reach the other Mac on the network."
    case .connectTimeout:
      return "The other Mac didn't respond in time."
    case .handshakeFailed(.authFailed):
      return "Pairing codes don't match. Re-pair both Macs with the same code."
    case .handshakeFailed(.handshakeTimeout):
      return "The other Mac didn't respond to the secure handshake."
    case .handshakeFailed(.replay), .handshakeFailed(.decryptionFailed):
      return "Couldn't establish a secure connection (possible tampering)."
    case .handshakeFailed:
      return "Couldn't establish a secure connection."
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
/// Owns its NWConnection + SecureChannel; tears itself down once `run` is
/// complete (success or failure).
final class OutgoingConnection {
  // MARK: - Constants

  private static let connectionTimeout: TimeInterval = 5
  /// Upper bound on `body` execution after the handshake completes.
  /// Receivers that don't respond (or peers that don't recognize a newer
  /// opcode and don't reply OP_FAILED — i.e. anything older than the
  /// commit that added the default-case ack) would otherwise hang here
  /// until the peer's own idle timer (~30s) closes the socket.
  private static let bodyTimeout: TimeInterval = 5

  // MARK: - State

  private let connection: NWConnection
  /// Captured separately so we can key the outbound rate limiter on it.
  /// `NWConnection` doesn't expose the original host string in a
  /// useful form, hence the dedicated field.
  private let host: String
  private let pairingStore: PairingStore
  private let rateLimiter: OutboundRateLimiter
  private let queue: DispatchQueue
  private var channel: SecureChannel?
  private var selfRef: OutgoingConnection?
  private var finished = false
  private var connectTimer: DispatchSourceTimer?
  private var bodyTimer: DispatchSourceTimer?

  // MARK: - Init

  init(
    host: String,
    port: UInt16,
    pairingStore: PairingStore = .shared,
    rateLimiter: OutboundRateLimiter = .shared,
    queue: DispatchQueue = DispatchQueue(label: "com.magicswitch.outgoing", qos: .userInitiated)
  ) {
    self.connection = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(integerLiteral: port),
      using: .tcp
    )
    self.host = host
    self.pairingStore = pairingStore
    self.rateLimiter = rateLimiter
    self.queue = queue
  }

  // MARK: - Public API

  /// Runs the handshake then invokes `body` with the live secure channel.
  /// `body` must call `done(_:)` to release the connection. The completion
  /// receives a `Result` whose failure case carries a categorised reason
  /// (see `OutgoingFailure`) so the caller can render a useful notification.
  func run(
    body: @escaping (SecureChannel, @escaping (Bool) -> Void) -> Void,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    selfRef = self

    guard rateLimiter.shouldAttempt(host: host) else {
      print("OutgoingConnection: backing off — too many recent failures to \(host)")
      completion(.failure(.tooManyRecentFailures))
      release()
      return
    }

    guard let psk = pairingStore.currentKey() else {
      print("OutgoingConnection: not paired, aborting send")
      completion(.failure(.notPaired))
      release()
      return
    }

    let channel = SecureChannel(
      connection: connection, role: .client, psk: psk, queue: queue
    )
    self.channel = channel

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + Self.connectionTimeout)
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      self.finish(.failure(.connectTimeout), completion: completion)
    }
    timer.resume()
    connectTimer = timer

    connection.stateUpdateHandler = { [weak self] state in
      guard let self = self else { return }
      switch state {
      case .ready:
        channel.performHandshake { result in
          switch result {
          case .success:
            self.connectTimer?.cancel()
            self.connectTimer = nil
            self.startBodyTimer(completion: completion)
            body(channel) { ok in
              self.finish(
                ok ? .success(()) : .failure(.bodyFailed), completion: completion)
            }
          case .failure(let err):
            print("OutgoingConnection handshake failed: \(err)")
            self.finish(.failure(.handshakeFailed(err)), completion: completion)
          }
        }
      case .failed(let error):
        print("OutgoingConnection failed: \(error)")
        self.finish(
          .failure(.connectionFailed(error.localizedDescription)),
          completion: completion)
      case .cancelled:
        // No-op; finish handled explicitly.
        break
      default:
        break
      }
    }
    connection.start(queue: queue)
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
    connection.cancel()
    // Feed the outbound rate limiter so a series of failures throttles
    // future attempts, and a success clears the counter immediately. Skip
    // `tooManyRecentFailures` — that's the limiter's own refusal and would
    // double-count.
    switch result {
    case .success:
      rateLimiter.recordSuccess(host: host)
    case .failure(.tooManyRecentFailures):
      break
    case .failure:
      rateLimiter.recordFailure(host: host)
    }
    completion(result)
    release()
  }

  private func startBodyTimer(
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + Self.bodyTimeout)
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
