import Combine
import Foundation
import Network

/// Protocol defining the interface for network service publishing
protocol NetworkNetworkServicePublishable {
  /// Starts publishing the network service
  func startPublishing()

  /// Stops publishing the network service
  func stopPublishing()
}

/// Manages the publication of network services for device discovery
final class ServicePublisher: NSObject, NetworkNetworkServicePublishable {
  // MARK: - Constants

  private let serviceType = "_blueswitch._tcp."
  private let serviceDomain = "local."

  // MARK: - Dependencies

  private let rateLimiter = RateLimiter()
  private let pairingStore = PairingStore.shared

  // MARK: - Properties

  private var listener: NWListener?
  private var netService: NetService?
  private let queue = DispatchQueue(label: "com.blueswitch.service.publisher")
  private var fingerprintObserver: AnyCancellable?

  // MARK: - NetworkNetworkServicePublishable Implementation

  func startPublishing() {
    setupListener()
  }

  func stopPublishing() {
    listener?.cancel()
    netService?.stop()
    netService = nil
  }

  // MARK: - Private Setup Methods

  /// Sets up the network listener with appropriate configuration and handlers
  private func setupListener() {
    do {
      listener = try NWListener(using: .tcp)
      configureListener()
    } catch {
      handleListenerError(error)
    }
  }

  /// Configures the listener with state and connection handlers
  private func configureListener() {
    listener?.stateUpdateHandler = { [weak self] newState in
      self?.handleListenerState(newState)
    }

    listener?.newConnectionHandler = { [weak self] newConnection in
      self?.handleNewConnection(newConnection)
    }

    listener?.start(queue: queue)
  }

  // MARK: - Private Event Handling Methods

  /// Handles updates to the listener's state
  private func handleListenerState(_ state: NWListener.State) {
    switch state {
    case .ready:
      if let port = listener?.port?.rawValue {
        print("Listener ready: Port \(port)")
        publishService(port: Int(port))
      }
    case .failed(let error):
      print("Listener error: \(error)")
    case .cancelled:
      print("Listener was cancelled")
    default:
      break
    }
  }

  /// Processes new incoming connections
  private func handleNewConnection(_ connection: NWConnection) {
    let handler = IncomingConnection(
      connection: connection,
      endpoint: connection.endpoint,
      rateLimiter: rateLimiter,
      pairingStore: pairingStore,
      queue: queue
    )
    handler.start()
  }

  /// Handles errors that occur during listener setup
  private func handleListenerError(_ error: Error) {
    print("Failed to create listener: \(error)")
  }

  /// Publishes the service with the specified port
  private func publishService(port: Int) {
    let service = NetService(
      domain: serviceDomain,
      type: serviceType,
      name: Host.current().localizedName ?? "Unknown",
      port: Int32(port))

    service.delegate = self
    netService = service
    refreshTXTRecord()
    service.publish()

    // Republish the TXT record whenever the local fingerprint changes, so
    // peers can detect a re-pair (and re-pin on the new fingerprint).
    fingerprintObserver = pairingStore.$fingerprint
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.refreshTXTRecord()
      }
  }

  /// Writes a TXT record carrying the local PSK fingerprint (when paired).
  /// Receivers use this for TOFU identity pinning, so an attacker that
  /// publishes a colliding Bonjour name can't redirect commands without
  /// also knowing the PSK.
  private func refreshTXTRecord() {
    var record: [String: Data] = [:]
    if let fp = pairingStore.fingerprint {
      record["fp"] = Data(fp.utf8)
    }
    let data = NetService.data(fromTXTRecord: record)
    netService?.setTXTRecord(data)
  }
}

// MARK: - NetServiceDelegate

extension ServicePublisher: NetServiceDelegate {
  func netServiceDidPublish(_ sender: NetService) {
    print("Service published successfully: \(sender.name)")
  }

  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    print("Failed to publish service: \(errorDict)")
  }
}
