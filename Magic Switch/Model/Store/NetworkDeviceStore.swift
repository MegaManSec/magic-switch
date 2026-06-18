import Foundation
import Network
import SwiftUI

/// Protocol defining the interface for network device management operations
protocol NetworkDeviceManageable {
  /// List of registered network devices
  var networkDevices: [NetworkDevice] { get }
  /// List of discovered network devices
  var discoveredNetworkDevices: [NetworkDevice] { get }
  /// List of available network devices that can be registered
  var availableNetworkDevices: [NetworkDevice] { get }

  /// Registers a new network device
  func registerNetworkDevice(device: NetworkDevice)
  /// Removes a registered network device
  func removeNetworkDevice(device: NetworkDevice)
  /// Updates the information of a network device
  func updateNetworkDevice(_ device: NetworkDevice)
}

/// A user-initiated Device-tab operation currently in flight to a peer.
/// Tracked in `NetworkDeviceStore` (not the view) so the row can disable its
/// buttons and keep rendering progress across Settings tab switches — the
/// view's local `@State` is reset when the tab is left and re-entered.
enum DeviceOperation {
  case ping
  case sync(count: Int)
}

/// Manages the state and operations of network devices
final class NetworkDeviceStore: ObservableObject, NetworkDeviceManageable {
  // MARK: - Singleton

  static let shared = NetworkDeviceStore()

  // MARK: - Dependencies

  private let servicePublisher = ServicePublisher()
  private let serviceBrowser = ServiceBrowser()

  // MARK: - Properties

  @Published private(set) var networkDevices: [NetworkDevice] = []
  @Published private(set) var discoveredNetworkDevices: [NetworkDevice] = []
  @AppStorage("networkDevices") private var networkDevicesData: Data = Data()

  /// Last active-probe result per device id (runtime only, never persisted).
  /// Combined signal: Bonjour resolve/withdraw write it on each transition, and
  /// a repeating `.ping` (plus an on-menu-open `.ping`) keep it honest between
  /// Bonjour events — so a peer that vanished without a Bonjour goodbye flips
  /// to false within one poll interval instead of waiting out the mDNS TTL.
  @Published private(set) var deviceReachability: [String: Bool] = [:]
  private var reachabilityTimer: DispatchSourceTimer?
  private static let reachabilityInterval: TimeInterval = 30

  /// Body-read timeout for the two commands whose receiver only acks after it
  /// has actually finished (re-)pairing — `CONNECT_ALL` and `CONNECT_ONE` —
  /// rather than acking on receipt. It must exceed the receiver's worst-case
  /// connect time (its pair watchdog, `pairTimeout`, is 60s) so the sender
  /// waits for the real result instead of giving up early; and the receiver's
  /// `IncomingConnection.idleTimeout` must stay >= this so it doesn't idle-kill
  /// the connection before sending that ack. Every other command acks
  /// immediately and uses `OutgoingConnection`'s 5s default.
  private static let handoffBodyTimeout: TimeInterval = 75

  /// Consecutive failed `.ping` polls per device id (runtime only). Drives
  /// the peer-vanished adoption trigger: one missed poll is routine (Wi-Fi
  /// blip, mid-transition), two in a row (~a minute) is a peer that's
  /// genuinely gone — asleep, shut down, off the network. Main-only.
  private var consecutivePollFailures: [String: Int] = [:]

  /// In-flight Ping/Sync per device id. Set when the user taps Ping/Sync on the
  /// Device tab and cleared when the op finishes; the view both disables the
  /// buttons and renders the "Pinging…/Syncing…" line off this, so they survive
  /// leaving and re-entering the tab (the view's own `@State` wouldn't).
  @Published private(set) var inFlightOperations: [String: DeviceOperation] = [:]

  // MARK: - Computed Properties

  var availableNetworkDevices: [NetworkDevice] {
    // "Self" is recognised by address, not by name. When two Macs share a
    // device name, mDNS renames one of the advertised services, so the old
    // name-based check (`discovered.name != Host.current().localizedName`)
    // made a Mac hide its real peer (same name) while listing itself
    // (renamed). The address we resolve for our own advertised service is
    // always one of this machine's interface addresses; a peer's never is.
    let localHosts = Self.localAddresses()
    return discoveredNetworkDevices.filter { discovered in
      let isNotSelf = !localHosts.contains(Self.normalizeHost(discovered.host))
      let isNotRegistered = !networkDevices.contains(where: { $0.id == discovered.id })
      return isNotSelf && isNotRegistered
    }
  }

