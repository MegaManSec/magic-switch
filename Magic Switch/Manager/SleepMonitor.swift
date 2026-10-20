import Foundation
import IOKit
import IOKit.pwr_mgt

/// IOKit power message types from `<IOKit/IOMessage.h>`. They're defined there
/// via the `iokit_common_msg` macro (`sys_iokit | sub_iokit_common | msg`,
/// with `sys_iokit == 0xe0000000`), which the Swift importer can't evaluate —
/// so the symbols aren't visible in Swift and we hardcode the resolved values.
private let kIOMessageCanSystemSleep: UInt32 = 0xe000_0270
private let kIOMessageSystemWillSleep: UInt32 = 0xe000_0280
private let kIOMessageSystemHasPoweredOn: UInt32 = 0xe000_0300

/// Fires `onWillSleep` immediately before the system sleeps and holds off the
/// power transition until the handler returns, so brief teardown work (here,
/// releasing the Magic peripherals this Mac is holding) lands before the
/// Bluetooth radio powers down.
///
/// Uses `IORegisterForSystemPower` rather than
/// `NSWorkspace.willSleepNotification` on purpose: only the IOKit path lets us
/// delay the acknowledgement until our work is done. The notification path
/// fires and the system proceeds to sleep regardless, which would race the
/// unpair against the radio power-down — exactly what we can't afford, since
/// the whole point is that a peer can't ask a sleeping Mac to release later.
final class SleepMonitor {
  /// Called on the main run loop just before sleep. The system is blocked
  /// until it returns (subject to the OS's ~30s power-handler watchdog), so
  /// keep it fast.
  var onWillSleep: (() -> Void)?

  /// Called on the main run loop after the system wakes. Not blocking — used
  /// to reclaim peripherals released for sleep that the peer didn't take.
  var onDidWake: (() -> Void)?

  private var rootPort: io_connect_t = 0
  private var notifierObject: io_object_t = 0
  private var notifyPortRef: IONotificationPortRef?

  func start() {
    guard rootPort == 0 else { return }
    let refCon = Unmanaged.passUnretained(self).toOpaque()
    rootPort = IORegisterForSystemPower(refCon, &notifyPortRef, Self.callback, &notifierObject)
    guard rootPort != 0, let notifyPortRef = notifyPortRef else {
      Log.bluetooth.error("SleepMonitor: IORegisterForSystemPower failed")
      return
    }
    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      IONotificationPortGetRunLoopSource(notifyPortRef).takeUnretainedValue(),
      .commonModes)
  }

  deinit {
    guard rootPort != 0 else { return }
    if let notifyPortRef = notifyPortRef {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(),
        IONotificationPortGetRunLoopSource(notifyPortRef).takeUnretainedValue(),
        .commonModes)
    }
    IODeregisterForSystemPower(&notifierObject)
    IOServiceClose(rootPort)
    if let notifyPortRef = notifyPortRef {
      IONotificationPortDestroy(notifyPortRef)
    }
  }

  /// The C callback can't capture context, so `self` is recovered from the
  /// `refCon` we registered with.
  private static let callback: IOServiceInterestCallback = {
    refCon, _, messageType, messageArgument in
    guard let refCon = refCon else { return }
    let monitor = Unmanaged<SleepMonitor>.fromOpaque(refCon).takeUnretainedValue()
    monitor.handle(messageType: messageType, argument: messageArgument)
  }

  private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
    switch messageType {
    case kIOMessageSystemWillSleep:
      // Do our teardown, *then* allow the transition. Holding the ack until
      // the handler returns is what keeps the release from racing the radio.
      onWillSleep?()
      IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case kIOMessageCanSystemSleep:
      // Idle-sleep query — never veto; we only care about the actual sleep.
      IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case kIOMessageSystemHasPoweredOn:
      // Informational — no acknowledgement required.
      onDidWake?()
    default:
      break
    }
  }
}
