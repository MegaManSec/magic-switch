import Foundation
import IOBluetooth

/// Runtime connection state of a peripheral. Not persisted — owned by
/// `BluetoothPeripheralStore`, surfaced to views via `connectionState(for:)`.
enum PeripheralConnectionState: Equatable {
  case disconnected
  case connecting
  case connected
}

/// Represents a Bluetooth peripheral device with its connection state and identity information
struct BluetoothPeripheral: Identifiable, Codable {
  // MARK: - Properties

  /// Unique identifier (MAC address) of the Bluetooth device
  let id: String

  /// Display name of the Bluetooth device
  var name: String

  // MARK: - Codable

  private enum CodingKeys: String, CodingKey {
    case id
    case name
  }

  init(id: String, name: String) {
    self.id = id
    self.name = name
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    let rawId = try container.decode(String.self, forKey: .id)
    // MAC address as formatted by IOBluetoothDevice.addressString (e.g. "aa-bb-cc-dd-ee-ff").
    let macPattern = "^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$"
    if rawId.range(of: macPattern, options: .regularExpression) == nil {
      throw DecodingError.dataCorruptedError(
        forKey: .id, in: container, debugDescription: "invalid MAC address format")
    }
    self.id = rawId

    let rawName = try container.decode(String.self, forKey: .name)
    if rawName.trimmingCharacters(in: .whitespaces).isEmpty {
      throw DecodingError.dataCorruptedError(
        forKey: .name, in: container, debugDescription: "name must not be empty")
    }
    // Peer-supplied names are user-controlled; truncate rather than fail the whole sync.
    self.name = rawName.count > 128 ? String(rawName.prefix(128)) : rawName
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
  }
}