  // MARK: - Initialization

  private init() {
    loadNetworkDevices()
    startServices()
    startReachabilityPolling()
  }

  deinit {
    stopServices()
    reachabilityTimer?.cancel()
  }

  // MARK: - Service Management

  private func startServices() {
    servicePublisher.startPublishing()
    serviceBrowser.startBrowsing()
  }

  private func stopServices() {
    servicePublisher.stopPublishing()
    serviceBrowser.stopBrowsing()
  }

  // MARK: - Public Methods

  func registerNetworkDevice(device: NetworkDevice) {
    // Don't drop from `discoveredNetworkDevices`; `availableNetworkDevices`
    // filters by `!networkDevices.contains` at read time. Dropping here
    // would mean `removeNetworkDevice` can't re-surface the Mac under
    // "Available Devices" until the next Bonjour resolution.
    networkDevices.append(device)
    saveNetworkDevices()
  }

  func removeNetworkDevice(device: NetworkDevice) {
    networkDevices.removeAll { $0.id == device.id }
    saveNetworkDevices()
  }

  func updateNetworkDevice(_ device: NetworkDevice) {
    if let index = networkDevices.firstIndex(where: { $0.id == device.id }) {
      let priorFingerprint = networkDevices[index].fingerprint
      networkDevices[index].update(with: device)
      saveNetworkDevices()
      // Fold the Bonjour signal into reachability: a fresh resolve is a good
      // indication the peer is up; a mismatch (isActive == false) keeps it
      // greyed. The `.ping` poll refines this between Bonjour events.
      deviceReachability[device.id] = networkDevices[index].isActive
      if let prior = priorFingerprint,
        let incoming = device.fingerprint,
        prior != incoming
      {
        NotificationManager.showNotification(
          title: "Identity Mismatch",
          body:
            "\(device.name) is advertising a new pairing key. Open Settings → Device and choose Trust if you re-paired the other Mac yourself.",
          identifier: "identity-mismatch-\(device.id)"
        )
      }
    }
  }

  /// Promote `pendingFingerprint` to the stored pin and re-mark the device
  /// active. Invoked from the UI when the user explicitly trusts a new key
  /// after an Identity Mismatch (e.g., they re-paired the other Mac).
  func trustPendingFingerprint(for deviceID: String) {
    guard let index = networkDevices.firstIndex(where: { $0.id == deviceID }),
      let pending = networkDevices[index].pendingFingerprint
    else { return }
    networkDevices[index].fingerprint = pending
    networkDevices[index].pendingFingerprint = nil
    networkDevices[index].isActive = true
    networkDevices[index].lastUpdated = Date()
    // Trust is a positive presence signal — the peer is on the network, which
    // is how we saw the new key — so clear the stale `false` reachability the
    // mismatch left behind rather than make the user wait for the next poll to
    // un-grey the menu row.
    deviceReachability[deviceID] = true
    saveNetworkDevices()
  }

  /// Tear down and re-start Bonjour browsing. Used by the "Refresh" button
  /// when the discovered list goes stale (network change, sleep/wake).
  func refreshDiscovery() {
    discoveredNetworkDevices = []
    serviceBrowser.refresh()
  }

  /// Adds a newly discovered network device
  func addDiscoveredNetworkDevice(_ device: NetworkDevice) {
    if let index = discoveredNetworkDevices.firstIndex(where: { $0.id == device.id }) {
      discoveredNetworkDevices[index].update(with: device)
    } else {
      discoveredNetworkDevices.append(device)
    }
  }

  /// Removes a discovered network device by name
  func removeDiscoveredNetworkDevice(named name: String) {
    discoveredNetworkDevices.removeAll { $0.name == name }
  }

