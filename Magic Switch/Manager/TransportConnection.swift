import Foundation
import Network

/// A reliable, ordered byte stream between two Macs — a TCP connection or a
/// Bluetooth session. `SecureChannel` runs on top, so a transport only ever
/// carries ciphertext.
protocol TransportConnection: AnyObject {
  /// Begins delivering events on `queue`. `onClose` fires once the stream
  /// fails or is cancelled.
  func start(queue: DispatchQueue, onClose: @escaping () -> Void)

  func send(_ data: Data, completion: @escaping (Error?) -> Void)

  /// Reads exactly `byteCount` bytes, failing with `.connectionClosed` if the
  /// stream ends first. One read at a time.
  func receive(
    exactly byteCount: Int, completion: @escaping (Result<Data, SecureChannelError>) -> Void)

  func cancel()
}

extension NWConnection: TransportConnection {
  func start(queue: DispatchQueue, onClose: @escaping () -> Void) {
    stateUpdateHandler = { state in
      switch state {
      case .failed, .cancelled:
        onClose()
      default:
        break
      }
    }
    start(queue: queue)
  }

  func send(_ data: Data, completion: @escaping (Error?) -> Void) {
    send(content: data, completion: .contentProcessed { completion($0) })
  }

  func receive(
    exactly byteCount: Int, completion: @escaping (Result<Data, SecureChannelError>) -> Void
  ) {
    receive(minimumIncompleteLength: byteCount, maximumLength: byteCount) {
      data, _, isComplete, error in
      if error != nil {
        completion(.failure(.connectionClosed))
        return
      }
      guard let data = data, data.count == byteCount else {
        completion(.failure(isComplete ? .connectionClosed : .framingFailed))
        return
      }
      completion(.success(data))
    }
  }
}
