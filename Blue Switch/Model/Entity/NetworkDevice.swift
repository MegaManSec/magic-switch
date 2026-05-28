import Foundation

/// Represents a network device with its connection state and identity information
struct NetworkDevice: Identifiable, Codable {
  // MARK: - Properties

  /// Unique identifier of the device (using device name)
  let id: String

  /// Display name of the device
  var name: String

  /// Hostname or IP address of the device
  var host: String

  /// Communication port number of the device
  var port: Int

  /// Timestamp of the last device update
  var lastUpdated: Date

  /// Indicates whether the device is currently active and available
  var isActive: Bool

  /// Peer PSK fingerprint from the Bonjour TXT record (`fp` key). Used for
  /// TOFU identity pinning: once a fingerprint is captured for a registered
  /// device, advertisements with a different fingerprint are treated as
  /// impersonation attempts and the routing info is not updated.
  var fingerprint: String?

  /// When a peer advertises a fingerprint that does not match the stored
  /// pin, the new one is held here pending an explicit user "Trust" action
  /// (which moves it into `fingerprint`). nil means no mismatch is pending.
  var pendingFingerprint: String?

  // MARK: - Initialization

  /// Creates a new network device instance
  /// - Parameters:
  ///   - id: Unique identifier for the device
  ///   - name: Display name of the device
  ///   - host: Hostname or IP address
  ///   - port: Communication port number
  ///   - isActive: Initial active state of the device
  ///   - fingerprint: Optional peer PSK fingerprint (TOFU pin)
  init(
    id: String,
    name: String,
    host: String,
    port: Int,
    isActive: Bool = true,
    fingerprint: String? = nil
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.port = port
    self.lastUpdated = Date()
    self.isActive = isActive
    self.fingerprint = fingerprint
  }

  // MARK: - Public Methods

  /// Updates the device information with data from another device, applying
  /// the TOFU fingerprint pin: a mismatch between our stored fingerprint and
  /// the peer's advertised fingerprint causes us to drop the new routing
  /// info, mark the device inactive, and stash the incoming fingerprint as
  /// `pendingFingerprint` so the user can explicitly trust it later.
  mutating func update(with device: NetworkDevice) {
    if let stored = fingerprint,
      let incoming = device.fingerprint,
      stored != incoming
    {
      isActive = false
      lastUpdated = Date()
      pendingFingerprint = incoming
      return
    }
    if fingerprint == nil, let incoming = device.fingerprint {
      fingerprint = incoming
    }
    pendingFingerprint = nil
    host = device.host
    port = device.port
    lastUpdated = Date()
    isActive = device.isActive
  }
}
