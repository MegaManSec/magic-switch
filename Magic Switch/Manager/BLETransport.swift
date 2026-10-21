import Combine
import CoreBluetooth
import CryptoKit
import Foundation

enum BLETransportError: LocalizedError {
  case unavailable
  case peerNotFound
  case linkFailed(Error?)

  var errorDescription: String? {
    switch self {
    case .unavailable: return "Bluetooth isn't available."
    case .peerNotFound: return "The other Mac isn't in Bluetooth range."
    case .linkFailed(let error): return error?.localizedDescription ?? "The Bluetooth link dropped."
    }
  }
}

/// Carries peer sessions over Bluetooth LE, for networks that won't let the two
/// Macs reach each other (a VPN that blocks local traffic, Wi-Fi client
/// isolation). Opt-in; when enabled and paired, each Mac publishes a GATT
/// service and scans for the other's. The service UUID is derived from the
/// pairing key, so only Macs paired with the same code see each other.
///
/// Sessions are multiplexed over one link per peer: every write (central to
/// peripheral) and notification (back) is one packet, `[kind][session][bytes]`.
/// `SecureChannel` runs on top unchanged, so the link only carries ciphertext.
final class BLETransport: NSObject, ObservableObject {
  static let shared = BLETransport()

  static let enabledDefaultsKey = "bluetoothTransportEnabled"

  @Published private(set) var isEnabled = UserDefaults.standard.bool(
    forKey: BLETransport.enabledDefaultsKey)
  /// The radio as this transport sees it; `.unknown` while it isn't running.
  @Published private(set) var radioState: CBManagerState = .unknown

  /// Enabled, with a radio that isn't known to be unusable. Main-only.
  var mayReachPeers: Bool {
    isEnabled && ![.poweredOff, .unauthorized, .unsupported].contains(radioState)
  }

  // MARK: - Constants

  private static let inboxUUID = CBUUID(string: "6E1C0A52-4B7E-4D8A-9F3B-2C5D8E7A1B01")
  private static let outboxUUID = CBUUID(string: "6E1C0A52-4B7E-4D8A-9F3B-2C5D8E7A1B02")
  private static let serviceKeyInfo = Data("magicswitch-ble-service-v1".utf8)
  private static let packetHeaderLength = 2
  /// Keeps a link up between sessions, so commands and the next reachability
  /// poll (every 30s) reuse it instead of reconnecting.
  private static let linkIdleTimeout: TimeInterval = 45
  /// How long a new link to a peer waits for the disconnect from cancelling
  /// its previous one, in case that callback never comes.
  private static let cancelSettleTimeout: TimeInterval = 2
  /// Write-without-response readiness isn't always signalled, so a stalled
  /// queue is also retried on this interval.
  private static let writeRetryInterval: TimeInterval = 0.05
  /// How long each `rescan` listens before the radio stops scanning.
  private static let scanWindow: TimeInterval = 10
  /// The service UUID is visible to anything in radio range, so cap how much
  /// of `RateLimiter`'s shared pre-auth budget inbound sessions can hold.
  private static let maxInboundSessions = 16
  /// Enforced on both ends: the peer refuses more, and we queue the rest.
  private static let maxSessionsPerLink = 4
  /// A peer may run ahead of our reads by a frame or so; more is abuse.
  fileprivate static let maxBufferedBytes = 2 * (Int(SecureChannel.maxFrameSize) + 4)

  fileprivate enum PacketKind: UInt8 {
    case open = 1
    case data = 2
    case close = 3
  }

  // MARK: - State

  /// Every CoreBluetooth callback and all state below.
  fileprivate let queue = DispatchQueue(label: "com.magicswitch.ble-transport", qos: .userInitiated)
  /// Runs inbound sessions' `IncomingConnection`s.
  private let inboundQueue = DispatchQueue(label: "com.magicswitch.ble-transport.inbound")
  private var central: CBCentralManager?
  private var peripheralManager: CBPeripheralManager?
  private var serviceUUID: CBUUID?
  private var outbox: CBMutableCharacteristic?
  private var discovered: [UUID: CBPeripheral] = [:]
  /// Links we dialed as central, by the peer's peripheral identifier.
  private var outboundLinks: [UUID: OutboundLink] = [:]
  /// Links the peer dialed into our service, by its central identifier.
  private var inboundLinks: [UUID: InboundLink] = [:]
  /// Peers whose connection we cancelled and whose disconnect hasn't been
  /// reported yet, each with a token for its settle timeout. A new link to one
  /// connects only once that report lands, so it can't take the new link down.
  private var cancellingPeers: [UUID: UUID] = [:]
  private var scanToken: UUID?
  private var localIdentity: () -> IntroducedIdentity? = { nil }
  private var onPeerDiscovered: (UUID) -> Void = { _ in }

