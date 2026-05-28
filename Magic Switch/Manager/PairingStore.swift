import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Errors that can occur during pairing operations
enum PairingError: Error {
  case invalidCode
  case derivationFailed
  case keychainFailed(OSStatus)
}

/// Manages the pre-shared key used to authenticate peer Magic Switch installs.
/// Persists the derived 32-byte key in the keychain; exposes a published
/// `isPaired` flag plus a short fingerprint suitable for visual verification.
final class PairingStore: ObservableObject {
  // MARK: - Singleton

  static let shared = PairingStore()

  // MARK: - Constants

  static let codeLength = 12
  static let codeAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  private static let pbkdfSalt = "MagicSwitch-PSK-v2"
  private static let pbkdfIterations: UInt32 = 600_000
  private static let pbkdfKeyLength = 32
  /// Service name reflects the previous `psk-v3` data-protection-keychain
  /// attempt that was reverted: `kSecUseDataProtectionKeychain` requires
  /// either a real Team ID or a sandbox-derived access group, neither of
  /// which an ad-hoc-signed sandboxed build of this app has. `SecItemAdd`
  /// fails with `errSecMissingEntitlement` (-34018) and pairing breaks.
  /// We kept the v3 service name so the boundary in users' keychains is
  /// still explicit — items at v3 in the legacy keychain are this fork's;
  /// items at v2 are from before that breaking change.
  private static let keychainService = "com.magicswitch.psk-v3"
  private static let keychainAccount = "shared"

  // MARK: - Published State

  @Published private(set) var isPaired: Bool = false
  @Published private(set) var fingerprint: String? = nil

  // MARK: - Initialization

  private init() {
    refreshState()
  }

  // MARK: - Public API

  /// Returns the currently stored PSK, or nil if unpaired.
  func currentKey() -> SymmetricKey? {
    guard let data = readKeyData() else { return nil }
    return SymmetricKey(data: data)
  }

  /// Generates a random pairing code of `codeLength` characters from the
  /// Crockford Base32 alphabet (no I/L/O/U).
  static func generateCode() -> String {
    let alphabet = Array(codeAlphabet)
    var bytes = [UInt8](repeating: 0, count: codeLength)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    // `SecRandomCopyBytes` failing is extremely unlikely on a healthy
    // system, but if it did and we ignored the status we'd silently
    // generate "AAAAAAAAAAAA" (every byte still zero) — i.e. a guessable
    // pairing key. Crash hard instead.
    precondition(
      status == errSecSuccess,
      "SecRandomCopyBytes failed with status \(status); refusing to generate a weak pairing code."
    )
    var result = ""
    for byte in bytes {
      result.append(alphabet[Int(byte) % alphabet.count])
    }
    return result
  }

  /// Returns a display form (`XXXX-XXXX-XXXX`) for a 12-char code.
  static func formatCode(_ code: String) -> String {
    let normalized = normalize(code)
    guard normalized.count == codeLength else { return normalized }
    let chars = Array(normalized)
    return "\(String(chars[0...3]))-\(String(chars[4...7]))-\(String(chars[8...11]))"
  }

  /// Normalizes free-form user input: uppercase, then apply Crockford's
  /// look-alike substitutions (I/L → 1, O → 0, U → V) so common typos of
  /// the excluded letters resolve to the visually-similar canonical
  /// character instead of being silently dropped. Anything still outside
  /// the alphabet (dashes, spaces, etc.) is then filtered out.
  static func normalize(_ input: String) -> String {
    let upper = input.uppercased()
    let substituted = upper.map { char -> Character in
      switch char {
      case "I", "L": return "1"
      case "O": return "0"
      case "U": return "V"
      default: return char
      }
    }
    return String(substituted).filter { codeAlphabet.contains($0) }
  }

  /// Validates that `code` is exactly `codeLength` chars in the alphabet.
  static func isValid(_ code: String) -> Bool {
    let normalized = normalize(code)
    guard normalized.count == codeLength else { return false }
    return normalized.allSatisfy { codeAlphabet.contains($0) }
  }

