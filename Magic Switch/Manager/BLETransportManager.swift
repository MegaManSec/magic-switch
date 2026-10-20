import CoreBluetooth
import Foundation

/// Coordinates peer discovery and bidirectional session management over Bluetooth LE.
/// Operates simultaneously as a GATT Server (CBPeripheralManager) to receive handoff commands
/// and as a GATT Client (CBCentralManager) to discover and dispatch commands to peer Macs.
final class BLETransportManager: NSObject, ObservableObject {
  // MARK: - Singleton

  static let shared = BLETransportManager()

  // MARK: - Properties

  private let centralQueue = DispatchQueue(label: "com.magicswitch.ble.central.queue")
  private let peripheralQueue = DispatchQueue(label: "com.magicswitch.ble.peripheral.queue")
  private let rateLimiter = RateLimiter()

  private var centralManager: CBCentralManager?
  private var peripheralManager: CBPeripheralManager?

  // Peripheral (Server) state
  private var serviceAdded = false
  private var responseCharacteristic: CBMutableCharacteristic?
  private var activeServerConnections: [UUID: BLETransportConnection] = [:]

  // Central (Client) state
  private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
  private var lastSeen: [UUID: Date] = [:]
  private var lastPeerActivity: Date?
  private var activeClientConnections: [UUID: BLETransportConnection] = [:]
  private var pendingClientConnects: [UUID: (Result<BLETransportConnection, Error>) -> Void] = [:]
  private var discoveryTimer: DispatchSourceTimer?

  /// Whether the Bluetooth radio is powered on and ready for connections.
  var isAvailable: Bool {
    centralQueue.sync {
      centralManager?.state == .poweredOn
    }
  }

  /// Whether an active BLE session exists or a peer communicated recently.
  var hasRecentPeerActivity: Bool {
    centralQueue.sync {
      if !activeServerConnections.isEmpty || !activeClientConnections.isEmpty { return true }
      if let activity = lastPeerActivity, Date().timeIntervalSince(activity) < 60 {
        return true
      }
      return false
    }
  }

  /// Records recent peer communication over Bluetooth.
  func notePeerActivity() {
    centralQueue.async { [weak self] in
      self?.lastPeerActivity = Date()
    }
  }

  // Queued outgoing client connection requests per peer (to serialize BLE access)
  private struct QueuedClientRequest {
    let id: UUID
    let timeout: TimeInterval
    let completion: (Result<BLETransportConnection, Error>) -> Void
  }

  private var queuedClientRequests: [UUID: [QueuedClientRequest]] = [:]
  private var queueTimers: [UUID: DispatchSourceTimer] = [:]

  // MARK: - Lifecycle

  func start() {
    centralQueue.async { [weak self] in
      guard let self = self else { return }
      if self.centralManager == nil {
        self.centralManager = CBCentralManager(delegate: self, queue: self.centralQueue)
      }
    }
    peripheralQueue.async { [weak self] in
      guard let self = self else { return }
      if self.peripheralManager == nil {
        self.peripheralManager = CBPeripheralManager(delegate: self, queue: self.peripheralQueue)
      }
    }
    startPeriodicDiscoveryTimer()
    Log.network.notice("BLETransportManager: started Bluetooth transport services")
  }

  func stop() {
    discoveryTimer?.cancel()
    discoveryTimer = nil
    centralQueue.async { [weak self] in
      guard let self = self else { return }
      for (_, timer) in self.queueTimers {
        timer.cancel()
      }
      self.queueTimers.removeAll()
      for (_, requests) in self.queuedClientRequests {
        requests.forEach { $0.completion(.failure(BLETransportError.disconnected)) }
      }
      self.queuedClientRequests.removeAll()
      self.centralManager?.stopScan()
    }
    peripheralQueue.async { [weak self] in
      self?.peripheralManager?.stopAdvertising()
    }
    Log.network.notice("BLETransportManager: stopped Bluetooth transport services")
  }

  /// Triggers a fresh scan and check for connected Bluetooth peers.
  func refresh() {
    centralQueue.async { [weak self] in
      guard let self = self else { return }
      Log.network.notice("BLETransportManager: refreshing Bluetooth discovery")
      self.scanAndRetrievePeripherals()
    }
    peripheralQueue.async { [weak self] in
      guard let self = self else { return }
      self.ensureAdvertising()
    }
  }

