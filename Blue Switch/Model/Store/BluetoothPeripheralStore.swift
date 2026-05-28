import Foundation
import IOBluetooth
import SwiftUI

/// Protocol defining the interface for Bluetooth peripheral management operations
protocol BluetoothPeripheralManageable {
  /// Fetches and updates the list of connected peripherals
  func fetchConnectedPeripherals()

  /// Adds a new peripheral to the managed list
  func addPeripheral(_ peripheral: BluetoothPeripheral)

  /// Initiates connection to a peripheral
  func connectPeripheral(_ peripheral: BluetoothPeripheral)

  /// Disconnects from a peripheral
  func disconnectPeripheral(_ peripheral: BluetoothPeripheral)
}

/// Manages the state and operations of Bluetooth peripherals
final class BluetoothPeripheralStore: NSObject, ObservableObject, BluetoothPeripheralManageable {
  // MARK: - Singleton

  static let shared = BluetoothPeripheralStore()

  // MARK: - Constants

  private enum Constants {
    static let queueLabel = "com.blueswitch.bluetooth"
    static let invalidRSSI = 127
  }

  // MARK: - Dependencies

  private let bluetoothQueue = DispatchQueue(label: Constants.queueLabel, qos: .userInitiated)

  // MARK: - Properties

  @AppStorage("peripherals") private var peripheralsData: Data = Data()

  @Published private(set) var peripherals: [BluetoothPeripheral] = [] {
    didSet {
      savePeripherals()
    }
  }

  @Published private(set) var discoveredPeripherals: [BluetoothPeripheral] = []

  /// Runtime connection state per peripheral id. Driven by pair completion and
  /// IOBluetooth disconnect notifications.
  @Published private(set) var connectionStates: [String: PeripheralConnectionState] = [:]

  /// In-flight `IOBluetoothDevicePair` instances, kept alive until
  /// `devicePairingFinished` fires. Without this, ARC frees the pair mid-op and
  /// macOS aborts pairing, dropping the peripheral seconds after it connects.
  private var pendingPairs: [String: IOBluetoothDevicePair] = [:]

  /// Disconnect notification observers, keyed by peripheral id.
  private var disconnectObservers: [String: IOBluetoothUserNotification] = [:]

  // MARK: - Computed Properties

  var availablePeripherals: [BluetoothPeripheral] {
    discoveredPeripherals.filter { discovered in
      !peripherals.contains(where: { $0.id == discovered.id })
    }
  }

  func connectionState(for peripheralID: String) -> PeripheralConnectionState {
    connectionStates[peripheralID] ?? .disconnected
  }

  // MARK: - Initialization

  private override init() {
    super.init()
    loadPeripherals()
    fetchConnectedPeripherals()
  }

  // MARK: - Public Methods

  /// Adds a peripheral to the managed list in connected state
  /// - Parameter peripheral: The peripheral to add
  func addPeripheral(_ peripheral: BluetoothPeripheral) {
    guard validateBluetoothState() else { return }
    guard validateDeviceExists(peripheral) else { return }

    var newPeripheral = peripheral
    peripherals.append(newPeripheral)
  }

  /// Removes peripheral information from the system while maintaining it in the list
  /// - Parameter peripheral: The peripheral to unregister
  func unregisterFromPC(_ peripheral: BluetoothPeripheral) {
    guard validateBluetoothState() else { return }
    guard let btDevice = getBluetoothDevice(for: peripheral) else { return }

    if !btDevice.isConnected() {
      print("Device is already disconnected: \(peripheral.name)")
      setConnectionState(.disconnected, for: peripheral.id)
      return
    }

    if btDevice.responds(to: Selector(("remove"))) {
      btDevice.perform(Selector(("remove")))
      print("Device information removed: \(peripheral.name)")
      setConnectionState(.disconnected, for: peripheral.id)
    } else {
      print("Failed to remove device information: \(peripheral.name)")
    }
  }

  /// Completely remove device from list
  func removeFromList(_ peripheral: BluetoothPeripheral) {
    guard peripherals.contains(where: { $0.id == peripheral.id }) else {
      print("\(peripheral.name) does not exist in the list")
      return
    }
    peripherals.removeAll { $0.id == peripheral.id }
    print("\(peripheral.name) has been removed from the list")
  }