  /// Derives K from a pairing code and stores it in the keychain.
  /// Runs the PBKDF2 derivation off-main (600k iterations is ~half a second)
  /// and reports back on main. The published state is updated before the
  /// completion fires.
  func pair(
    withCode code: String,
    completion: @escaping (Result<Void, PairingError>) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      let normalized = Self.normalize(code)
      guard Self.isValid(normalized) else {
        DispatchQueue.main.async { completion(.failure(.invalidCode)) }
        return
      }
      do {
        let key = try Self.deriveKey(fromCode: normalized)
        try self.writeKeyData(key)
        DispatchQueue.main.async {
          self.refreshState()
          completion(.success(()))
        }
      } catch let error as PairingError {
        DispatchQueue.main.async { completion(.failure(error)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(.derivationFailed)) }
      }
    }
  }

  /// Removes the stored PSK. Runs the keychain call off-main so the
  /// authorization prompt (if any) doesn't block the UI, and updates the
  /// published state directly on success rather than re-reading the
  /// keychain — the re-read could trigger a second authorization prompt
  /// on the same item we just had to authorize, which manifested as the
  /// user needing to click Unpair twice.
  ///
  /// `completion` receives `nil` on success or the underlying `OSStatus`
  /// when SecItemDelete fails for any reason other than "item not found".
  /// We pass that back so the Pairing tab can render an inline error in
  /// the view itself — system notifications are unreliable on
  /// ad-hoc-signed sandboxed builds (UNUserNotificationCenter refuses to
  /// authorize them), so an Unpair that fails would otherwise look like
  /// "nothing happened".
  func unpair(completion: ((OSStatus?) -> Void)? = nil) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: Self.keychainService,
        kSecAttrAccount as String: Self.keychainAccount,
      ]
      let status = SecItemDelete(query as CFDictionary)
      print("PairingStore.unpair: SecItemDelete -> \(status)")
      DispatchQueue.main.async {
        if status == errSecSuccess || status == errSecItemNotFound {
          self.isPaired = false
          self.fingerprint = nil
          completion?(nil)
        } else {
          completion?(status)
        }
      }
    }
  }

  // MARK: - Internal Helpers

  /// PBKDF2-HMAC-SHA256 derivation of the PSK from the pairing code.
  static func deriveKey(fromCode code: String) throws -> Data {
    guard let codeData = code.data(using: .utf8),
      let saltData = pbkdfSalt.data(using: .utf8)
    else {
      throw PairingError.derivationFailed
    }

    var derived = Data(count: pbkdfKeyLength)
    let status: Int32 = derived.withUnsafeMutableBytes { derivedBytes in
      saltData.withUnsafeBytes { saltBytes in
        codeData.withUnsafeBytes { codeBytes in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            codeBytes.bindMemory(to: Int8.self).baseAddress,
            codeData.count,
            saltBytes.bindMemory(to: UInt8.self).baseAddress,
            saltData.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            pbkdfIterations,
            derivedBytes.bindMemory(to: UInt8.self).baseAddress,
            pbkdfKeyLength
          )
        }
      }
    }
    guard status == kCCSuccess else { throw PairingError.derivationFailed }
    return derived
  }

  /// First 4 bytes of SHA256(K), hex-encoded.
  static func fingerprint(forKey key: Data) -> String {
    let digest = SHA256.hash(data: key)
    let prefix = Array(digest).prefix(4)
    return prefix.map { String(format: "%02X", $0) }.joined()
  }

  // MARK: - Private Methods

  private func refreshState() {
    if let data = readKeyData() {
      isPaired = true
      fingerprint = Self.fingerprint(forKey: data)
    } else {
      isPaired = false
      fingerprint = nil
    }
  }

  private func readKeyData() -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: Self.keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return data
  }

  private func writeKeyData(_ data: Data) throws {
    let delete: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: Self.keychainAccount,
    ]
    SecItemDelete(delete as CFDictionary)

    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: Self.keychainAccount,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
      kSecValueData as String: data,
    ]
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw PairingError.keychainFailed(status)
    }
  }
}
