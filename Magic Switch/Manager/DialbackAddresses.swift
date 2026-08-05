import Foundation
import Network

/// The addresses a peer can dial this Mac back at, for the UI spots where
/// the user must carry them to the other Mac (the Add by Address sheet and
/// the not-advertising advisory). Two tiers: the local address an
/// authenticated connection actually ran over (proven — the peer dialed it,
/// or will see it as our source), else the addresses of the viable
/// Wi-Fi/Ethernet interfaces. Which network the peer sits on is unknowable
/// at bootstrap, so candidates are listed with labels rather than guessed
/// down to one.
final class DialbackAddresses: ObservableObject {
  static let shared = DialbackAddresses()

  /// Local endpoint host of the most recent authenticated connection.
  /// Main-only (`noteProven` hops).
  @Published private(set) var provenHost: String?
  @Published private var currentPath: NWPath?

  private let monitor = NWPathMonitor()

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      DispatchQueue.main.async { self?.currentPath = path }
    }
    monitor.start(queue: DispatchQueue(label: "com.magicswitch.dialback"))
  }

  /// Record the local endpoint of a connection whose handshake completed.
  /// Loopback and link-local are refused: a self-dial's handshake succeeds
  /// against our own listener, and a link-local address is only routable
  /// with the *dialer's* zone id, which we can't know.
  func noteProven(endpoint: NWEndpoint?) {
    guard let host = Self.hostString(from: endpoint), Self.isDialable(host) else { return }
    DispatchQueue.main.async {
      if self.provenHost != host { self.provenHost = host }
    }
  }

  /// One line for UI captions — "192.168.1.23 (Wi-Fi)", possibly
  /// "… or 10.0.0.5 (Ethernet)". The proven address wins outright while it
  /// is still assigned to an interface; otherwise up to two labeled
  /// candidates in the system's own preference order. nil when nothing
  /// credible is known. Main-only.
  func displayList() -> String? {
    let addresses = Self.interfaceAddresses()
    let viable = currentPath?.availableInterfaces ?? []
    let labels = Dictionary(
      viable.compactMap { iface in Self.label(for: iface.type).map { (iface.name, $0) } },
      uniquingKeysWith: { first, _ in first })
    if let proven = provenHost,
      let owner = addresses.first(where: { $0.host == proven })?.interface
    {
      return Self.entry(proven, labels[owner])
    }
    // `availableInterfaces` repeats an interface (once per address family).
    var seenNames: Set<String> = []
    var entries = viable.compactMap { iface -> String? in
      guard seenNames.insert(iface.name).inserted,
        let label = labels[iface.name],
        let address = addresses.first(where: { $0.interface == iface.name && $0.isIPv4 })
          ?? addresses.first(where: { $0.interface == iface.name })
      else { return nil }
      return Self.entry(address.host, label)
    }
    if entries.isEmpty {
      entries = addresses.filter { $0.isIPv4 }.map { Self.entry($0.host, nil) }
    }
    guard !entries.isEmpty else { return nil }
    return entries.prefix(2).joined(separator: " or ")
  }

  /// Dialable host string of an endpoint — unlike `RateLimiter`'s bucketing
  /// it keeps IPv6 zone ids (a stripped link-local address isn't routable)
  /// but still collapses IPv4-mapped IPv6.
  static func hostString(from endpoint: NWEndpoint?) -> String? {
    guard case .hostPort(let host, _) = endpoint else { return nil }
    switch host {
    case .ipv4(let addr):
      return addr.debugDescription
    case .ipv6(let addr):
      let raw = addr.debugDescription
      if raw.lowercased().hasPrefix("::ffff:") {
        let v4 = String(raw.dropFirst("::ffff:".count))
        if v4.split(separator: ".").count == 4 { return v4 }
      }
      return raw
    case .name(let name, _):
      return name
    @unknown default:
      return nil
    }
  }

  private static func entry(_ host: String, _ label: String?) -> String {
    label.map { "\(host) (\($0))" } ?? host
  }

  private static func label(for type: NWInterface.InterfaceType) -> String? {
    switch type {
    case .wifi: return "Wi-Fi"
    case .wiredEthernet: return "Ethernet"
    default: return nil
    }
  }

  private static func isDialable(_ host: String) -> Bool {
    let lower = host.lowercased()
    return lower != "::1" && !lower.hasPrefix("127.") && !lower.hasPrefix("fe80:")
      && !lower.hasPrefix("169.254.")
  }

  /// Addresses of the up, non-loopback, non-point-to-point interfaces —
  /// the point-to-point flag is what keeps VPN tunnels out, whose
  /// addresses the peer usually can't reach.
  private static func interfaceAddresses() -> [(interface: String, host: String, isIPv4: Bool)] {
    var result: [(interface: String, host: String, isIPv4: Bool)] = []
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0 else { return result }
    defer { freeifaddrs(ifaddrPtr) }
    var cursor = ifaddrPtr
    while let current = cursor {
      defer { cursor = current.pointee.ifa_next }
      let flags = Int32(bitPattern: current.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
        let sa = current.pointee.ifa_addr
      else { continue }
      let family = sa.pointee.sa_family
      guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else { continue }
      var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let status = getnameinfo(
        sa, socklen_t(sa.pointee.sa_len),
        &hostBuffer, socklen_t(hostBuffer.count),
        nil, 0, NI_NUMERICHOST)
      guard status == 0 else { continue }
      let host = String(cString: hostBuffer)
      guard Self.isDialable(host) else { continue }
      result.append(
        (
          interface: String(cString: current.pointee.ifa_name),
          host: host,
          isIPv4: family == sa_family_t(AF_INET)
        ))
    }
    return result
  }
}