  private func startPeriodicDiscoveryTimer() {
    centralQueue.async { [weak self] in
      guard let self = self, self.discoveryTimer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: self.centralQueue)
      timer.schedule(deadline: .now() + 2, repeating: 10.0)
      timer.setEventHandler { [weak self] in
        self?.scanAndRetrievePeripherals()
        self?.ensureAdvertising()
      }
      timer.resume()
      self.discoveryTimer = timer
    }
  }

  private func ensureAdvertising() {
    peripheralQueue.async { [weak self] in
      guard let self = self,
        let manager = self.peripheralManager,
        manager.state == .poweredOn,
        self.serviceAdded,
        !manager.isAdvertising
      else { return }
      self.startAdvertising()
    }
  }

  /// Scans for advertising peer Macs and checks for already-connected Bluetooth peers.
  func scanAndRetrievePeripherals() {
    centralQueue.async { [weak self] in
      guard let self = self, let central = self.centralManager, central.state == .poweredOn else {
        return
      }

      // 1. Retrieve already-connected peripherals that advertise/host our service
      let connected = central.retrieveConnectedPeripherals(withServices: [MagicSwitchBLE.serviceUUID])
      if !connected.isEmpty {
        Log.network.notice(
          "BLETransportManager: retrieveConnectedPeripherals found \(connected.count) peer(s)"
        )
        for peripheral in connected {
          self.handleDiscoveredPeripheral(peripheral)
        }
      }

      // 2. Start scanning for advertising peers
      central.scanForPeripherals(
        withServices: [MagicSwitchBLE.serviceUUID],
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
      )
    }
  }

  private func handleDiscoveredPeripheral(_ peripheral: CBPeripheral) {
    discoveredPeripherals[peripheral.identifier] = peripheral
    lastSeen[peripheral.identifier] = Date()
    peripheral.delegate = self

    if peripheral.state == .connected {
      prepareConnectedPeripheral(peripheral)
    } else if peripheral.state == .disconnected {
      Log.network.notice(
        "BLETransportManager: connecting to discovered peripheral '\(peripheral.name ?? "unnamed")' (\(peripheral.identifier))"
      )
      centralManager?.connect(peripheral, options: nil)
    }
  }

  /// Checks whether a peer device is currently known and reachable over Bluetooth.
  func isPeerAvailable(identifier: UUID) -> Bool {
    centralQueue.sync {
      if !activeServerConnections.isEmpty || !activeClientConnections.isEmpty { return true }
      if let seen = lastPeerActivity, Date().timeIntervalSince(seen) < 60 {
        return true
      }
      if let p = discoveredPeripherals[identifier] {
        if p.state == .connected { return true }
        if let seen = lastSeen[identifier], Date().timeIntervalSince(seen) < 30 {
          return true
        }
        return centralManager?.state == .poweredOn
      }
      if let central = centralManager, central.state == .poweredOn {
        if let retrieved = central.retrievePeripherals(withIdentifiers: [identifier]).first {
          discoveredPeripherals[identifier] = retrieved
          retrieved.delegate = self
          return true
        }
        if !discoveredPeripherals.isEmpty {
          return true
        }
      }
      return false
    }
  }

  /// Establishes an authenticated transport connection to a discovered peer Mac over BLE.
  func connect(
    to peripheralIdentifier: UUID,
    timeout: TimeInterval = MagicSwitchBLE.bleConnectTimeout,
    completion: @escaping (Result<BLETransportConnection, Error>) -> Void
  ) {
    self.notePeerActivity()
    centralQueue.async {
      guard let central = self.centralManager, central.state == .poweredOn else {
        completion(.failure(BLETransportError.notConnected))
        return
      }

      var targetPeripheral = self.discoveredPeripherals[peripheralIdentifier]
      if targetPeripheral == nil {
        if let retrieved = central.retrievePeripherals(withIdentifiers: [peripheralIdentifier]).first {
          self.discoveredPeripherals[peripheralIdentifier] = retrieved
          retrieved.delegate = self
          targetPeripheral = retrieved
        }
      }

      guard let peripheral = targetPeripheral else {
        completion(.failure(BLETransportError.characteristicNotFound))
        return
      }

      // If this peer already has an active client connection or a connect in flight, serialize by queueing
      if self.activeClientConnections[peripheralIdentifier] != nil
        || self.pendingClientConnects[peripheralIdentifier] != nil
      {
        Log.network.notice(
          "BLETransportManager: peer \(peripheralIdentifier) is busy; queueing request (timeout \(timeout)s)"
        )
        self.enqueueClientRequest(
          peripheralIdentifier: peripheralIdentifier,
          timeout: timeout,
          completion: completion
        )
        return
      }

      // Check if peripheral is connected and characteristics are ready and notifying
      if peripheral.state == .connected,
        let service = peripheral.services?.first(where: { $0.uuid == MagicSwitchBLE.serviceUUID }),
        let commandChar = service.characteristics?.first(where: {
          $0.uuid == MagicSwitchBLE.commandCharacteristicUUID
        }),
        let responseChar = service.characteristics?.first(where: {
          $0.uuid == MagicSwitchBLE.responseCharacteristicUUID
        }),
        responseChar.isNotifying
      {
        self.establishClientConnection(
          peripheral: peripheral,
          commandChar: commandChar,
          completion: completion
        )
        return
      }

      self.pendingClientConnects[peripheralIdentifier] = completion

      // If already connected, discover characteristics directly
      if peripheral.state == .connected {
        self.prepareConnectedPeripheral(peripheral)
      } else {
        central.connect(peripheral, options: nil)
      }

      // Enforce connection timeout
      self.centralQueue.asyncAfter(deadline: .now() + timeout) {
        if let pending = self.pendingClientConnects.removeValue(forKey: peripheralIdentifier) {
          pending(.failure(BLETransportError.timeout))
          self.processNextQueuedClientRequest(for: peripheralIdentifier)
        }
      }
    }
  }

  private func enqueueClientRequest(
    peripheralIdentifier: UUID,
    timeout: TimeInterval,
    completion: @escaping (Result<BLETransportConnection, Error>) -> Void
  ) {
    let reqID = UUID()
    let timer = DispatchSource.makeTimerSource(queue: centralQueue)
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      if var list = self.queuedClientRequests[peripheralIdentifier] {
        if let idx = list.firstIndex(where: { $0.id == reqID }) {
          let req = list.remove(at: idx)
          self.queuedClientRequests[peripheralIdentifier] = list.isEmpty ? nil : list
          self.queueTimers.removeValue(forKey: reqID)?.cancel()
          Log.network.notice(
            "BLETransportManager: queued request for \(peripheralIdentifier) timed out"
          )
          req.completion(.failure(BLETransportError.timeout))
        }
      }
    }
    timer.resume()
    queueTimers[reqID] = timer

    let request = QueuedClientRequest(
      id: reqID,
      timeout: timeout,
      completion: { [weak self] result in
        self?.centralQueue.async {
          self?.queueTimers.removeValue(forKey: reqID)?.cancel()
        }
        completion(result)
      }
    )
    queuedClientRequests[peripheralIdentifier, default: []].append(request)
  }

  private func processNextQueuedClientRequest(for peripheralIdentifier: UUID) {
    // Only process if no active connection and no connect in flight
    guard activeClientConnections[peripheralIdentifier] == nil,
      pendingClientConnects[peripheralIdentifier] == nil
    else { return }

    guard var list = queuedClientRequests[peripheralIdentifier], !list.isEmpty else {
      queuedClientRequests.removeValue(forKey: peripheralIdentifier)
      return
    }

    let next = list.removeFirst()
    queuedClientRequests[peripheralIdentifier] = list.isEmpty ? nil : list
    queueTimers.removeValue(forKey: next.id)?.cancel()

    Log.network.notice(
      "BLETransportManager: processing queued client request for \(peripheralIdentifier) (\(list.count) remaining)"
    )

    connect(to: peripheralIdentifier, timeout: next.timeout, completion: next.completion)
  }

  private func establishClientConnection(
    peripheral: CBPeripheral,
    commandChar: CBCharacteristic,
    completion: @escaping (Result<BLETransportConnection, Error>) -> Void
  ) {
    let peripheralIdentifier = peripheral.identifier
    if let old = self.activeClientConnections[peripheralIdentifier] {
      old.cancel()
    }

    let connection = BLETransportConnection(
      peripheral: peripheral,
      commandCharacteristic: commandChar,
      queue: centralQueue
    )
    connection.onCancel = { [weak self] in
      self?.centralQueue.async {
        if self?.activeClientConnections[peripheralIdentifier] === connection {
          self?.activeClientConnections.removeValue(forKey: peripheralIdentifier)
        }
        self?.processNextQueuedClientRequest(for: peripheralIdentifier)
      }
    }
    self.activeClientConnections[peripheralIdentifier] = connection

    connection.startSession { [weak self] error in
      self?.centralQueue.async {
        if let error = error {
          connection.cancel()
          completion(.failure(error))
        } else {
          completion(.success(connection))
        }
      }
    }
  }

  private func prepareConnectedPeripheral(_ peripheral: CBPeripheral) {
    peripheral.delegate = self
    if let service = peripheral.services?.first(where: { $0.uuid == MagicSwitchBLE.serviceUUID }) {
      if service.characteristics != nil {
        self.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
      } else {
        peripheral.discoverCharacteristics(
          [
            MagicSwitchBLE.commandCharacteristicUUID,
            MagicSwitchBLE.responseCharacteristicUUID,
            MagicSwitchBLE.metadataCharacteristicUUID,
          ],
          for: service
        )
      }
    } else {
      peripheral.discoverServices([MagicSwitchBLE.serviceUUID])
    }
  }
}