  /// Main-only.
  private var pairingObserver: AnyCancellable?

  private override init() {
    super.init()
  }

  // MARK: - Public API

  /// Wires the transport up and brings it up if enabled. `localIdentity`
  /// answers INTRODUCE on inbound sessions; `onPeerDiscovered` gets each
  /// peripheral found advertising our service, on main. Call on main.
  func start(
    localIdentity: @escaping () -> IntroducedIdentity?,
    onPeerDiscovered: @escaping (UUID) -> Void
  ) {
    queue.async {
      self.localIdentity = localIdentity
      self.onPeerDiscovered = onPeerDiscovered
    }
    // Re-pairing changes the service UUID; unpairing takes the transport down.
    pairingObserver = PairingStore.shared.$fingerprint
      .removeDuplicates()
      .sink { [weak self] _ in self?.reconfigure() }
  }

  /// Persists the setting and brings the transport up or down. Call on main.
  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
    reconfigure()
  }

  /// Scans for `scanWindow`, reporting every peer still advertising to
  /// `onPeerDiscovered` again — including one whose private address rotated.
  func rescan() {
    queue.async {
      guard let central = self.central, central.state == .poweredOn else { return }
      central.stopScan()
      self.startScanning()
    }
  }

  /// Opens a session to the peer advertising as `peripheral`. `onOpen` runs on
  /// `deliveryQueue` once the link is up, unless the session is cancelled
  /// first.
  func openSession(
    to peripheral: UUID,
    queue deliveryQueue: DispatchQueue,
    onOpen: @escaping (Result<BLESession, Error>) -> Void
  ) -> BLESession {
    let session = BLESession(
      peer: peripheral, isInbound: false, transport: self, queue: deliveryQueue)
    queue.async { self.attach(session, onOpen: onOpen) }
    return session
  }

  // MARK: - Configuration

  private func reconfigure() {
    let uuid = isEnabled ? PairingStore.shared.currentKey().map(Self.serviceUUID(for:)) : nil
    queue.async { self.apply(serviceUUID: uuid) }
  }

  private static func serviceUUID(for key: SymmetricKey) -> CBUUID {
    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: key, info: serviceKeyInfo, outputByteCount: 16)
    return CBUUID(data: derived.withUnsafeBytes { Data($0) })
  }

  private func apply(serviceUUID uuid: CBUUID?) {
    guard uuid != serviceUUID else { return }
    shutDown()
    serviceUUID = uuid
    guard uuid != nil else {
      Log.network.notice("BLETransport: stopped")
      DispatchQueue.main.async { self.radioState = .unknown }
      return
    }
    Log.network.notice("BLETransport: starting")
    central = CBCentralManager(delegate: self, queue: queue)
    peripheralManager = CBPeripheralManager(delegate: self, queue: queue)
  }

  private func shutDown() {
    for peer in Array(outboundLinks.keys) {
      dropOutboundLink(peer, error: .unavailable)
    }
    for central in Array(inboundLinks.keys) {
      dropInboundLink(central)
    }
    discovered.removeAll()
    cancellingPeers.removeAll()
    scanToken = nil
    central?.stopScan()
    peripheralManager?.stopAdvertising()
    peripheralManager?.removeAllServices()
    central = nil
    peripheralManager = nil
    outbox = nil
  }

  // MARK: - Sessions

  private func attach(
    _ session: BLESession, onOpen: @escaping (Result<BLESession, Error>) -> Void
  ) {
    guard !session.isClosed else { return }
    let fail = { (error: BLETransportError) in
      session.close()
      session.deliver { onOpen(.failure(error)) }
    }
    guard let central = central, central.state == .poweredOn else { return fail(.unavailable) }

    let link: OutboundLink
    if let existing = outboundLinks[session.peer] {
      link = existing
    } else {
      guard
        let peripheral = discovered[session.peer]
          ?? central.retrievePeripherals(withIdentifiers: [session.peer]).first
      else { return fail(.peerNotFound) }
      link = OutboundLink(peripheral: peripheral)
      outboundLinks[session.peer] = link
      peripheral.delegate = self
      if cancellingPeers[session.peer] == nil {
        central.connect(peripheral)
      }
    }
    link.idleTimer?.cancel()
    link.idleTimer = nil
    link.pendingOpens.append((session, onOpen))
    openPending(on: link)
  }

  /// Opens queued sessions while the link is up and has room.
  private func openPending(on link: OutboundLink) {
    guard link.isReady else { return }
    while link.sessions.count < Self.maxSessionsPerLink, !link.pendingOpens.isEmpty,
      let id = link.allocateSessionID()
    {
      let (session, onOpen) = link.pendingOpens.removeFirst()
      session.id = id
      link.sessions[id] = session
      enqueue(.open, session: id, on: link)
      session.deliver { onOpen(.success(session)) }
    }
  }

  /// A session's owner cancelled it: tell the peer, and release the link
  /// once nothing uses it.
  fileprivate func sessionCancelled(_ session: BLESession) {
    if session.isInbound {
      guard let link = inboundLinks[session.peer], link.sessions[session.id] === session else {
        return
      }
      link.sessions.removeValue(forKey: session.id)
      link.packets.purge(session: session.id, error: SecureChannelError.connectionClosed)
      enqueue(.close, session: session.id, on: link)
      return
    }
    guard let link = outboundLinks[session.peer] else { return }
    if let index = link.pendingOpens.firstIndex(where: { $0.session === session }) {
      link.pendingOpens.remove(at: index)
    } else if link.sessions[session.id] === session {
      link.sessions.removeValue(forKey: session.id)
      link.packets.purge(session: session.id, error: SecureChannelError.connectionClosed)
      enqueue(.close, session: session.id, on: link)
      openPending(on: link)
    } else {
      return
    }
    releaseIfIdle(link)
  }

  fileprivate func send(
    _ data: Data, for session: BLESession, completion: @escaping (Error?) -> Void
  ) {
    if session.isInbound, let link = inboundLinks[session.peer] {
      enqueue(.data, session: session.id, payload: data, on: link, completion: completion)
    } else if !session.isInbound, let link = outboundLinks[session.peer], link.isReady {
      enqueue(.data, session: session.id, payload: data, on: link, completion: completion)
    } else {
      completion(SecureChannelError.connectionClosed)
    }
  }

  private func enqueue(
    _ kind: PacketKind, session id: UInt8, payload: Data = Data(), on link: OutboundLink,
    completion: ((Error?) -> Void)? = nil
  ) {
    link.packets.enqueue(
      kind, session: id, payload: payload,
      maxLength: link.peripheral.maximumWriteValueLength(for: .withoutResponse),
      completion: completion)
    drain(link)
  }

  private func drain(_ link: OutboundLink) {
    guard let inbox = link.inbox else { return }
    let peripheral = link.peripheral
    link.packets.drain { packet in
      guard peripheral.canSendWriteWithoutResponse else { return false }
      peripheral.writeValue(packet, for: inbox, type: .withoutResponse)
      return true
    }
    guard !link.packets.isEmpty, !link.isDrainRetryScheduled else { return }
    link.isDrainRetryScheduled = true
    queue.asyncAfter(deadline: .now() + Self.writeRetryInterval) { [weak self] in
      guard let self = self, self.outboundLinks[peripheral.identifier] === link else { return }
      link.isDrainRetryScheduled = false
      self.drain(link)
    }
  }

  private func enqueue(
    _ kind: PacketKind, session id: UInt8, payload: Data = Data(), on link: InboundLink,
    completion: ((Error?) -> Void)? = nil
  ) {
    link.packets.enqueue(
      kind, session: id, payload: payload,
      maxLength: link.central.maximumUpdateValueLength, completion: completion)
    drain(link)
  }

  private func drain(_ link: InboundLink) {
    guard let manager = peripheralManager, let outbox = outbox else { return }
    link.packets.drain {
      manager.updateValue($0, for: outbox, onSubscribedCentrals: [link.central])
    }
  }

  // MARK: - Links

  private func linkBecameReady(_ link: OutboundLink) {
    link.isReady = true
    Log.network.notice("BLETransport: link to \(link.peripheral.identifier) ready")
    openPending(on: link)
    releaseIfIdle(link)
  }

  private func releaseIfIdle(_ link: OutboundLink) {
    guard link.sessions.isEmpty, link.pendingOpens.isEmpty else { return }
    let peer = link.peripheral.identifier
    guard link.isReady else {
      dropOutboundLink(peer, error: .linkFailed(nil))
      return
    }
    let timer = DispatchWorkItem { [weak self] in
      guard let self = self, self.outboundLinks[peer] === link, link.sessions.isEmpty,
        link.pendingOpens.isEmpty
      else {
        return
      }
      self.dropOutboundLink(peer, error: .linkFailed(nil))
    }
    link.idleTimer?.cancel()
    link.idleTimer = timer
    queue.asyncAfter(deadline: .now() + Self.linkIdleTimeout, execute: timer)
  }

  private func dropOutboundLink(_ peer: UUID, error: BLETransportError) {
    guard let link = outboundLinks.removeValue(forKey: peer) else { return }
    link.idleTimer?.cancel()
    for (session, onOpen) in link.pendingOpens {
      session.close()
      session.deliver { onOpen(.failure(error)) }
    }
    for session in link.sessions.values {
      session.peerClosed()
    }
    link.packets.fail(error)
    let peripheral = link.peripheral
    guard peripheral.state != .disconnected else { return }
    if peripheral.state == .connected, let outbox = link.outbox, outbox.isNotifying {
      // The radio link may outlive this cancel when the peer is also dialing
      // us over it; unsubscribing still ends the peer's side of this one.
      peripheral.setNotifyValue(false, for: outbox)
    }
    let token = UUID()
    cancellingPeers[peer] = token
    queue.asyncAfter(deadline: .now() + Self.cancelSettleTimeout) { [weak self] in
      self?.cancelSettled(peer, token: token)
    }
    central?.cancelPeripheralConnection(peripheral)
  }

  /// The cancel of `peer`'s previous link is done (or gave up waiting): let a
  /// link opened meanwhile connect.
  private func cancelSettled(_ peer: UUID, token: UUID? = nil) {
    guard let pending = cancellingPeers[peer], token == nil || token == pending else { return }
    cancellingPeers.removeValue(forKey: peer)
    if let link = outboundLinks[peer], !link.isReady {
      central?.connect(link.peripheral)
    }
  }

  /// `peripheral`'s link, unless the callback is for a peripheral object
  /// from a central since replaced.
  private func outboundLink(for peripheral: CBPeripheral) -> OutboundLink? {
    guard let link = outboundLinks[peripheral.identifier], link.peripheral === peripheral else {
      return nil
    }
    return link
  }

  private func inboundLink(for central: CBCentral) -> InboundLink {
    if let link = inboundLinks[central.identifier] { return link }
    let link = InboundLink(central: central)
    inboundLinks[central.identifier] = link
    return link
  }

  private func dropInboundLink(_ central: UUID) {
    guard let link = inboundLinks.removeValue(forKey: central) else { return }
    for session in link.sessions.values {
      session.peerClosed()
    }
    link.packets.fail(BLETransportError.linkFailed(nil))
  }

  private func startScanning() {
    guard let central = central, let uuid = serviceUUID else { return }
    central.scanForPeripherals(withServices: [uuid])
    let token = UUID()
    scanToken = token
    queue.asyncAfter(deadline: .now() + Self.scanWindow) { [weak self] in
      guard let self = self, self.scanToken == token else { return }
      self.scanToken = nil
      if let central = self.central, central.state == .poweredOn {
        central.stopScan()
      }
    }
  }

  private func publishService() {
    guard let manager = peripheralManager, let uuid = serviceUUID else { return }
    let inbox = CBMutableCharacteristic(
      type: Self.inboxUUID, properties: [.writeWithoutResponse], value: nil,
      permissions: [.writeable])
    let outbox = CBMutableCharacteristic(
      type: Self.outboxUUID, properties: [.notify], value: nil, permissions: [])
    let service = CBMutableService(type: uuid, primary: true)
    service.characteristics = [inbox, outbox]
    self.outbox = outbox
    manager.removeAllServices()
    manager.add(service)
  }

  /// `[kind][session][payload]`, or nil for a malformed packet.
  private static func parse(_ packet: Data) -> (PacketKind, UInt8, Data)? {
    guard packet.count >= packetHeaderLength,
      let kind = PacketKind(rawValue: packet[packet.startIndex])
    else { return nil }
    return (kind, packet[packet.startIndex + 1], Data(packet.dropFirst(packetHeaderLength)))
  }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central === self.central else { return }
    let state = central.state
    DispatchQueue.main.async { self.radioState = state }
    if state == .poweredOn {
      startScanning()
    } else {
      for peer in Array(outboundLinks.keys) {
        dropOutboundLink(peer, error: .unavailable)
      }
      discovered.removeAll()
    }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi: NSNumber
  ) {
    guard central === self.central else { return }
    discovered[peripheral.identifier] = peripheral
    let onPeerDiscovered = onPeerDiscovered
    DispatchQueue.main.async { onPeerDiscovered(peripheral.identifier) }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard central === self.central, let uuid = serviceUUID, outboundLink(for: peripheral) != nil
    else { return }
    peripheral.discoverServices([uuid])
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    linkEnded(peripheral, on: central, error: error)
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    linkEnded(peripheral, on: central, error: error)
  }

  private func linkEnded(_ peripheral: CBPeripheral, on central: CBCentralManager, error: Error?) {
    guard central === self.central else { return }
    if cancellingPeers[peripheral.identifier] != nil {
      return cancelSettled(peripheral.identifier)
    }
    guard outboundLink(for: peripheral) != nil else { return }
    dropOutboundLink(peripheral.identifier, error: .linkFailed(error))
  }
}