  func connectPeripheral(_ peripheral: BluetoothPeripheral) {
    setConnectionState(.connecting, for: peripheral.id)

    bluetoothQueue.async { [weak self] in
      guard let self = self else { return }

      guard let btDevice = IOBluetoothDevice(addressString: peripheral.id) else {
        print("\(peripheral.name) not found")
        self.setConnectionState(.disconnected, for: peripheral.id)
        return
      }

      guard IOBluetoothHostController.default().powerState != kBluetoothHCIPowerStateOFF else {
        print("Bluetooth is turned off")
        self.setConnectionState(.disconnected, for: peripheral.id)
        return
      }

      if btDevice.rssi() == Constants.invalidRSSI {
        print("\(peripheral.name) is out of range or not responding")
        self.setConnectionState(.disconnected, for: peripheral.id)
        return
      }

      guard let devicePair = IOBluetoothDevicePair(device: btDevice) else {
        print("Failed to initialize pairing for \(peripheral.name)")
        self.setConnectionState(.disconnected, for: peripheral.id)
        return
      }

      devicePair.delegate = self
      DispatchQueue.main.async {
        self.pendingPairs[peripheral.id]?.stop()
        self.pendingPairs[peripheral.id] = devicePair
      }

      let pairResult = devicePair.start()
      if pairResult != kIOReturnSuccess {
        print("Failed to start pairing with \(peripheral.name). Error code: \(pairResult)")
        DispatchQueue.main.async {
          self.pendingPairs.removeValue(forKey: peripheral.id)
        }
        self.setConnectionState(.disconnected, for: peripheral.id)
      }
      // Success path continues in `devicePairingFinished(_:error:)`.
    }
  }

  /// Disconnect device
  func disconnectPeripheral(_ peripheral: BluetoothPeripheral) {
    guard IOBluetoothHostController.default().powerState != kBluetoothHCIPowerStateOFF else {
      print("Bluetooth is turned off")
      return
    }

    guard let btDevice = IOBluetoothDevice(addressString: peripheral.id) else {
      print("\(peripheral.name) not found")
      return
    }

    if !btDevice.isConnected() {
      print("\(peripheral.name) is already disconnected")
      setConnectionState(.disconnected, for: peripheral.id)
      return
    }

    let result = btDevice.closeConnection()
    if result == kIOReturnSuccess {
      print("Disconnected from \(peripheral.name)")
      setConnectionState(.disconnected, for: peripheral.id)
    } else {
      print("Failed to disconnect from \(peripheral.name). Error code: \(result)")
    }
  }

  func fetchConnectedPeripherals() {
    let runSnapshot: ([String]) -> Void = { [weak self] registeredIDs in
      guard let self = self else { return }
      self.bluetoothQueue.async {
        guard IOBluetoothHostController.default().powerState != kBluetoothHCIPowerStateOFF else {
          print("Bluetooth is turned off")
          return
        }

        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
          print("No paired peripherals found")
          return
        }

        let registeredSet = Set(registeredIDs)
        var available: [BluetoothPeripheral] = []
        var connectedAddresses: Set<String> = []

        for device in pairedDevices {
          guard let address = device.addressString else { continue }
          if device.isConnected() {
            connectedAddresses.insert(address)
          }
          if !registeredSet.contains(address) {
            available.append(
              BluetoothPeripheral(id: address, name: device.name ?? "Unknown Device")
            )
          }
        }

        DispatchQueue.main.async {
          self.discoveredPeripherals = available
          for id in registeredIDs {
            let isConnected = connectedAddresses.contains(id)
            // Don't overwrite an in-flight .connecting state with a stale read.
            if self.connectionStates[id] == .connecting { continue }
            self.connectionStates[id] = isConnected ? .connected : .disconnected
            if isConnected, self.disconnectObservers[id] == nil,
              let device = IOBluetoothDevice(addressString: id)
            {
              self.registerForDisconnect(device: device, address: id)
            }
          }
        }
      }
    }

