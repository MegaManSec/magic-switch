import Foundation
import Network

/// Represents the result of a health check operation
enum HealthCheckResult {
  case success
  case failure(String)
  case timeout
}

/// Protocol defining health check functionality for network devices
protocol HealthCheckable {
  func checkHealth(completion: @escaping (HealthCheckResult) -> Void)
}

extension NetworkDevice: HealthCheckable {
  func checkHealth(completion: @escaping (HealthCheckResult) -> Void) {
    let connection = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(integerLiteral: UInt16(port)),
      using: .tcp
    )
    let queue = DispatchQueue(label: "com.magicswitch.healthcheck")
    var fired = false

    // Serialised on `queue` (both the state handler and the timeout closure
    // run there), so `fired` is the only gate needed.
    func finish(_ result: HealthCheckResult) {
      guard !fired else { return }
      fired = true
      connection.stateUpdateHandler = nil
      connection.cancel()
      completion(result)
    }

    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        finish(.success)
      case .failed(let error):
        finish(.failure(error.localizedDescription))
      default:
        break
      }
    }

    connection.start(queue: queue)

    queue.asyncAfter(deadline: .now() + .seconds(5)) {
      finish(.timeout)
    }
  }
}