// MARK: - CBPeripheralDelegate (links we dialed)

extension BLETransport: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard outboundLink(for: peripheral) != nil else { return }
    guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
      return dropOutboundLink(peripheral.identifier, error: .linkFailed(error))
    }
    peripheral.discoverCharacteristics([Self.inboxUUID, Self.outboxUUID], for: service)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    guard let link = outboundLink(for: peripheral) else { return }
    let characteristics = service.characteristics ?? []
    guard let inbox = characteristics.first(where: { $0.uuid == Self.inboxUUID }),
      let outbox = characteristics.first(where: { $0.uuid == Self.outboxUUID })
    else { return dropOutboundLink(peripheral.identifier, error: .linkFailed(error)) }
    link.inbox = inbox
    link.outbox = outbox
    peripheral.setNotifyValue(true, for: outbox)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard let link = outboundLink(for: peripheral), !link.isReady else { return }
    guard error == nil, characteristic.isNotifying else {
      return dropOutboundLink(peripheral.identifier, error: .linkFailed(error))
    }
    linkBecameReady(link)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard let link = outboundLink(for: peripheral), characteristic.uuid == Self.outboxUUID,
      let value = characteristic.value, let (kind, id, payload) = Self.parse(value)
    else { return }
    switch kind {
    case .data:
      link.sessions[id]?.receive(payload)
    case .close:
      guard let session = link.sessions.removeValue(forKey: id) else { return }
      session.peerClosed()
      openPending(on: link)
      releaseIfIdle(link)
    case .open:
      break
    }
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    guard let link = outboundLink(for: peripheral) else { return }
    drain(link)
  }

  func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
    // Ours goes away when the peer re-pairs or turns the transport off.
    guard outboundLink(for: peripheral) != nil,
      invalidatedServices.contains(where: { $0.uuid == serviceUUID })
    else { return }
    dropOutboundLink(peripheral.identifier, error: .linkFailed(nil))
  }
}

