import AppKit
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
struct BluetoothPeripheral: Identifiable, Codable, Equatable {
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

/// Logical category of a peripheral. Drives the row glyph in the menu-bar
/// dropdown and the Peripheral settings tab, and the choices in the manual type
/// picker. The resolved type is `user override ?? auto-detected`;
/// `BluetoothPeripheralStore` owns both halves (`typeOverrides`, `deviceClasses`).
enum PeripheralType: String, Codable, CaseIterable {
  case keyboard
  case mouse
  case trackpad
  case headphones
  case airpods
  case microphone
  case unknown

  /// Types offered in the manual picker, in order. Includes `.unknown`
  /// ("Other") so a device can be forced to the generic glyph; the picker adds
  /// "Automatic" (which clears the override) separately.
  static let selectable: [PeripheralType] = [
    .keyboard, .mouse, .trackpad, .headphones, .airpods, .microphone, .unknown,
  ]

  /// Title shown in the manual picker.
  var label: String {
    switch self {
    case .keyboard: return "Keyboard"
    case .mouse: return "Mouse"
    case .trackpad: return "Trackpad"
    case .headphones: return "Headphones"
    case .airpods: return "AirPods"
    case .microphone: return "Microphone"
    case .unknown: return "Other"
    }
  }

  /// SF Symbol candidates, most-specific/newest first. The running macOS may
  /// not have the newest glyph (`NSImage(systemSymbolName:)` returns nil for an
  /// absent symbol), so `symbolName` walks these to the first that resolves.
  var symbolCandidates: [String] {
    switch self {
    case .keyboard: return ["keyboard"]
    case .mouse: return ["magicmouse", "computermouse", "cursorarrow"]
    case .trackpad:
      return ["rectangle.and.hand.point.up.left", "hand.point.up.left", "cursorarrow"]
    case .headphones: return ["headphones"]
    case .airpods: return ["airpods", "headphones"]
    case .microphone: return ["mic"]
    case .unknown: return ["questionmark.circle"]
    }
  }

  /// First candidate glyph available on this macOS, else a guaranteed fallback.
  var symbolName: String {
    symbolCandidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
      ?? "questionmark.circle"
  }

  /// Classify from the device name and, when known, its Bluetooth Class of
  /// Device. CoD wins for audio gear (names like "WH-1000XM4" don't say
  /// "headphones"); the name settles what CoD can't — AirPods vs any other
  /// headset, and mouse vs trackpad (both report as a generic pointing device).
  static func detect(name: String, classOfDevice: UInt32?) -> PeripheralType {
    let lower = name.lowercased()

    // CoD can't distinguish AirPods from any other Bluetooth headset, so the
    // name is the only signal — check it before anything else.
    if lower.contains("airpod") { return .airpods }

    if let cod = classOfDevice, cod != 0 {
      // "Class of Device": major class in bits 8-12, minor class in bits 2-7.
      let major = (cod >> 8) & 0x1F
      let minor = (cod >> 2) & 0x3F
      switch major {
      case 0x05:  // Peripheral
        // Minor bits 4-5: keyboard (0x10) / pointing (0x20) / combo (0x30).
        switch minor & 0x30 {
        case 0x10: return .keyboard
        case 0x20: return lower.contains("trackpad") ? .trackpad : .mouse
        default: break
        }
      case 0x04:  // Audio / Video
        switch minor {
        case 0x04: return .microphone  // microphone
        case 0x01, 0x02, 0x06, 0x07, 0x0A: return .headphones  // headset / headphones
        default: break
        }
      default:
        break
      }
    }

    // No (or inconclusive) Class of Device — fall back to the name.
    if lower.contains("keyboard") { return .keyboard }
    if lower.contains("trackpad") { return .trackpad }
    if lower.contains("mouse") { return .mouse }
    if lower.contains("microphone") { return .microphone }
    if lower.contains("headphone") || lower.contains("headset")
      || lower.contains("buds") || lower.contains("beats")
    {
      return .headphones
    }
    return .unknown
  }
}