    if Thread.isMainThread {
      runSnapshot(peripherals.map { $0.id })
    } else {
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        runSnapshot(self.peripherals.map { $0.id })
      }
    }
  }

  /// Updates the peripheral list with new data from sync
  /// - Parameter newPeripherals: Array of peripherals to update with
  func updatePeripherals(_ newPeripherals: [BluetoothPeripheral]) {
    // Cap inbound list size; reject larger payloads outright.
    guard newPeripherals.count <= 64 else {
      print("Rejecting peripheral sync: list exceeds cap of 64")
      return
    }

    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.updatePeripherals(newPeripherals)
      }
      return
    }

    peripherals = newPeripherals
  }

  // MARK: - Pair Delegate & Connection Tracking

  /// `IOBluetoothDevicePairDelegate` callback. Open the actual connection here
  /// once pairing has actually completed (the pre-rewrite code called
  /// `openConnection()` synchronously after `start()` and lost the device).
  @objc func devicePairingFinished(_ sender: Any!, error: IOReturn) {
    guard let pair = sender as? IOBluetoothDevicePair,
      let device = pair.device(),
      let address = device.addressString
    else {
      return
    }

    DispatchQueue.main.async {
      self.pendingPairs.removeValue(forKey: address)
    }

    guard error == kIOReturnSuccess else {
      print("Pairing failed for \(address): \(error)")
      setConnectionState(.disconnected, for: address)
      return
    }

    bluetoothQueue.async { [weak self] in
      guard let self = self else { return }
      if !device.isConnected() {
        let result = device.openConnection()
        if result != kIOReturnSuccess {
          print("openConnection failed after pair: \(result)")
        }
      }
      if device.isConnected() {
        self.setConnectionState(.connected, for: address)
        self.registerForDisconnect(device: device, address: address)
      } else {
        self.setConnectionState(.disconnected, for: address)
      }
    }
  }

  /// Selector target for `IOBluetoothDevice.register(forDisconnectNotification:...)`.
  /// Signature must be `(IOBluetoothUserNotification, IOBluetoothDevice)`.
  @objc private func handlePeripheralDisconnected(
    _ notification: IOBluetoothUserNotification,
    fromDevice device: IOBluetoothDevice
  ) {
    notification.unregister()
    let address = device.addressString ?? ""
    DispatchQueue.main.async {
      self.disconnectObservers.removeValue(forKey: address)
      // Don't clobber a fresh .connecting attempt from a pre-empt path.
      if self.connectionStates[address] != .connecting {
        self.connectionStates[address] = .disconnected
      }
    }
  }

  private func registerForDisconnect(device: IOBluetoothDevice, address: String) {
    guard
      let observer = device.register(
        forDisconnectNotification: self,
        selector: #selector(handlePeripheralDisconnected(_:fromDevice:))
      )
    else {
      return
    }
    DispatchQueue.main.async {
      self.disconnectObservers[address]?.unregister()
      self.disconnectObservers[address] = observer
    }
  }

  private func setConnectionState(_ state: PeripheralConnectionState, for id: String) {
    if Thread.isMainThread {
      connectionStates[id] = state
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.connectionStates[id] = state
      }
    }
  }

  // MARK: - Private Methods

  private func savePeripherals() {
    do {
      let encoded = try JSONEncoder().encode(peripherals)
      peripheralsData = encoded
    } catch {
      print("Failed to save peripherals: \(error)")
    }
  }

  private func loadPeripherals() {
    do {
      peripherals = try JSONDecoder().decode([BluetoothPeripheral].self, from: peripheralsData)
    } catch {
      print("Failed to load peripherals: \(error)")
    }
  }

  // MARK: - Helper Methods

  private func validateBluetoothState() -> Bool {
    let powerState = IOBluetoothHostController.default().powerState
    guard powerState != kBluetoothHCIPowerStateOFF else {
      print("Bluetooth is turned off")
      return false
    }
    return true
  }

  private func validateDeviceExists(_ peripheral: BluetoothPeripheral) -> Bool {
    guard IOBluetoothDevice(addressString: peripheral.id) != nil else {
      print("Device not found: \(peripheral.name)")
      return false
    }
    return true
  }

  private func getBluetoothDevice(for peripheral: BluetoothPeripheral) -> IOBluetoothDevice? {
    guard let device = IOBluetoothDevice(addressString: peripheral.id) else {
      print("Device not found: \(peripheral.name)")
      return nil
    }
    return device
  }
}

extension BluetoothPeripheralStore {
  /// Aggregate connection state across all registered peripherals.
  enum ConnectionStatus {
    case allConnected
    case allDisconnected
    case partial
  }

  /// Queries the live IOBluetooth state on `bluetoothQueue` and returns on
  /// main. Snapshots `peripherals` on main before hopping so we never read
  /// the `@Published` array from a background thread.
  func checkActualConnectionStatusAsync(completion: @escaping (ConnectionStatus) -> Void) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.checkActualConnectionStatusAsync(completion: completion)
      }
      return
    }

    let snapshot = peripherals
    bluetoothQueue.async {
      var connectedCount = 0
      var totalCount = 0
      for peripheral in snapshot {
        if let device = IOBluetoothDevice(addressString: peripheral.id) {
          totalCount += 1
          if device.isConnected() { connectedCount += 1 }
        }
      }
      let status: ConnectionStatus
      if totalCount == 0 || connectedCount == 0 {
        status = .allDisconnected
      } else if connectedCount == totalCount {
        status = .allConnected
      } else {
        status = .partial
      }
      DispatchQueue.main.async { completion(status) }
    }
  }
}