// MARK: - CBPeripheralManagerDelegate (links the peer dialed)

extension BLETransport: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    guard peripheral === peripheralManager else { return }
    if peripheral.state == .poweredOn {
      publishService()
    } else {
      for central in Array(inboundLinks.keys) {
        dropInboundLink(central)
      }
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?
  ) {
    guard peripheral === peripheralManager else { return }
    if let error = error {
      Log.network.error("BLETransport: couldn't publish service: \(error)")
      return
    }
    peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid]])
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error = error {
      Log.network.error("BLETransport: couldn't advertise: \(error)")
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    guard peripheral === peripheralManager else { return }
    _ = inboundLink(for: central)
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]
  ) {
    guard peripheral === peripheralManager else { return }
    for request in requests where request.characteristic.uuid == Self.inboxUUID {
      // A write can land before the central's subscription is reported.
      guard let value = request.value, let (kind, id, payload) = Self.parse(value) else { continue }
      let link = inboundLink(for: request.central)
      switch kind {
      case .open:
        link.sessions.removeValue(forKey: id)?.peerClosed()
        let inboundCount = inboundLinks.values.reduce(0) { $0 + $1.sessions.count }
        guard link.sessions.count < Self.maxSessionsPerLink,
          inboundCount < Self.maxInboundSessions
        else {
          enqueue(.close, session: id, on: link)
          continue
        }
        let session = BLESession(
          peer: link.central.identifier, isInbound: true, transport: self, queue: inboundQueue)
        session.id = id
        link.sessions[id] = session
        let incoming = IncomingConnection(
          session: session, rateLimiter: .shared, pairingStore: .shared, queue: inboundQueue,
          localIdentity: localIdentity)
        inboundQueue.async { incoming.start() }
      case .data:
        link.sessions[id]?.receive(payload)
      case .close:
        link.sessions.removeValue(forKey: id)?.peerClosed()
      }
    }
  }

  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    guard peripheral === peripheralManager else { return }
    for link in inboundLinks.values {
      drain(link)
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    guard peripheral === peripheralManager else { return }
    dropInboundLink(central.identifier)
  }
}

