import CoreBluetooth
import Foundation

/// Errors specific to BLE transport connections.
enum BLETransportError: Error {
  case disconnected
  case notConnected
  case writeFailed(String)
  case characteristicNotFound
  case timeout
}

/// A `TransportConnection` operating over CoreBluetooth.
/// Bridges a Bluetooth Low Energy link into a reliable stream for `SecureChannel`.
final class BLETransportConnection: NSObject, TransportConnection {
  // MARK: - Types

  private struct SendTask {
    var chunks: [Data]
    let completion: (Error?) -> Void
  }

  // MARK: - Properties

  private let byteStreamBuffer: ByteStreamBuffer
  private let queue: DispatchQueue
  private var isCancelled = false

  // Central-side properties
  private weak var peripheral: CBPeripheral?
  private var commandCharacteristic: CBCharacteristic?
  private var sendQueue: [SendTask] = []
  private var isSending = false

  // Peripheral-side properties
  private weak var central: CBCentral?
  private weak var peripheralManager: CBPeripheralManager?
  private var responseCharacteristic: CBMutableCharacteristic?
  private var peripheralSendQueue: [SendTask] = []
  private var isPeripheralSending = false

  /// Invoked when the transport connection is cancelled and torn down.
  var onCancel: (() -> Void)?

  var isConnected: Bool {
    if isCancelled { return false }
    if let peripheral = peripheral {
      return peripheral.state == .connected
    }
    return central != nil && peripheralManager != nil
  }

  // MARK: - Initialization (Central / Outgoing Role)

  init(
    peripheral: CBPeripheral,
    commandCharacteristic: CBCharacteristic,
    queue: DispatchQueue = DispatchQueue(label: "com.magicswitch.ble.conn.central")
  ) {
    self.peripheral = peripheral
    self.commandCharacteristic = commandCharacteristic
    self.queue = queue
    self.byteStreamBuffer = ByteStreamBuffer(queue: queue)
    super.init()
  }

  // MARK: - Initialization (Peripheral / Incoming Role)

  init(
    central: CBCentral,
    peripheralManager: CBPeripheralManager,
    responseCharacteristic: CBMutableCharacteristic,
    queue: DispatchQueue = DispatchQueue(label: "com.magicswitch.ble.conn.peripheral")
  ) {
    self.central = central
    self.peripheralManager = peripheralManager
    self.responseCharacteristic = responseCharacteristic
    self.queue = queue
    self.byteStreamBuffer = ByteStreamBuffer(queue: queue)
    super.init()
  }

  // MARK: - Incoming Byte Ingestion

  /// Called when new raw bytes arrive over the BLE link.
  func ingestIncomingData(_ data: Data) {
    byteStreamBuffer.append(data)
  }

  // MARK: - Session Control (Central Role)

  /// Sends session start control magic to the peripheral before exchanging stream frames.
  func startSession(completion: @escaping (Error?) -> Void) {
    queue.async {
      guard self.isConnected, self.peripheral != nil,
        self.commandCharacteristic != nil
      else {
        completion(BLETransportError.notConnected)
        return
      }
      let task = SendTask(chunks: [MagicSwitchBLE.sessionStartMagic], completion: completion)
      self.sendQueue.append(task)
      if !self.isSending {
        self.isSending = true
        self.sendNextCentralChunk()
      }
    }
  }

  // MARK: - TransportConnection Implementation

  func send(data: Data, completion: @escaping (Error?) -> Void) {
    queue.async {
      guard self.isConnected else {
        completion(BLETransportError.notConnected)
        return
      }

      if let peripheral = self.peripheral, let char = self.commandCharacteristic {
        self.sendAsCentral(
          data: data, peripheral: peripheral, characteristic: char, completion: completion)
      } else if let central = self.central, let manager = self.peripheralManager,
        let char = self.responseCharacteristic
      {
        self.sendAsPeripheral(
          data: data, central: central, manager: manager, characteristic: char,
          completion: completion)
      } else {
        completion(BLETransportError.notConnected)
      }
    }
  }

  func receive(exactByteCount count: Int, completion: @escaping (Result<Data, Error>) -> Void) {
    byteStreamBuffer.read(exact: count, completion: completion)
  }

  func cancel() {
    queue.async {
      guard !self.isCancelled else { return }
      self.isCancelled = true

      // Inform peripheral that session has ended so it can tear down immediately
      if let peripheral = self.peripheral, let char = self.commandCharacteristic,
        peripheral.state == .connected
      {
        peripheral.writeValue(MagicSwitchBLE.sessionEndMagic, for: char, type: .withoutResponse)
      }

      self.byteStreamBuffer.fail(error: SecureChannelError.connectionClosed)
      self.drainCentralQueue(error: BLETransportError.disconnected)
      self.drainPeripheralQueue(error: BLETransportError.disconnected)
      self.onCancel?()
    }
  }