// MARK: - CBPeripheralManagerDelegate (Server / Peripheral Role)

extension BLETransportManager: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    guard peripheral.state == .poweredOn else { return }

    if !serviceAdded {
      setupGATTService(peripheral)
    } else {
      startAdvertising()
    }
  }

  private func setupGATTService(_ manager: CBPeripheralManager) {
    let service = CBMutableService(type: MagicSwitchBLE.serviceUUID, primary: true)

    let commandChar = CBMutableCharacteristic(
      type: MagicSwitchBLE.commandCharacteristicUUID,
      properties: [.write, .writeWithoutResponse],
      value: nil,
      permissions: [.writeable]
    )

    let responseChar = CBMutableCharacteristic(
      type: MagicSwitchBLE.responseCharacteristicUUID,
      properties: [.notify],
      value: nil,
      permissions: []
    )
    self.responseCharacteristic = responseChar

    let metadataChar = CBMutableCharacteristic(
      type: MagicSwitchBLE.metadataCharacteristicUUID,
      properties: [.read],
      value: nil,
      permissions: [.readable]
    )

    service.characteristics = [commandChar, responseChar, metadataChar]
    manager.add(service)
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?
  ) {
    if let error = error {
      Log.network.error("BLETransportManager: failed to add GATT service: \(error)")
      return
    }
    serviceAdded = true
    startAdvertising()
  }

  private func startAdvertising() {
    guard let manager = peripheralManager, manager.state == .poweredOn else { return }
    let advertisementData: [String: Any] = [
      CBAdvertisementDataServiceUUIDsKey: [MagicSwitchBLE.serviceUUID]
    ]
    if manager.isAdvertising {
      manager.stopAdvertising()
    }
    manager.startAdvertising(advertisementData)
    Log.network.notice(
      "BLETransportManager: advertising Magic Switch service UUID '\(MagicSwitchBLE.serviceUUID)'"
    )
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard request.characteristic.uuid == MagicSwitchBLE.metadataCharacteristicUUID else {
      peripheral.respond(to: request, withResult: .requestNotSupported)
      return
    }

    let localName = Host.current().localizedName ?? "Mac"
    let fingerprint = PairingStore.shared.fingerprint
    let metadata = BLEPeerMetadata(
      name: localName,
      fingerprint: fingerprint,
      version: MagicSwitchBLE.protocolVersion
    )

    do {
      let data = try JSONEncoder().encode(metadata)
      if request.offset > data.count {
        peripheral.respond(to: request, withResult: .invalidOffset)
        return
      }
      request.value = data.subdata(in: request.offset..<data.count)
      peripheral.respond(to: request, withResult: .success)
    } catch {
      peripheral.respond(to: request, withResult: .unlikelyError)
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]
  ) {
    for request in requests {
      guard request.characteristic.uuid == MagicSwitchBLE.commandCharacteristicUUID,
        let data = request.value
      else {
        peripheral.respond(to: request, withResult: .requestNotSupported)
        continue
      }

      let centralID = request.central.identifier
      let connection = activeServerConnections[centralID]

      if data == MagicSwitchBLE.sessionStartMagic {
        self.notePeerActivity()
        if let oldConn = connection {
          Log.network.notice(
            "BLETransportManager: resetting previous server session for \(centralID) on sessionStartMagic"
          )
          oldConn.cancel()
        }

        if let responseChar = responseCharacteristic {
          let newConn = BLETransportConnection(
            central: request.central,
            peripheralManager: peripheral,
            responseCharacteristic: responseChar,
            queue: peripheralQueue
          )
          newConn.onCancel = { [weak self] in
            self?.peripheralQueue.async {
              if self?.activeServerConnections[centralID] === newConn {
                self?.activeServerConnections.removeValue(forKey: centralID)
              }
            }
          }
          activeServerConnections[centralID] = newConn

          DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let incoming = IncomingConnection(
              transport: newConn,
              endpointDesc: "Bluetooth (\(centralID))",
              rateLimiter: self.rateLimiter,
              pairingStore: PairingStore.shared,
              queue: DispatchQueue(label: "com.magicswitch.ble.incoming.\(centralID)"),
              localIdentity: {
                IntroducedIdentity(
                  name: Host.current().localizedName ?? "Mac",
                  port: 0
                )
              }
            )
            incoming.start()
          }
        }
        peripheral.respond(to: request, withResult: .success)
        continue
      }

      if data == MagicSwitchBLE.sessionEndMagic {
        self.notePeerActivity()
        if let conn = connection {
          Log.network.notice(
            "BLETransportManager: tearing down server session for \(centralID) on sessionEndMagic"
          )
          conn.cancel()
          activeServerConnections.removeValue(forKey: centralID)
        }
        peripheral.respond(to: request, withResult: .success)
        continue
      }

      // Stream data for active session
      if let conn = connection, conn.isConnected {
        conn.ingestIncomingData(data)
      } else {
        Log.network.error(
          "BLETransportManager: received write for \(centralID) with no active session"
        )
      }
      peripheral.respond(to: request, withResult: .success)
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    Log.network.notice(
      "BLETransportManager: central \(central.identifier) subscribed to \(characteristic.uuid)"
    )
    activeServerConnections[central.identifier]?.handlePeripheralReady()
  }

  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    Log.network.notice("BLETransportManager: peripheral manager is ready to update subscribers")
    for connection in activeServerConnections.values {
      connection.handlePeripheralReady()
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    Log.network.notice(
      "BLETransportManager: central \(central.identifier) unsubscribed from \(characteristic.uuid)"
    )
    activeServerConnections.removeValue(forKey: central.identifier)
  }
}