  /// Updates the active state of a device
  func updateDeviceIsActive(id: String, isActive: Bool) {
    if let index = networkDevices.firstIndex(where: { $0.id == id }) {
      networkDevices[index].isActive = isActive
      saveNetworkDevices()
    }
    if let index = discoveredNetworkDevices.firstIndex(where: { $0.id == id }) {
      discoveredNetworkDevices[index].isActive = isActive
    }
    // Mirror Bonjour's verdict into reachability (a withdraw is a valid, if
    // slow, offline signal); the `.ping` poll provides the fast path.
    deviceReachability[id] = isActive
  }

  // MARK: - Reachability

  /// Pessimistic default: until a Bonjour resolve or a `.ping` has actually
  /// confirmed the peer, treat it as unreachable. The probe is async, so it
  /// can't gate the first (synchronous) menu build — an optimistic default
  /// would show an offline peer's row enabled on a cold start until the first
  /// probe lands. An online peer un-greys within ~1s: a Bonjour resolve writes
  /// `true`, and the first poll confirms it.
  func isReachable(_ id: String) -> Bool { deviceReachability[id] ?? false }

  /// A device is switchable when it's reachable *and* not parked behind a
  /// pending TOFU identity mismatch (which the user must Trust first). Drives
  /// the menu's Mac-row enablement and tooltip.
  func isSwitchable(_ device: NetworkDevice) -> Bool {
    device.pendingFingerprint == nil && isReachable(device.id)
  }

  /// Repeating background probe — runs every `reachabilityInterval` for the
  /// life of the app, independent of whether the menu is ever opened.
  private func startReachabilityPolling() {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    // First fire soon after launch so an online peer is confirmed quickly
    // (it starts greyed under the pessimistic default); then settle into the
    // steady interval.
    timer.schedule(
      deadline: .now() + 1, repeating: Self.reachabilityInterval, leeway: .seconds(5))
    timer.setEventHandler { [weak self] in self?.pollReachability() }
    timer.resume()
    reachabilityTimer = timer
  }

  /// Kick an immediate probe — called when the menu opens so the *next* render
  /// is fresh (the probe is async and can't update an already-built menu). The
  /// background timer keeps running on its own cadence regardless.
  func refreshReachability() { pollReachability() }

  private func pollReachability() {
    // `.ping` rides the secure channel, so it's meaningless unpaired — skip
    // (leaving the pessimistic default) rather than spam `.notPaired` failures.
    // Skip mismatched peers too: a `.ping` with our old key would just auth-fail
    // and feed the peer's inbound rate limiter. `countsTowardRateLimit: false`
    // keeps these fixed-cadence probes from tripping our own outbound limiter.
    guard PairingStore.shared.isPaired else { return }
    for device in networkDevices where device.pendingFingerprint == nil {
      executeCommand(.ping, on: device, countsTowardRateLimit: false) { [weak self] result in
        DispatchQueue.main.async {
          guard let self = self else { return }
          let reachable: Bool
          if case .success = result { reachable = true } else { reachable = false }
          // Publish only on change — a steady-state poll would otherwise fire
          // objectWillChange every interval and needlessly re-render observers.
          if self.deviceReachability[device.id] != reachable {
            self.deviceReachability[device.id] = reachable
          }
          if reachable {
            self.consecutivePollFailures[device.id] = 0
          } else {
            let failures = (self.consecutivePollFailures[device.id] ?? 0) + 1
            self.consecutivePollFailures[device.id] = failures
            // Second consecutive miss: the peer has genuinely gone away, and
            // whatever it was holding is stranded — let the adoption watcher
            // pick it up. Exactly-two (not ≥) fires once per outage, so a
            // long-dark peer doesn't re-arm the watcher every poll forever;
            // a recovery resets the streak and re-arms it for the next one.
            if failures == 2 {
              BluetoothPeripheralStore.shared.armAdoptionOfUnheldPeripherals()
            }
          }
        }
      }
    }
  }

  func sendNotification(
    to device: NetworkDevice,
    completion: ((Result<Void, OutgoingFailure>) -> Void)? = nil
  ) {
    guard PairingStore.shared.isPaired else {
      completion?(.failure(.notPaired))
      return
    }

    beginOperation(.ping, for: device.id)
    let senderName = Host.current().localizedName ?? "another Mac"
    // Put the sender's name in the title so the receiver's Notification
    // Center entry is informative at a glance.
    let title = "Notification from \(senderName)"
    let body = "Sent via Magic Switch."
    sendNotificationOverSecure(to: device, title: title, message: body) { [weak self] result in
      DispatchQueue.main.async {
        self?.endOperation(for: device.id)
        completion?(result)
      }
    }
  }

