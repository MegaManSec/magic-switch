import Foundation
import dnssd

/// Advisory discovery health, surfaced in the Macs tab. The failure it
/// exists for is otherwise silent: mDNSResponder accepts a registration but
/// never puts it on the wire (MDM's `NoMulticastAdvertisements`), so the
/// peer simply never sees this Mac. `NetServiceBrowser` hides interface
/// indexes, so the self-check browses via the dnssd C API: an own instance
/// seen only on the local-only pseudo-interface is not on the air.
final class AdvertisingDiagnostics: ObservableObject {
  static let shared = AdvertisingDiagnostics()

  /// Publish health ("your other Mac can't see this one") and search health
  /// ("this Mac can't see others") fail independently — separate slots so
  /// the self-check's verdict can't wipe a search advisory, or vice versa.
  @Published private(set) var publishWarning: String?
  @Published private(set) var searchWarning: String?

  private static let settleTime: TimeInterval = 10
  private let queue = DispatchQueue(label: "com.magicswitch.diagnostics")
  private var browseRef: DNSServiceRef?
  private var ownName: String?
  private var seenOnWire = false
  /// Ties each settle timer to its own browse, so a republish restarting the
  /// check can't have the previous timer report (and stop) the new one.
  private var checkGeneration = 0

  private init() {}

  func servicePublished(name: String) {
    queue.async { self.startSelfCheck(name: name) }
  }

  func servicePublishFailed() {
    // Kill any in-flight self-check: its settle timer would otherwise read
    // pre-failure browse results and clear the warning posted here.
    queue.async {
      self.checkGeneration += 1
      self.stopBrowse()
    }
    reportPublish(Self.notAdvertisingMessage())
  }

  func serviceSearchStarted() {
    reportSearch(nil)
  }

  func serviceSearchFailed() {
    reportSearch(
      "This Mac couldn't search the network for other Macs. Use Add by Address if your other Mac doesn't appear."
    )
  }

  private func startSelfCheck(name: String) {
    stopBrowse()
    // Invalidate the previous check's settle timer before any early return —
    // it would otherwise report on the state this restart just reset.
    checkGeneration += 1
    ownName = name
    seenOnWire = false
    var ref: DNSServiceRef?
    let context = Unmanaged.passUnretained(self).toOpaque()
    let err = DNSServiceBrowse(
      &ref, 0, 0, "_magicswitch._tcp", "local.",
      { _, _, interfaceIndex, errorCode, serviceName, _, _, context in
        guard errorCode == kDNSServiceErr_NoError,
          let context = context, let serviceName = serviceName
        else { return }
        Unmanaged<AdvertisingDiagnostics>.fromOpaque(context).takeUnretainedValue()
          .handleBrowseResult(name: String(cString: serviceName), interfaceIndex: interfaceIndex)
      }, context)
    guard err == kDNSServiceErr_NoError, let browse = ref else { return }
    DNSServiceSetDispatchQueue(browse, queue)
    browseRef = browse
    let generation = checkGeneration
    queue.asyncAfter(deadline: .now() + Self.settleTime) { [weak self] in
      self?.finishSelfCheck(generation: generation)
    }
  }

  private func handleBrowseResult(name: String, interfaceIndex: UInt32) {
    guard name == ownName else { return }
    if interfaceIndex != kDNSServiceInterfaceIndexLocalOnly {
      seenOnWire = true
    }
  }

  private func finishSelfCheck(generation: Int) {
    guard generation == checkGeneration else { return }
    stopBrowse()
    reportPublish(seenOnWire ? nil : Self.notAdvertisingMessage())
  }

  private func stopBrowse() {
    if let ref = browseRef {
      DNSServiceRefDeallocate(ref)
      browseRef = nil
    }
  }

  private func reportPublish(_ message: String?) {
    DispatchQueue.main.async { self.publishWarning = message }
  }

  private func reportSearch(_ message: String?) {
    DispatchQueue.main.async { self.searchWarning = message }
  }

  private static func notAdvertisingMessage() -> String {
    let cause =
      advertisingDisabledByPolicy()
      ? "Bonjour advertising is disabled by policy on this Mac (NoMulticastAdvertisements)"
      : "This Mac's Bonjour advertisements aren't reaching the network"
    return
      "\(cause), so your other Mac can't discover it by itself. An already-added Mac still reaches it automatically; otherwise use Add by Address on the other Mac."
  }

  /// Best-effort: the sandbox usually denies this read, and the generic
  /// wording stands.
  private static func advertisingDisabledByPolicy() -> Bool {
    let value = CFPreferencesCopyValue(
      "NoMulticastAdvertisements" as CFString,
      "com.apple.mDNSResponder" as CFString,
      kCFPreferencesAnyUser,
      kCFPreferencesAnyHost)
    return (value as? NSNumber)?.boolValue ?? false
  }
}
