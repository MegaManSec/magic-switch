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

  // MARK: - Computed Properties

  var availableNetworkDevices: [NetworkDevice] {
    discoveredNetworkDevices.filter { discovered in
      // Exclude own device from the list
      let isNotSelf = discovered.name != Host.current().localizedName
      let isNotRegistered = !networkDevices.contains(where: { $0.id == discovered.id })
      return isNotSelf && isNotRegistered
    }
  }

  // MARK: - Initialization

  private init() {
    loadNetworkDevices()
    startServices()
  }

  deinit {
    stopServices()
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
    networkDevices.append(device)
    removeFromDiscoveredDevices(device)
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
  }

  func sendNotification(to device: NetworkDevice) {
    guard PairingStore.shared.isPaired else {
      NotificationManager.showNotification(
        title: "Not Paired",
        body: "Pair this Mac first to send notifications to \(device.name).",
        identifier: "notify-not-paired-\(device.id)"
      )
      return
    }

    let senderName = Host.current().localizedName ?? "another Mac"
    // Put the sender's name in the title so the receiver's Notification
    // Center entry is informative at a glance (previously the title was the
    // generic "New Notification" and the sender's name was buried in the body).
    let title = "Notification from \(senderName)"
    let body = "Sent via Blue Switch."
    sendNotificationOverSecure(to: device, title: title, message: body) { result in
      switch result {
      case .success:
        NotificationManager.showNotification(
          title: "Notification Sent",
          body: "Notification sent to \(device.name)",
          identifier: "notify-sent-\(device.id)"
        )
      case .failure(let err):
        NotificationManager.showNotification(
          title: "Couldn't Notify \(device.name)",
          body: err.userMessage,
          identifier: "notify-failed-\(device.id)"
        )
      }
    }
  }

  // MARK: - Private Methods

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

  private func removeFromDiscoveredDevices(_ device: NetworkDevice) {
    discoveredNetworkDevices.removeAll { $0.id == device.id }
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

  /// Executes a command on the first connected device through a secure channel.
  func executeCommand(
    _ command: DeviceCommand,
    completion: @escaping (Result<Void, OutgoingFailure>) -> Void
  ) {
    guard let device = networkDevices.first else {
      print("No connected devices found")
      completion(.failure(.connectionFailed("no registered device")))
      return
    }

    guard PairingStore.shared.isPaired else {
      completion(.failure(.notPaired))
      return
    }

    let outgoing = OutgoingConnection(host: device.host, port: UInt16(device.port))
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
            } else {
              done(true)
            }
          }
        }
      },
      completion: completion
    )
  }
}

extension NetworkDeviceStore {
  func sendPeripheralSync(peripherals: [BluetoothPeripheral], to device: NetworkDevice) {
    guard PairingStore.shared.isPaired else {
      NotificationManager.showNotification(
        title: "Not Paired",
        body: "Pair this Mac first to sync the peripheral list to \(device.name).",
        identifier: "sync-not-paired-\(device.id)"
      )
      return
    }

    guard let data = try? JSONEncoder().encode(peripherals),
      let jsonString = String(data: data, encoding: .utf8)
    else {
      print("sendPeripheralSync: failed to encode peripherals")
      return
    }

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
            } else {
              done(true)
            }
          }
        }
      },
      completion: { result in
        // Sync is a routine background-ish operation, so we stay quiet on
        // success and only surface failures.
        if case .failure(let err) = result {
          NotificationManager.showNotification(
            title: "Couldn't Sync \(device.name)",
            body: err.userMessage,
            identifier: "sync-failed-\(device.id)"
          )
        }
      }
    )
  }
}
