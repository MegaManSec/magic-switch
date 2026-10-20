import Foundation

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
  /// Require an authenticated command reply before declaring the peer healthy.
  /// A TCP-only probe closes before the handshake, producing a misleading
  /// `Handshake failed: connectionClosed` error on the receiving Mac.
  func checkHealth(completion: @escaping (HealthCheckResult) -> Void) {
    NetworkDeviceStore.shared.executeCommand(.ping, on: self) { result in
      switch result {
      case .success:
        completion(.success)
      case .failure(.connectTimeout), .failure(.handshakeFailed(.handshakeTimeout)):
        completion(.timeout)
      case .failure(let error):
        completion(.failure(error.userMessage))
      }
    }
  }
}
