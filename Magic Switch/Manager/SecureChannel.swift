import CryptoKit
import Foundation
import Network

/// Errors thrown by the secure channel layer.
enum SecureChannelError: Error {
  case connectionClosed
  case framingFailed
  case frameTooLarge
  case decryptionFailed
  case replay
  case authFailed
  case handshakeTimeout
  case sendFailed(Error)
}

/// On-wire framing + ChaCha20-Poly1305 session for a single NWConnection.
/// Handshake:
///   * Each side sends a 32-byte random nonce (length-prefixed cleartext).
///   * Both derive HKDF(K, salt=N_C||N_S) -> [sk_c2s | sk_s2c | k_mac] (96 bytes).
///   * Each side sends a sealed `HMAC(k_mac, role || N_C || N_S)` over the
///     handshake transcript and verifies the peer's MAC in constant time.
/// The role tag prevents reflection: Mac A can't replay its MAC back as if
/// it were Mac B's.
/// After auth, each sealed frame is [u32-BE length][12-byte counter nonce][ciphertext+tag].
final class SecureChannel {
  // MARK: - Constants

  static let nonceLength = 32
  static let maxFrameSize: UInt32 = 65536
  static let aeadNonceLength = 12
  private static let hkdfInfo = Data("magicswitch-session-v2".utf8)
  private static let clientRoleTag = Data("client".utf8)
  private static let serverRoleTag = Data("server".utf8)
  private static let handshakeTimeout: TimeInterval = 5.0

  // MARK: - Roles

  enum Role {
    case client
    case server
  }

  // MARK: - State

  private let connection: NWConnection
  private let role: Role
  private let psk: SymmetricKey
  private let queue: DispatchQueue

  private var sendKey: SymmetricKey?
  private var receiveKey: SymmetricKey?
  private var macKey: SymmetricKey?
  private var sendCounter: UInt64 = 0
  private var lastReceivedCounter: UInt64?
  private var receivedAuth: Bool = false
  private var teardown = false

  // MARK: - Init

  init(connection: NWConnection, role: Role, psk: SymmetricKey, queue: DispatchQueue) {
    self.connection = connection
    self.role = role
    self.psk = psk
    self.queue = queue
  }

  // MARK: - Handshake