  // MARK: - Central Sending (Chunked Write with Response Queue)

  private func sendAsCentral(
    data: Data,
    peripheral: CBPeripheral,
    characteristic: CBCharacteristic,
    completion: @escaping (Error?) -> Void
  ) {
    let limit = peripheral.maximumWriteValueLength(for: .withResponse)
    let maxChunk = (limit > 0) ? min(limit, 500) : 20
    var chunks: [Data] = []
    var offset = 0
    while offset < data.count {
      let length = min(maxChunk, data.count - offset)
      chunks.append(data.subdata(in: offset..<(offset + length)))
      offset += length
    }

    let task = SendTask(chunks: chunks, completion: completion)
    sendQueue.append(task)
    if !isSending {
      isSending = true
      sendNextCentralChunk()
    }
  }

  private func sendNextCentralChunk() {
    guard !isCancelled else {
      drainCentralQueue(error: BLETransportError.disconnected)
      return
    }

    guard let peripheral = peripheral, let char = commandCharacteristic else {
      drainCentralQueue(error: BLETransportError.disconnected)
      return
    }

    while !sendQueue.isEmpty {
      if sendQueue[0].chunks.isEmpty {
        let task = sendQueue.removeFirst()
        task.completion(nil)
        continue
      }

      let chunk = sendQueue[0].chunks.removeFirst()
      peripheral.writeValue(chunk, for: char, type: .withResponse)
      return
    }

    isSending = false
  }

  /// Called by the peripheral delegate when a chunk write completes.
  func handleDidWriteValue(error: Error?) {
    queue.async {
      if let error = error {
        self.drainCentralQueue(error: error)
        return
      }
      self.sendNextCentralChunk()
    }
  }

  private func drainCentralQueue(error: Error) {
    let tasks = sendQueue
    sendQueue.removeAll()
    isSending = false
    tasks.forEach { $0.completion(error) }
  }

  // MARK: - Peripheral Sending (Chunked Notification Queue)

  private func sendAsPeripheral(
    data: Data,
    central: CBCentral,
    manager: CBPeripheralManager,
    characteristic: CBMutableCharacteristic,
    completion: @escaping (Error?) -> Void
  ) {
    // BLE ATT baseline MTU payload limit is 20 bytes (23 ATT MTU - 3 byte header).
    // Characteristic notifications without MTU exchange fail in CoreBluetooth if chunk > 20.
    let maxChunk = 20
    var chunks: [Data] = []
    var offset = 0
    while offset < data.count {
      let length = min(maxChunk, data.count - offset)
      chunks.append(data.subdata(in: offset..<(offset + length)))
      offset += length
    }

    let task = SendTask(chunks: chunks, completion: completion)
    peripheralSendQueue.append(task)
    if !isPeripheralSending {
      isPeripheralSending = true
      sendNextPeripheralChunk()
    }
  }

  func sendNextPeripheralChunk() {
    queue.async {
      guard !self.isCancelled else {
        self.drainPeripheralQueue(error: BLETransportError.disconnected)
        return
      }

      guard let manager = self.peripheralManager, let char = self.responseCharacteristic else {
        self.drainPeripheralQueue(error: BLETransportError.notConnected)
        return
      }

      while !self.peripheralSendQueue.isEmpty {
        if self.peripheralSendQueue[0].chunks.isEmpty {
          let task = self.peripheralSendQueue.removeFirst()
          task.completion(nil)
          continue
        }

        let chunk = self.peripheralSendQueue[0].chunks[0]
        let sent = manager.updateValue(chunk, for: char, onSubscribedCentrals: nil)
        if sent {
          self.peripheralSendQueue[0].chunks.removeFirst()
        } else {
          // Transmit buffer full or central subscription still pending.
          // Retry automatically after a short interval or when peripheralManagerIsReady fires.
          self.queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.sendNextPeripheralChunk()
          }
          return
        }
      }

      self.isPeripheralSending = false
    }
  }

  private func drainPeripheralQueue(error: Error) {
    let tasks = peripheralSendQueue
    peripheralSendQueue.removeAll()
    isPeripheralSending = false
    tasks.forEach { $0.completion(error) }
  }

  /// Called when the peripheral manager's transmit queue has freed up.
  func handlePeripheralReady() {
    sendNextPeripheralChunk()
  }
}
