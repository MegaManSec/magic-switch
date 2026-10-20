import CoreBluetooth
import Foundation

/// Constants and identifiers used for Bluetooth LE peer-to-peer transport.
enum MagicSwitchBLE {
  /// The primary GATT service UUID advertised by Magic Switch peers.
  static let serviceUUID = CBUUID(string: "9B575301-2D62-4C1B-8B23-7F637C5E4801")

  /// Characteristic for Central-to-Peripheral command stream writes.
  /// Central writes frames here (with response for reliability).
  static let commandCharacteristicUUID = CBUUID(string: "9B575302-2D62-4C1B-8B23-7F637C5E4801")

  /// Characteristic for Peripheral-to-Central response stream notifications.
  /// Peripheral notifies Central when sending response frames.
  static let responseCharacteristicUUID = CBUUID(string: "9B575303-2D62-4C1B-8B23-7F637C5E4801")

  /// Characteristic exposing peer identity metadata (device name and TOFU PSK fingerprint).
  /// Readable by Central immediately upon connection to determine peer identity.
  static let metadataCharacteristicUUID = CBUUID(string: "9B575304-2D62-4C1B-8B23-7F637C5E4801")

  /// Protocol version for Bluetooth transport.
  static let protocolVersion = 2

  /// 4-byte control sequence sent by Central to initialize a new session on Peripheral.
  static let sessionStartMagic = Data([0xFF, 0xFF, 0xFF, 0x01])

  /// 4-byte control sequence sent by Central when tearing down a session.
  static let sessionEndMagic = Data([0xFF, 0xFF, 0xFF, 0x02])

  /// Maximum chunk size for Bluetooth characteristic writes (safe default within standard BLE MTU).
  static let maxChunkSize = 500

  /// Connection timeout for establishing a BLE connection to a discovered peer.
  static let bleConnectTimeout: TimeInterval = 6.0
}

/// Metadata payload advertised/read via the BLE metadata characteristic.
struct BLEPeerMetadata: Codable {
  let name: String
  let fingerprint: String?
  let version: Int
}
