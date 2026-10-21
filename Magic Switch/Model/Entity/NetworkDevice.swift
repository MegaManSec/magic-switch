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
  /// the TOFU fingerprint pin. Once a fingerprint is pinned, the routing info
  /// (`host`/`port`/`isActive`) is only updated by an advertisement carrying
  /// that same fingerprint. A *different* fingerprint is dropped, the device
  /// marked inactive, and the incoming value stashed as `pendingFingerprint`
  /// for an explicit user "Trust". A *missing* fingerprint is ignored entirely
  /// — it can't prove the pinned identity, so an impersonator advertising the
  /// peer's Bonjour name with no `fp` can't re-point us at their machine.
  mutating func update(with device: NetworkDevice) {
    // Once a fingerprint is pinned (TOFU), only an advertisement that proves
    // that exact identity may move the routing info.
    if let stored = fingerprint {
      guard let incoming = device.fingerprint else {
        // No fingerprint at all can't prove the pinned identity, so refuse to
        // touch any state from it. A legitimately paired peer always
        // advertises its `fp`, so a missing one is either a peer that unpaired
        // (it would reject commands anyway, and the reachability ping to the
        // still-pinned host will mark it unreachable) or an attacker
        // advertising the peer's Bonjour name to silently re-point host/port
        // at a machine they control. Leaving the verified routing and the
        // active flag untouched denies the attacker any influence.
        return
      }
      if stored != incoming {
        // Different fingerprint: a possible re-pair. Park the new value for an
        // explicit user "Trust" and stop treating the device as switchable
        // until then.
        isActive = false
        lastUpdated = Date()
        pendingFingerprint = incoming
        return
      }
      // Fingerprint matches the pin — a trusted update.
      pendingFingerprint = nil
      host = device.host
      port = device.port
      lastUpdated = Date()
      isActive = device.isActive
      return
    }

    // No pin yet: first contact. Capture any advertised fingerprint as the pin
    // and accept the routing info (classic trust-on-first-use).
    if let incoming = device.fingerprint {
      fingerprint = incoming
    }
    pendingFingerprint = nil
    host = device.host
    port = device.port
    lastUpdated = Date()
    isActive = device.isActive
  }
}