  // MARK: - In-Flight Operation Tracking

  /// Marks a Device-tab operation as running for `deviceID`. Main-thread only.
  private func beginOperation(_ op: DeviceOperation, for deviceID: String) {
    inFlightOperations[deviceID] = op
  }

  /// Clears the in-flight marker for `deviceID`. Main-thread only.
  private func endOperation(for deviceID: String) {
    inFlightOperations.removeValue(forKey: deviceID)
  }

  // MARK: - Private Methods

  /// This Mac's active IPv4/IPv6 interface addresses, used by
  /// `availableNetworkDevices` to recognise its own advertised service in
  /// discovery results (robust to an mDNS rename of a duplicate device name).
  /// Recomputed each call — `getifaddrs` is cheap and interface addresses
  /// change (Wi-Fi reconnect, VPN, sleep/wake).
  private static func localAddresses() -> Set<String> {
    var result: Set<String> = []
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0 else { return result }
    defer { freeifaddrs(ifaddrPtr) }
    var cursor = ifaddrPtr
    while let current = cursor {
      defer { cursor = current.pointee.ifa_next }
      guard let sa = current.pointee.ifa_addr else { continue }
      let family = sa.pointee.sa_family
      guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else { continue }
      var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let status = getnameinfo(
        sa, socklen_t(sa.pointee.sa_len),
        &hostBuffer, socklen_t(hostBuffer.count),
        nil, 0, NI_NUMERICHOST)
      guard status == 0 else { continue }
      result.insert(Self.normalizeHost(String(cString: hostBuffer)))
    }
    return result
  }

  /// Drop an IPv6 zone id (`fe80::1%en0` → `fe80::1`) so addresses compare
  /// equal regardless of how the scope is formatted on each side.
  private static func normalizeHost(_ host: String) -> String {
    guard let pct = host.firstIndex(of: "%") else { return host }
    return String(host[..<pct])
  }

  private func saveNetworkDevices() {
    do {
      let encoded = try JSONEncoder().encode(networkDevices)
      networkDevicesData = encoded
    } catch {
      print("Failed to save devices: \(error)")
    }
  }

  private func loadNetworkDevices() {
    do {
      networkDevices = try JSONDecoder().decode([NetworkDevice].self, from: networkDevicesData)
    } catch {
      print("Failed to load devices: \(error)")
    }
  }

}

/// Represents different types of device commands
enum DeviceCommand: String, Codable {
  case unregisterAll = "UNREGISTER_ALL"
  case connectAll = "CONNECT_ALL"
  case operationSuccess = "OP_SUCCESS"
  case operationFailed = "OP_FAILED"
  case notification = "NOTIFICATION"
  case syncPeripherals = "SYNC_PERIPHERALS"
  /// Two-frame: opcode then a single peripheral's MAC address. The peer
  /// releases just that peripheral (used by per-peripheral switch flows).
  case unregisterOne = "UNREGISTER_ONE"
  /// Two-frame: opcode then a single peripheral's MAC address. The peer
  /// connects just that peripheral.
  case connectOne = "CONNECT_ONE"
  /// Two-frame: opcode then a single peripheral's MAC address. The peer acks
  /// `OP_SUCCESS` if it currently holds (has a live Bluetooth connection to)
  /// that peripheral, `OP_FAILED` otherwise. Read-only — used by the
  /// wake-time reclaim to avoid grabbing a peripheral the peer is actively
  /// using.
  case holdsOne = "HOLDS_ONE"
  /// Single-frame no-op the peer immediately acks. Used as a secure-channel
  /// preflight: a TCP-open `checkHealth` doesn't prove the peer's app will
  /// accept commands, but a PING that handshakes + receives OP_SUCCESS
  /// does. Lets the switch action bail out before touching local Bluetooth
  /// state if the peer can't actually take a command right now.
  case ping = "PING"
}

// MARK: - Health Check Extension

