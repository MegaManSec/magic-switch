import Foundation

/// Why a `magicswitch://` URL couldn't be parsed or resolved. `message` is the
/// user-facing text for the failure notification — an external trigger (a
/// hotkey, a script) has no UI of its own, so a notification is the only
/// feedback channel.
enum URLCommandError: Error {
  case unknownCommand(String)
  case unknownParameter(String)
  case invalidDirection(String)
  case emptyPeripheral
  case noMatch(String)

  var message: String {
    switch self {
    case .unknownCommand(let url):
      return "Unrecognized command URL '\(url)'. The only command is magicswitch://switch."
    case .unknownParameter(let name):
      return "Unknown parameter '\(name)'. Supported: 'peripheral' and 'direction'."
    case .invalidDirection(let value):
      return "Invalid direction '\(value)'. Use 'take', 'send', or 'toggle'."
    case .emptyPeripheral:
      return "'peripheral' needs a value: a type (e.g. 'trackpad'), a name, or a MAC address."
    case .noMatch(let selector):
      return "No registered peripheral matches '\(selector)'."
    }
  }
}

/// A parsed `magicswitch://switch` URL — the app's external-control surface.
/// Anything that can open a URL (a hotkey utility, a mouse-button macro,
/// `open -g` in a script) can trigger the same switches as the dropdown:
///
///     magicswitch://switch                             toggle the full set
///     magicswitch://switch?direction=take              bring the full set here
///     magicswitch://switch?peripheral=trackpad&direction=take
///     magicswitch://switch?peripheral=trackpad&peripheral=mouse
///
/// Parsing is strict: an unknown command or parameter fails the whole URL
/// rather than degrading — a typo like `perpheral=` must not silently become
/// a full-set switch. This type only parses and resolves; execution lives in
/// `AppDelegate.handleCommandURL`.
struct SwitchURLCommand {
  /// How one `peripheral=` value picks registered peripherals. Classified at
  /// parse time, most-specific reading first — MAC address, else type
  /// keyword, else display name — so a peripheral literally named "Mouse"
  /// can still be pinned down by its address.
  enum PeripheralSelector {
    /// Exact `BluetoothPeripheral.id` (IOBluetooth's "aa-bb-cc-dd-ee-ff"), lowercased.
    case address(String)
    /// Every registered peripheral whose resolved type matches.
    case type(PeripheralType)
    /// Every registered peripheral with this display name, case-insensitively.
    case name(String)

    /// The value as the caller wrote it, for "no match" error text.
    var label: String {
      switch self {
      case .address(let address): return address
      case .type(let type): return type.rawValue
      case .name(let name): return name
      }
    }

    func matches(_ peripheral: BluetoothPeripheral, in store: BluetoothPeripheralStore) -> Bool {
      switch self {
      case .address(let address):
        return peripheral.id.lowercased() == address
      case .type(let type):
        return store.peripheralType(for: peripheral) == type
      case .name(let name):
        return peripheral.name.caseInsensitiveCompare(name) == .orderedSame
      }
    }
  }

  let direction: SwitchDirection
  /// Empty means the whole registered set.
  let selectors: [PeripheralSelector]

  static func parse(_ url: URL) -> Result<SwitchURLCommand, URLCommandError> {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.host == "switch",
      components.path.isEmpty || components.path == "/"
    else {
      return .failure(.unknownCommand(url.absoluteString))
    }
    var direction = SwitchDirection.toggle
    var selectors: [PeripheralSelector] = []
    for item in components.queryItems ?? [] {
      switch item.name {
      case "direction":
        guard let value = item.value, let parsed = SwitchDirection(rawValue: value) else {
          return .failure(.invalidDirection(item.value ?? ""))
        }
        direction = parsed
      case "peripheral":
        guard let value = item.value, !value.isEmpty else {
          return .failure(.emptyPeripheral)
        }
        selectors.append(classify(value))
      default:
        return .failure(.unknownParameter(item.name))
      }
    }
    return .success(SwitchURLCommand(direction: direction, selectors: selectors))
  }

  /// Union of every selector's matches, in registration order without
  /// duplicates. A selector that matches nothing fails the whole command —
  /// better a "no match" notification than half a command silently acting.
  func resolvePeripherals(
    in store: BluetoothPeripheralStore
  ) -> Result<[BluetoothPeripheral], URLCommandError> {
    var seen = Set<String>()
    var resolved: [BluetoothPeripheral] = []
    for selector in selectors {
      let matches = store.peripherals.filter { selector.matches($0, in: store) }
      guard !matches.isEmpty else { return .failure(.noMatch(selector.label)) }
      for peripheral in matches where seen.insert(peripheral.id).inserted {
        resolved.append(peripheral)
      }
    }
    return .success(resolved)
  }

  /// `.unknown` is excluded from the type keywords: "unknown" as a selector
  /// is far likelier a typo than a request for every unclassified device.
  private static func classify(_ value: String) -> PeripheralSelector {
    // Same shape check as `BluetoothPeripheral`'s decoder: the MAC address as
    // formatted by `IOBluetoothDevice.addressString`.
    if value.range(of: "^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$", options: .regularExpression) != nil {
      return .address(value.lowercased())
    }
    if let type = PeripheralType(rawValue: value.lowercased()), type != .unknown {
      return .type(type)
    }
    return .name(value)
  }
}
