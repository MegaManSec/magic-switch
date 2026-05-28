import Foundation
import Network

/// Categorised outgoing-side failure. Carries enough information for the
/// caller to render a useful user-facing notification without needing to
/// know about `SecureChannel` internals.
enum OutgoingFailure: Error {
  case notPaired
  case connectionFailed(String)
  case connectTimeout
  case handshakeFailed(SecureChannelError)
  case bodyFailed

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
  private let pairingStore: PairingStore
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
    queue: DispatchQueue = DispatchQueue(label: "com.magicswitch.outgoing", qos: .userInitiated)
  ) {
    self.connection = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(integerLiteral: port),
      using: .tcp
    )
    self.pairingStore = pairingStore
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