extension NetworkDeviceStore {
  /// Performs a health check on the specified device
  func performHealthCheck(
    for device: NetworkDevice, completion: @escaping (HealthCheckResult) -> Void
  ) {
    device.checkHealth { result in
      DispatchQueue.main.async {
        switch result {
        case .success:
          print("Health check successful with \(device.name)")
          completion(result)
        case .failure(let error):
          print("Health check failed with \(device.name): \(error)")
          completion(result)
        case .timeout:
          print("Health check timed out with \(device.name)")
          completion(result)
        }
      }
    }
  }

  /// Executes a command on `device` through a secure channel. The caller
  /// must pick the target device — keeping this explicit matches the per-
  /// peripheral senders (`executeUnregisterOne` / `executeConnectOne`) and
  /// avoids burying the single-device assumption inside this function.
  func executeCommand(
    _ command: DeviceCommand,
    on device: NetworkDevice,
    countsTowardRateLimit: Bool = true,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    guard PairingStore.shared.isPaired else {
      completion(.failure(.notPaired))
      return
    }

    let bodyTimeout: TimeInterval = command == .connectAll ? Self.handoffBodyTimeout : 5
    let outgoing = OutgoingConnection(
      host: device.host,
      port: UInt16(device.port),
      countsTowardRateLimit: countsTowardRateLimit,
      bodyTimeout: bodyTimeout
    )
    outgoing.run(
      body: { channel, done in
        channel.send(Data(command.rawValue.utf8)) { sendErr in
          if let sendErr = sendErr {
            print("Failed to send command: \(sendErr)")
            done(false)
            return
          }
          channel.receive { result in
            switch result {
            case .failure(let err):
              print("Failed to receive response: \(err)")
              done(false)
            case .success(let data):
              let response = String(data: data, encoding: .utf8) ?? ""
              if let resp = DeviceCommand(rawValue: response) {
                done(resp == .operationSuccess)
              } else {
                done(false)
              }
            }
          }
        }
      },
      completion: completion
    )
  }

  /// Sends a notification through a secure channel.
  func sendNotificationOverSecure(
    to device: NetworkDevice,
    title: String,
    message: String,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    guard PairingStore.shared.isPaired else {
      completion(.failure(.notPaired))
      return
    }

    let outgoing = OutgoingConnection(host: device.host, port: UInt16(device.port))
    outgoing.run(
      body: { channel, done in
        channel.send(Data(DeviceCommand.notification.rawValue.utf8)) { err in
          if let err = err {
            print("Notification command send failed: \(err)")
            done(false)
            return
          }
          let payload = "\(title)|\(message)"
          channel.send(Data(payload.utf8)) { err2 in
            if let err2 = err2 {
              print("Notification payload send failed: \(err2)")
              done(false)
              return
            }
            // Wait for the receiver's OP_SUCCESS/OP_FAILED before tearing
            // down. `NWConnection.send(.contentProcessed)` only confirms
            // local buffering, and the subsequent cancel() can drop frames
            // still in flight — without an ack, the peer often never sees
            // the payload.
            channel.receive { result in
              switch result {
              case .failure(let err):
                print("Notification ack receive failed: \(err)")
                done(false)
              case .success(let data):
                let response = String(data: data, encoding: .utf8) ?? ""
                done(DeviceCommand(rawValue: response) == .operationSuccess)
              }
            }
          }
        }
      },
      completion: completion
    )
  }
}