// MARK: - CBCentralManagerDelegate (Client / Central Role)

extension BLETransportManager: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    Log.network.notice(
      "BLETransportManager: central manager state updated: \(central.state.rawValue)"
    )
    guard central.state == .poweredOn else { return }
    scanAndRetrievePeripherals()
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    Log.network.notice(
      "BLETransportManager: didDiscover peripheral '\(peripheral.name ?? "unnamed")' (\(peripheral.identifier)), rssi: \(RSSI)"
    )
    handleDiscoveredPeripheral(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    Log.network.notice(
      "BLETransportManager: central connected to peripheral '\(peripheral.name ?? "unnamed")' (\(peripheral.identifier))"
    )
    prepareConnectedPeripheral(peripheral)
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    Log.network.error(
      "BLETransportManager: failed to connect to peripheral \(peripheral.identifier): \(String(describing: error))"
    )
    if let pending = pendingClientConnects.removeValue(forKey: peripheral.identifier) {
      pending(.failure(error ?? BLETransportError.notConnected))
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    Log.network.notice(
      "BLETransportManager: disconnected from peripheral \(peripheral.identifier): \(String(describing: error))"
    )
    if let conn = activeClientConnections.removeValue(forKey: peripheral.identifier) {
      conn.cancel()
    }
    if let pending = pendingClientConnects.removeValue(forKey: peripheral.identifier) {
      pending(.failure(BLETransportError.disconnected))
    }
    if let queued = queuedClientRequests.removeValue(forKey: peripheral.identifier) {
      for req in queued {
        queueTimers.removeValue(forKey: req.id)?.cancel()
        req.completion(.failure(BLETransportError.disconnected))
      }
    }
  }
}

