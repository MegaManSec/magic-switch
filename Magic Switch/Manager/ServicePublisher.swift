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

  private let serviceType = "_magicswitch._tcp."
  private let serviceDomain = "local."
  /// Fixed rather than ephemeral so endpoints learned outside Bonjour
  /// survive a relaunch. Unassigned, below the ephemeral range; falls back
  /// to ephemeral if taken (INTRODUCE propagates the actual bound port).
  static let defaultPort: UInt16 = 41952

  // MARK: - Dependencies

  private let rateLimiter = RateLimiter()
  private let pairingStore = PairingStore.shared

  // MARK: - Properties

  private var listener: NWListener?
  private var netService: NetService?
  private let queue = DispatchQueue(label: "com.magicswitch.service.publisher")
  private var fingerprintObserver: AnyCancellable?
  private var usingFixedPort = false
  /// Queue-confined, like `advertisedName`.
  private var boundPort: UInt16?
  private var advertisedName: String?
  /// Clears inbound rate-limit blocks when the pairing key changes — see
  /// `RateLimiter.reset()`. Lifetime-long, unlike `fingerprintObserver`.
  private var repairObserver: AnyCancellable?

  // MARK: - Initialization

  override init() {
    super.init()
    repairObserver = pairingStore.$fingerprint
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.rateLimiter.reset() }
  }

  // MARK: - NetworkNetworkServicePublishable Implementation

  func startPublishing() {
    // On `queue`: the listener state machine owns `listener`/`boundPort`/
    // `advertisedName` there, so start, stop, and the relisten never race.
    queue.async { self.setupListener() }
  }

  func stopPublishing() {
    queue.async {
      self.listener?.cancel()
      // nil so a pending relisten (see the `.failed` case) can't resurrect
      // it — serialized here, so the relisten guard can't race this check.
      self.listener = nil
      self.boundPort = nil
      self.advertisedName = nil
    }
    DispatchQueue.main.async {
      self.fingerprintObserver = nil
      self.netService?.stop()
      self.netService = nil
    }
  }

  // MARK: - Private Setup Methods

  /// Sets up the network listener with appropriate configuration and handlers
  private func setupListener() {
    startListener(on: Self.defaultPort)
  }

  /// Starts a listener on `port`, or an ephemeral one when nil.
  private func startListener(on port: UInt16?) {
    usingFixedPort = port != nil
    let parameters = NWParameters.tcp
    // Without reuse, TIME_WAIT from a previous run blocks the re-bind.
    parameters.allowLocalEndpointReuse = true
    do {
      if let port = port {
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
      } else {
        listener = try NWListener(using: parameters)
      }
      configureListener()
    } catch {
      if port != nil {
        startListener(on: nil)
      } else {
        handleListenerError(error)
      }
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
        boundPort = port
        // NetService needs a run loop for its delegate callbacks; this
        // handler's dispatch queue has none.
        DispatchQueue.main.async { self.publishService(port: Int(port)) }
      }
    case .failed(let error):
      print("Listener error: \(error)")
      listener?.cancel()
      if boundPort != nil {
        // Died after ready. Clear the port so INTRODUCE stops asserting a
        // dead endpoint, then relisten — unless something else replaced this
        // listener while the delay ran.
        boundPort = nil
        // Withdraw the advertisement too. Enqueued to main from this serial
        // queue, so it always lands *after* any still-pending publish hop
        // from `.ready` — a dead-port ad can't outlive this failure even if
        // the relisten never succeeds.
        DispatchQueue.main.async {
          self.netService?.stop()
          self.netService = nil
        }
        // Bind non-optionally: with a nil `listener` (a stopPublishing race)
        // the identity check would pass vacuously and resurrect it.
        if let failed = listener {
          queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, self.listener === failed else { return }
            self.setupListener()
          }
        }
      } else if usingFixedPort {
        // A busy fixed port fails here at start(), not as an init throw.
        startListener(on: nil)
      }
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
      queue: queue,
      // Already on `queue`; `currentIdentity()`'s sync hop would deadlock.
      localIdentity: { [weak self] in self?.identityOnQueue() }
    )
    handler.start()
  }

  /// This Mac's INTRODUCE identity. Thread-safe; nil until the listener is
  /// ready.
  func currentIdentity() -> IntroducedIdentity? {
    queue.sync { identityOnQueue() }
  }

  private func identityOnQueue() -> IntroducedIdentity? {
    guard let port = boundPort else { return nil }
    return IntroducedIdentity(
      name: advertisedName ?? Host.current().localizedName ?? "Unknown",
      port: port
    )
  }

  /// Handles errors that occur during listener setup
  private func handleListenerError(_ error: Error) {
    print("Failed to create listener: \(error)")
  }

  /// Publishes the service with the specified port
  private func publishService(port: Int) {
    // A relisten republish must withdraw the previous registration first.
    netService?.stop()
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
    // mDNS renames on collision; INTRODUCE identities must match the air.
    let name = sender.name
    queue.async { self.advertisedName = name }
    AdvertisingDiagnostics.shared.servicePublished(name: name)
  }

  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    print("Failed to publish service: \(errorDict)")
    AdvertisingDiagnostics.shared.servicePublishFailed()
  }
}