// MARK: - Links

/// A link we dialed to a peer's service, and the sessions riding it.
private final class OutboundLink {
  let peripheral: CBPeripheral
  var inbox: CBCharacteristic?
  var outbox: CBCharacteristic?
  /// Subscribed to the peer's outbox, so sessions can open.
  var isReady = false
  var sessions: [UInt8: BLESession] = [:]
  /// Sessions waiting for the link to come up or for a free slot.
  var pendingOpens: [(session: BLESession, onOpen: (Result<BLESession, Error>) -> Void)] = []
  var packets = PacketQueue()
  var isDrainRetryScheduled = false
  var idleTimer: DispatchWorkItem?
  /// Random, so a new link doesn't reuse the ids a stale peer-side link of the
  /// last one may still be answering on.
  private var lastSessionID = UInt8.random(in: .min ... .max)

  init(peripheral: CBPeripheral) {
    self.peripheral = peripheral
  }

  func allocateSessionID() -> UInt8? {
    for _ in 0...UInt8.max {
      lastSessionID &+= 1
      if sessions[lastSessionID] == nil { return lastSessionID }
    }
    return nil
  }
}

/// A link a peer dialed into our service, and the sessions riding it.
private final class InboundLink {
  let central: CBCentral
  var sessions: [UInt8: BLESession] = [:]
  var packets = PacketQueue()