// MARK: - CBPeripheralDelegate (Client characteristics and I/O)

extension BLETransportManager: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error = error {
      Log.network.error("BLETransportManager: didDiscoverServices error: \(error)")
      return
    }
    guard let services = peripheral.services else { return }
    Log.network.notice(
      "BLETransportManager: discovered \(services.count) service(s) for \(peripheral.identifier)"
    )
    for service in services where service.uuid == MagicSwitchBLE.serviceUUID {
      peripheral.discoverCharacteristics(
        [
          MagicSwitchBLE.commandCharacteristicUUID,
          MagicSwitchBLE.responseCharacteristicUUID,
          MagicSwitchBLE.metadataCharacteristicUUID,
        ],
        for: service
      )
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    if let error = error {
      Log.network.error("BLETransportManager: didDiscoverCharacteristics error: \(error)")
      return
    }
    guard let characteristics = service.characteristics else { return }
    Log.network.notice(
      "BLETransportManager: discovered \(characteristics.count) characteristic(s) for \(peripheral.identifier)"
    )

    var commandChar: CBCharacteristic?
    var responseChar: CBCharacteristic?
    var metadataChar: CBCharacteristic?

    for char in characteristics {
      switch char.uuid {
      case MagicSwitchBLE.commandCharacteristicUUID: commandChar = char
      case MagicSwitchBLE.responseCharacteristicUUID: responseChar = char
      case MagicSwitchBLE.metadataCharacteristicUUID: metadataChar = char
      default: break
      }
    }

    // Subscribe to responses if not already notifying
    if let responseChar = responseChar {
      if !responseChar.isNotifying {
        peripheral.setNotifyValue(true, for: responseChar)
      } else if let commandChar = commandChar,
        let pending = pendingClientConnects.removeValue(forKey: peripheral.identifier)
      {
        establishClientConnection(
          peripheral: peripheral,
          commandChar: commandChar,
          completion: pending
        )
      }
    }

    // Read peer metadata to register in NetworkDeviceStore if not yet registered
    if let metadataChar = metadataChar,
      !NetworkDeviceStore.shared.networkDevices.contains(where: { $0.bluetoothID == peripheral.identifier })
    {
      peripheral.readValue(for: metadataChar)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let error = error {
      Log.network.error(
        "BLETransportManager: didUpdateNotificationStateFor error for \(characteristic.uuid): \(error)"
      )
      if let pending = pendingClientConnects.removeValue(forKey: peripheral.identifier) {
        pending(.failure(error))
      }
      return
    }

    Log.network.notice(
      "BLETransportManager: notification state for \(characteristic.uuid) is now \(characteristic.isNotifying)"
    )

    if characteristic.uuid == MagicSwitchBLE.responseCharacteristicUUID
      && characteristic.isNotifying
    {
      if let pending = pendingClientConnects.removeValue(forKey: peripheral.identifier) {
        if let service = peripheral.services?.first(where: {
          $0.uuid == MagicSwitchBLE.serviceUUID
        }),
          let commandChar = service.characteristics?.first(where: {
            $0.uuid == MagicSwitchBLE.commandCharacteristicUUID
          })
        {
          establishClientConnection(
            peripheral: peripheral,
            commandChar: commandChar,
            completion: pending
          )
        } else {
          pending(.failure(BLETransportError.characteristicNotFound))
        }
      }
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard error == nil, let data = characteristic.value else {
      if let error = error {
        Log.network.error("BLETransportManager: didUpdateValueFor error: \(error)")
      }
      return
    }

    if characteristic.uuid == MagicSwitchBLE.metadataCharacteristicUUID {
      // Decode and register peer in NetworkDeviceStore
      do {
        let metadata = try JSONDecoder().decode(BLEPeerMetadata.self, from: data)
        Log.network.notice(
          "BLETransportManager: received peer metadata: name='\(metadata.name)', fingerprint=\(metadata.fingerprint ?? "nil")"
        )
        DispatchQueue.main.async {
          NetworkDeviceStore.shared.registerDiscoveredBluetoothPeer(
            identifier: peripheral.identifier,
            name: metadata.name,
            fingerprint: metadata.fingerprint
          )
        }
      } catch {
        Log.network.error("BLETransportManager: failed to decode peer metadata: \(error)")
      }
    } else if characteristic.uuid == MagicSwitchBLE.responseCharacteristicUUID {
      // Deliver response data to the active client connection
      if let connection = activeClientConnections[peripheral.identifier] {
        connection.ingestIncomingData(data)
      }
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let connection = activeClientConnections[peripheral.identifier] {
      connection.handleDidWriteValue(error: error)
    }
  }
}