extension NetworkDeviceStore {
  /// Push this Mac's registered peripheral list to `device`. Completion
  /// receives the categorised outgoing result so the caller can render
  /// inline UI feedback (the Device tab does this under each row). The
  /// store no longer surfaces its own notifications for sync — callers
  /// decide how to report success/failure.
  func sendPeripheralSync(
    peripherals: [BluetoothPeripheral],
    to device: NetworkDevice,
    completion: ((Result<Void, OutgoingFailure>) -> Void)? = nil
  ) {
    guard PairingStore.shared.isPaired else {
      completion?(.failure(.notPaired))
      return
    }

    guard let data = try? JSONEncoder().encode(peripherals),
      let jsonString = String(data: data, encoding: .utf8)
    else {
      print("sendPeripheralSync: failed to encode peripherals")
      completion?(.failure(.connectionFailed("encode failed")))
      return
    }

    beginOperation(.sync(count: peripherals.count), for: device.id)
    let outgoing = OutgoingConnection(host: device.host, port: UInt16(device.port))
    outgoing.run(
      body: { channel, done in
        channel.send(Data(DeviceCommand.syncPeripherals.rawValue.utf8)) { err in
          if let err = err {
            print("syncPeripherals command send failed: \(err)")
            done(false)
            return
          }
          channel.send(Data(jsonString.utf8)) { err2 in
            if let err2 = err2 {
              print("syncPeripherals payload send failed: \(err2)")
              done(false)
              return
            }
            // Same rationale as the notification path: wait for the
            // receiver's OP_SUCCESS so we don't cancel() before the peer
            // actually processes the payload.
            channel.receive { result in
              switch result {
              case .failure(let err):
                print("syncPeripherals ack receive failed: \(err)")
                done(false)
              case .success(let data):
                let response = String(data: data, encoding: .utf8) ?? ""
                done(DeviceCommand(rawValue: response) == .operationSuccess)
              }
            }
          }
        }
      },
      completion: { [weak self] result in
        DispatchQueue.main.async {
          self?.endOperation(for: device.id)
          completion?(result)
        }
      }
    )
  }

  // MARK: - Per-Peripheral Switch Opcodes

  /// Asks `device` to release the peripheral with the given MAC address.
  /// Two-frame protocol: opcode + MAC, then OP_SUCCESS/OP_FAILED.
  func executeUnregisterOne(
    address: String,
    on device: NetworkDevice,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    sendTwoFrameCommand(.unregisterOne, payload: address, to: device, completion: completion)
  }

  /// Asks `device` to take ownership of the peripheral with the given MAC
  /// address. Two-frame protocol mirroring `executeUnregisterOne`.
  func executeConnectOne(
    address: String,
    on device: NetworkDevice,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    sendTwoFrameCommand(.connectOne, payload: address, to: device, completion: completion)
  }

  /// Asks `device` whether it currently holds the peripheral with the given
  /// MAC. `.success` means the peer holds it (so leave it alone); any
  /// `.failure` — an explicit "no" or an unreachable peer — means it's free
  /// for us to reclaim. Two-frame protocol mirroring `executeUnregisterOne`.
  func executeHoldsOne(
    address: String,
    on device: NetworkDevice,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    // `HOLDS_ONE` is only ever a background watcher/reclaim probe, never a user
    // action — opt out of the outbound limiter so its fixed cadence can't trip
    // the limiter that gates real switches (mirrors the reachability poll).
    sendTwoFrameCommand(
      .holdsOne, payload: address, to: device, countsTowardRateLimit: false,
      completion: completion)
  }

  /// Shared helper for "opcode + single payload frame, await OP_SUCCESS".
  /// Kept private to this extension; the older two-frame call sites
  /// (`sendNotificationOverSecure`, `sendPeripheralSync`) still have their
  /// own inline copies because their failure surfaces differ.
  private func sendTwoFrameCommand(
    _ command: DeviceCommand,
    payload: String,
    to device: NetworkDevice,
    countsTowardRateLimit: Bool = true,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    guard PairingStore.shared.isPaired else {
      completion(.failure(.notPaired))
      return
    }
    let bodyTimeout: TimeInterval = command == .connectOne ? Self.handoffBodyTimeout : 5
    let outgoing = OutgoingConnection(
      host: device.host, port: UInt16(device.port),
      countsTowardRateLimit: countsTowardRateLimit,
      bodyTimeout: bodyTimeout)
    outgoing.run(
      body: { channel, done in
        channel.send(Data(command.rawValue.utf8)) { err in
          if let err = err {
            print("\(command.rawValue) command send failed: \(err)")
            done(false)
            return
          }
          channel.send(Data(payload.utf8)) { err2 in
            if let err2 = err2 {
              print("\(command.rawValue) payload send failed: \(err2)")
              done(false)
              return
            }
            channel.receive { result in
              switch result {
              case .failure(let err):
                print("\(command.rawValue) ack receive failed: \(err)")
                done(false)
              case .success(let data):
                let response = String(data: data, encoding: .utf8) ?? ""
                done(DeviceCommand(rawValue: response) == .operationSuccess)
              }
            }
          }
        }
      },
      completion: completion
    )
  }
}