  init(central: CBCentral) {
    self.central = central
  }
}

/// One link's outgoing packets, handed to CoreBluetooth as it has room. A
/// send's completion fires once its last packet is handed over.
private struct PacketQueue {
  private var packets: [(data: Data, session: UInt8, completion: ((Error?) -> Void)?)] = []

  var isEmpty: Bool { packets.isEmpty }

  mutating func enqueue(
    _ kind: BLETransport.PacketKind, session: UInt8, payload: Data, maxLength: Int,
    completion: ((Error?) -> Void)?
  ) {
    let header = Data([kind.rawValue, session])
    let chunkLength = max(maxLength - header.count, 1)
    var offset = payload.startIndex
    repeat {
      let end = min(offset + chunkLength, payload.endIndex)
      packets.append((header + payload[offset..<end], session, nil))
      offset = end
    } while offset < payload.endIndex
    packets[packets.count - 1].completion = completion
  }

  /// Hands packets to `write` until it reports no room.
  mutating func drain(_ write: (Data) -> Bool) {
    while let next = packets.first, write(next.data) {
      packets.removeFirst()
      next.completion?(nil)
    }
  }

  /// Drops `session`'s unsent packets, failing their sends.
  mutating func purge(session: UInt8, error: Error) {
    let purged = packets.filter { $0.session == session }
    packets.removeAll { $0.session == session }
    for packet in purged {
      packet.completion?(error)
    }
  }

