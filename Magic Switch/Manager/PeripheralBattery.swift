import Foundation
import IOKit

/// Reads battery levels for connected Bluetooth peripherals from the
/// IORegistry: Apple's Magic devices publish `BatteryPercent` (alongside the
/// device's Bluetooth `DeviceAddress`) on their HID event-service node while
/// connected to this Mac. Read-at-render, no caching — a registry walk is
/// cheap, and the value only exists for peripherals currently held here.
enum PeripheralBattery {
  /// Battery percentage (0–100) for the peripheral with the given Bluetooth
  /// address (IOBluetooth's "aa-bb-cc-dd-ee-ff" format), or nil when the
  /// device isn't connected to this Mac or doesn't report battery.
  static func percent(forAddress address: String) -> Int? {
    let wanted = normalize(address)
    var iterator = io_iterator_t()
    // Port 0 = default master port; the named constant for it was renamed in
    // macOS 12 (kIOMasterPortDefault → kIOMainPortDefault) and using either
    // spelling trips a warning on the other side of the deployment range.
    guard
      IOServiceGetMatchingServices(
        0, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }

    while case let entry = IOIteratorNext(iterator), entry != 0 {
      defer { IOObjectRelease(entry) }
      guard let deviceAddress = property(entry, "DeviceAddress") as? String,
        normalize(deviceAddress) == wanted,
        let percent = property(entry, "BatteryPercent") as? Int
      else { continue }
      return percent
    }
    return nil
  }

  private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue()
  }

  /// IOBluetooth formats addresses "aa-bb-cc-dd-ee-ff"; the HID registry
  /// uses "aa:bb:cc:dd:ee:ff". Fold both to one form before comparing.
  private static func normalize(_ address: String) -> String {
    address.lowercased().replacingOccurrences(of: ":", with: "-")
  }
}
