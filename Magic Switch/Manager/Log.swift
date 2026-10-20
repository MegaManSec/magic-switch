import Foundation
import os

/// Unified-logging channels, one per area of the app. Messages are logged
/// `.public` so Console and `log show` output attached to a bug report show
/// them in full rather than as `<private>`.
enum Log {
  static let app = Channel(category: "app")
  static let bluetooth = Channel(category: "bluetooth")
  static let network = Channel(category: "network")

  struct Channel {
    private let logger: Logger

    init(category: String) {
      logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.megamansec.magic-switch",
        category: category)
    }

    func debug(_ message: String) {
      logger.debug("\(message, privacy: .public)")
    }

    func notice(_ message: String) {
      logger.notice("\(message, privacy: .public)")
    }

    func error(_ message: String) {
      logger.error("\(message, privacy: .public)")
    }
  }
}