  mutating func fail(_ error: Error) {
    let failed = packets
    packets.removeAll()
    for packet in failed {
      packet.completion?(error)
    }
  }
}

// MARK: - Session

/// One stream multiplexed over a Bluetooth link. State lives on the
/// transport's queue; completions are delivered on the owner's queue.
final class BLESession: TransportConnection {
  /// The peer's CoreBluetooth identifier: the peripheral we dialed, or the
  /// central that dialed us.
  let peer: UUID
  let isInbound: Bool
  /// The session's number on its link. Transport-queue only, like the state
  /// below.
  fileprivate var id: UInt8 = 0
  fileprivate private(set) var isClosed = false

  private let transport: BLETransport
  private var deliveryQueue: DispatchQueue
  private var onClose: (() -> Void)?
  private var buffer = Data()
  private var pendingRead: (byteCount: Int, completion: (Result<Data, SecureChannelError>) -> Void)?

  fileprivate init(peer: UUID, isInbound: Bool, transport: BLETransport, queue: DispatchQueue) {
    self.peer = peer
    self.isInbound = isInbound
    self.transport = transport
    self.deliveryQueue = queue
  }

  // MARK: TransportConnection

  func start(queue: DispatchQueue, onClose: @escaping () -> Void) {
    transport.queue.async {
      self.deliveryQueue = queue
      if self.isClosed {
        self.deliver(onClose)
      } else {
        self.onClose = onClose
      }
    }
  }

  func send(_ data: Data, completion: @escaping (Error?) -> Void) {
    transport.queue.async {
      guard !self.isClosed else {
        return self.deliver { completion(SecureChannelError.connectionClosed) }
      }
      self.transport.send(data, for: self) { error in
        self.deliver { completion(error) }
      }
    }
  }

  func receive(
    exactly byteCount: Int, completion: @escaping (Result<Data, SecureChannelError>) -> Void
  ) {
    transport.queue.async {
      self.pendingRead = (byteCount, completion)
      self.satisfyRead()
    }
  }

  func cancel() {
    transport.queue.async { self.abort() }
  }

  // MARK: Transport-queue entry points

  fileprivate func receive(_ data: Data) {
    guard !isClosed else { return }
    guard buffer.count + data.count <= BLETransport.maxBufferedBytes else {
      Log.network.error("BLETransport: peer overran a session's buffer; closing it")
      return abort()
    }
    buffer.append(data)
    satisfyRead()
  }

  /// The peer closed the session or the link dropped. Bytes already
  /// received stay readable.
  fileprivate func peerClosed() {
    guard !isClosed else { return }
    close()
    satisfyRead()
  }

  private func abort() {
    guard !isClosed else { return }
    close()
    buffer.removeAll()
    satisfyRead()
    transport.sessionCancelled(self)
  }

  fileprivate func close() {
    isClosed = true
    if let onClose = onClose {
      self.onClose = nil
      deliver(onClose)
    }
  }

  fileprivate func deliver(_ work: @escaping () -> Void) {
    deliveryQueue.async(execute: work)
  }

  private func satisfyRead() {
    guard let read = pendingRead else { return }
    if buffer.count >= read.byteCount {
      pendingRead = nil
      let bytes = Data(buffer.prefix(read.byteCount))
      buffer.removeFirst(read.byteCount)
      deliver { read.completion(.success(bytes)) }
    } else if isClosed {
      pendingRead = nil
      deliver { read.completion(.failure(.connectionClosed)) }
    }
  }
}
