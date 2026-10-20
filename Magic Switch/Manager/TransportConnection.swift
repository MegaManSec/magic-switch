import Foundation
import Network

/// Protocol defining a bidirectional byte stream transport connection.
/// Abstracting the transport allows `SecureChannel` to operate over TCP (via
/// `Network.framework` NWConnection), Bluetooth LE (via CoreBluetooth), or
/// any other stream-like medium without changing the encryption and framing layer.
protocol TransportConnection: AnyObject {
  /// Whether the connection is currently open and ready for I/O.
  var isConnected: Bool { get }

  /// Sends raw payload bytes over the transport.
  func send(data: Data, completion: @escaping (Error?) -> Void)

  /// Reads exactly `exactByteCount` bytes from the transport stream.
  func receive(exactByteCount count: Int, completion: @escaping (Result<Data, Error>) -> Void)

  /// Closes and tears down the underlying connection.
  func cancel()
}

/// A thread-safe FIFO byte stream buffer used by packet/chunk-based transports
/// (like CoreBluetooth) to satisfy exact-byte-count stream reads required by
/// length-prefixed framing layers.
final class ByteStreamBuffer {
  private var buffer = Data()
  private var pendingRead: (count: Int, completion: (Result<Data, Error>) -> Void)?
  private var terminalError: Error?
  private let queue: DispatchQueue

  init(queue: DispatchQueue = DispatchQueue(label: "com.magicswitch.bytestreambuffer")) {
    self.queue = queue
  }

  /// Appends newly arrived chunk bytes to the buffer and fulfills any pending read.
  func append(_ data: Data) {
    queue.async {
      guard self.terminalError == nil else { return }
      self.buffer.append(data)
      self.flush()
    }
  }

  /// Requests exactly `count` bytes. If already buffered, returns immediately;
  /// otherwise holds the request until enough bytes have been appended.
  func read(exact count: Int, completion: @escaping (Result<Data, Error>) -> Void) {
    queue.async {
      if let error = self.terminalError {
        completion(.failure(error))
        return
      }
      guard self.pendingRead == nil else {
        completion(.failure(SecureChannelError.framingFailed))
        return
      }
      self.pendingRead = (count, completion)
      self.flush()
    }
  }

  /// Fails any pending read with an error and clears the buffer (used on teardown).
  func fail(error: Error) {
    queue.async {
      self.terminalError = error
      if let pending = self.pendingRead {
        self.pendingRead = nil
        pending.completion(.failure(error))
      }
      self.buffer.removeAll()
    }
  }

  private func flush() {
    guard let (count, completion) = pendingRead, buffer.count >= count else { return }
    pendingRead = nil
    let chunk = buffer.prefix(count)
    buffer.removeFirst(count)
    completion(.success(Data(chunk)))
  }
}

/// Implementation of `TransportConnection` backed by Apple's `NWConnection` (TCP/LAN).
final class NWTransportConnection: TransportConnection {
  let connection: NWConnection

  var isConnected: Bool {
    connection.state == .ready
  }

  init(connection: NWConnection) {
    self.connection = connection
  }

  func send(data: Data, completion: @escaping (Error?) -> Void) {
    connection.send(
      content: data,
      completion: .contentProcessed { error in
        completion(error)
      })
  }

  func receive(exactByteCount count: Int, completion: @escaping (Result<Data, Error>) -> Void) {
    connection.receive(minimumIncompleteLength: count, maximumLength: count) {
      data, _, isComplete, error in
      if let error = error {
        completion(.failure(error))
        return
      }
      guard let data = data, data.count == count else {
        if isComplete {
          completion(.failure(SecureChannelError.connectionClosed))
        } else {
          completion(.failure(SecureChannelError.framingFailed))
        }
        return
      }
      completion(.success(data))
    }
  }

  func cancel() {
    connection.cancel()
  }
}