  /// Performs the handshake and verifies the peer's transcript MAC. On
  /// success calls `completion(.success(()))`; on failure closes the
  /// connection and returns the relevant error.
  func performHandshake(
    completion outerCompletion: @escaping (Result<Void, SecureChannelError>) -> Void
  ) {
    // Single-shot latch on the outer completion. The 5-second timeout fires
    // `connection.cancel()`, which then propagates to any in-flight
    // `sendRaw`/`receiveRaw` as a connection error and re-enters this
    // completion path with `.connectionClosed` *after* we've already
    // reported `.handshakeTimeout`. The race is by design — `cancel()` is
    // the cleanest way to abort all the nested I/O — so we just absorb the
    // duplicate via the latch instead of trying to suppress one path or the
    // other.
    var completed = false
    let completion: (Result<Void, SecureChannelError>) -> Void = { result in
      guard !completed else { return }
      completed = true
      outerCompletion(result)
    }

    var localNonce = Data(count: Self.nonceLength)
    let nonceStatus = localNonce.withUnsafeMutableBytes { buf in
      SecRandomCopyBytes(kSecRandomDefault, Self.nonceLength, buf.baseAddress!)
    }
    // Same rationale as `PairingStore.generateCode`: if the syscall fails
    // we'd silently negotiate a session with an all-zero nonce — replayable
    // and predictable. Crash rather than weaken the channel.
    precondition(
      nonceStatus == errSecSuccess,
      "SecRandomCopyBytes failed with status \(nonceStatus); refusing to handshake with a weak nonce."
    )

    let timeoutWork = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      if !self.receivedAuth {
        self.teardown = true
        self.connection.cancel()
        completion(.failure(.handshakeTimeout))
      }
    }
    queue.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: timeoutWork)

    // Send our nonce as a length-prefixed cleartext frame.
    sendRaw(payload: localNonce) { [weak self] err in
      guard let self = self else { return }
      if let err = err {
        timeoutWork.cancel()
        completion(.failure(.sendFailed(err)))
        return
      }

      self.receiveRaw { result in
        switch result {
        case .failure(let e):
          timeoutWork.cancel()
          completion(.failure(e))
        case .success(let remoteNonce):
          guard remoteNonce.count == Self.nonceLength else {
            timeoutWork.cancel()
            completion(.failure(.framingFailed))
            return
          }

          let (clientNonce, serverNonce): (Data, Data)
          switch self.role {
          case .client: (clientNonce, serverNonce) = (localNonce, remoteNonce)
          case .server: (clientNonce, serverNonce) = (remoteNonce, localNonce)
          }

          self.deriveKeys(clientNonce: clientNonce, serverNonce: serverNonce)

          guard let macKey = self.macKey else {
            timeoutWork.cancel()
            completion(.failure(.authFailed))
            return
          }

          let ourTag: Data = (self.role == .client) ? Self.clientRoleTag : Self.serverRoleTag
          let peerTag: Data = (self.role == .client) ? Self.serverRoleTag : Self.clientRoleTag
          let ourMac = Data(
            HMAC<SHA256>.authenticationCode(
              for: ourTag + clientNonce + serverNonce, using: macKey))
          let expectedPeerMac = Data(
            HMAC<SHA256>.authenticationCode(
              for: peerTag + clientNonce + serverNonce, using: macKey))

          self.sendSealed(payload: ourMac) { sealErr in
            if let sealErr = sealErr {
              timeoutWork.cancel()
              completion(.failure(sealErr))
              return
            }
            self.receiveSealed { recvResult in
              timeoutWork.cancel()
              switch recvResult {
              case .failure(let e):
                completion(.failure(e))
              case .success(let receivedMac):
                if Self.constantTimeEqual(receivedMac, expectedPeerMac) {
                  self.receivedAuth = true
                  completion(.success(()))
                } else {
                  completion(.failure(.authFailed))
                }
              }
            }
          }
        }
      }
    }
  }

  private func deriveKeys(clientNonce: Data, serverNonce: Data) {
    var salt = Data()
    salt.append(clientNonce)
    salt.append(serverNonce)

    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: psk,
      salt: salt,
      info: Self.hkdfInfo,
      outputByteCount: 96
    )

    let raw = derived.withUnsafeBytes { Data($0) }
    let c2s = SymmetricKey(data: raw.prefix(32))
    let s2c = SymmetricKey(data: raw.dropFirst(32).prefix(32))
    let mac = SymmetricKey(data: raw.suffix(32))

    switch role {
    case .client:
      sendKey = c2s
      receiveKey = s2c
    case .server:
      sendKey = s2c
      receiveKey = c2s
    }
    macKey = mac
  }

  // MARK: - Public Sealed I/O

  /// Sends a sealed message; the connection is cancelled on failure.
  func send(_ payload: Data, completion: @escaping (SecureChannelError?) -> Void) {
    sendSealed(payload: payload, completion: completion)
  }

  /// Receives one sealed message and decrypts. The completion is called once.
  func receive(completion: @escaping (Result<Data, SecureChannelError>) -> Void) {
    receiveSealed(completion: completion)
  }

  /// Closes the underlying connection.
  func cancel() {
    teardown = true
    connection.cancel()
  }

  // MARK: - Sealed Framing

  private func sendSealed(payload: Data, completion: @escaping (SecureChannelError?) -> Void) {
    guard let sendKey = sendKey else {
      completion(.authFailed)
      return
    }

    var nonceBytes = Data(count: Self.aeadNonceLength)
    let counter = sendCounter
    sendCounter &+= 1
    nonceBytes.withUnsafeMutableBytes { raw in
      let base = raw.bindMemory(to: UInt8.self).baseAddress!
      var c = counter.littleEndian
      withUnsafeBytes(of: &c) { src in
        for i in 0..<8 {
          base[i] = src.load(fromByteOffset: i, as: UInt8.self)
        }
      }
    }

    do {
      let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
      let box = try ChaChaPoly.seal(payload, using: sendKey, nonce: nonce)
      var frame = Data()
      frame.append(box.nonce.withUnsafeBytes { Data($0) })
      frame.append(box.ciphertext)
      frame.append(box.tag)
      sendRaw(
        payload: frame,
        completion: { err in
          if let err = err {
            completion(.sendFailed(err))
          } else {
            completion(nil)
          }
        })
    } catch {
      completion(.decryptionFailed)
    }
  }

  private func receiveSealed(completion: @escaping (Result<Data, SecureChannelError>) -> Void) {
    guard let receiveKey = receiveKey else {
      completion(.failure(.authFailed))
      return
    }
    receiveRaw { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .failure(let e):
        completion(.failure(e))
      case .success(let frame):
        guard frame.count >= Self.aeadNonceLength + 16 else {
          completion(.failure(.framingFailed))
          return
        }
        let nonceData = frame.prefix(Self.aeadNonceLength)
        let rest = frame.dropFirst(Self.aeadNonceLength)
        let tagStart = rest.count - 16
        let ciphertext = rest.prefix(tagStart)
        let tag = rest.suffix(16)

        // Decode counter (little-endian) and verify monotonicity.
        var counter: UInt64 = 0
        nonceData.prefix(8).withUnsafeBytes { raw in
          var le: UInt64 = 0
          memcpy(&le, raw.baseAddress, 8)
          counter = UInt64(littleEndian: le)
        }
        if let last = self.lastReceivedCounter, counter <= last {
          completion(.failure(.replay))
          return
        }

        do {
          let nonce = try ChaChaPoly.Nonce(data: nonceData)
          let box = try ChaChaPoly.SealedBox(
            nonce: nonce, ciphertext: ciphertext, tag: tag
          )
          let plaintext = try ChaChaPoly.open(box, using: receiveKey)
          self.lastReceivedCounter = counter
          completion(.success(plaintext))
        } catch {
          completion(.failure(.decryptionFailed))
        }
      }
    }
  }

  // MARK: - Raw Length-Prefixed Framing

  private func sendRaw(payload: Data, completion: @escaping (Error?) -> Void) {
    var lengthBE = UInt32(payload.count).bigEndian
    var frame = Data()
    withUnsafeBytes(of: &lengthBE) { frame.append(contentsOf: $0) }
    frame.append(payload)
    connection.send(
      content: frame,
      completion: .contentProcessed { error in
        completion(error)
      })
  }

  private func receiveRaw(completion: @escaping (Result<Data, SecureChannelError>) -> Void) {
    receiveExact(byteCount: 4) { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .failure(let e):
        completion(.failure(e))
      case .success(let lenData):
        var length: UInt32 = 0
        lenData.withUnsafeBytes { raw in
          var be: UInt32 = 0
          memcpy(&be, raw.baseAddress, 4)
          length = UInt32(bigEndian: be)
        }
        if length == 0 || length > Self.maxFrameSize {
          completion(.failure(.frameTooLarge))
          return
        }
        self.receiveExact(byteCount: Int(length), completion: completion)
      }
    }
  }

  private func receiveExact(
    byteCount: Int, completion: @escaping (Result<Data, SecureChannelError>) -> Void
  ) {
    connection.receive(minimumIncompleteLength: byteCount, maximumLength: byteCount) {
      data, _, isComplete, error in
      if error != nil {
        completion(.failure(.connectionClosed))
        return
      }
      guard let data = data, data.count == byteCount else {
        if isComplete {
          completion(.failure(.connectionClosed))
        } else {
          completion(.failure(.framingFailed))
        }
        return
      }
      completion(.success(data))
    }
  }

  // MARK: - Helpers

  /// Constant-time byte comparison. Same length only; differing lengths
  /// return false without revealing position via timing.
  static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    a.withUnsafeBytes { aRaw in
      b.withUnsafeBytes { bRaw in
        let aBytes = aRaw.bindMemory(to: UInt8.self)
        let bBytes = bRaw.bindMemory(to: UInt8.self)
        for i in 0..<a.count {
          diff |= aBytes[i] ^ bBytes[i]
        }
      }
    }
    return diff == 0
  }
}
