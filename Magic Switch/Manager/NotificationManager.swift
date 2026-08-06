import UserNotifications

/// Protocol defining the interface for managing system notifications
protocol NotificationManaging {
  /// Checks current authorization status and requests if needed
  static func requestAuthorizationIfNeeded()

  /// Requests notification authorization from the user
  static func requestAuthorization()

  /// Displays a notification with the specified title and body
  /// - Parameters:
  ///   - title: The notification title
  ///   - body: The notification message
  ///   - identifier: Optional stable identifier. Re-posting with the same
  ///     identifier replaces the previous notification rather than stacking,
  ///     so rapid retries coalesce instead of flooding Notification Centre.
  static func showNotification(title: String, body: String, identifier: String?)
}

final class NotificationManager: NotificationManaging {
  // MARK: - Types & Constants

  private enum Constants {
    static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound, .badge]
  }

  // MARK: - Public Methods

  static func requestAuthorizationIfNeeded() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      switch settings.authorizationStatus {
      case .notDetermined:
        requestAuthorization()
      case .denied:
        print("User has denied notifications")
      case .authorized, .provisional, .ephemeral:
        print("Notifications are authorized")
      @unknown default:
        print("Unknown notification authorization status")
      }
    }
  }

  /// Calls back on the main queue with whether the user has explicitly denied
  /// notifications. Settings → Other uses this to explain that failed
  /// handoffs and identity warnings would otherwise be silent.
  static func checkAuthorizationDenied(_ completion: @escaping (Bool) -> Void) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        completion(settings.authorizationStatus == .denied)
      }
    }
  }

  static func requestAuthorization() {
    UNUserNotificationCenter.current().requestAuthorization(
      options: Constants.authorizationOptions
    ) { granted, error in
      if let error = error {
        print("Failed to request notification authorization: \(error)")
        return
      }
      print("Notification authorization was \(granted ? "granted" : "denied")")
    }
  }

  /// Removes a delivered (and any pending) notification posted under
  /// `identifier` — for stable-identifier alerts whose condition has since
  /// cleared.
  static func removeNotification(identifier: String) {
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
  }

  static func showNotification(title: String, body: String, identifier: String? = nil) {
    let content = createNotificationContent(title: title, body: body)
    let request = UNNotificationRequest(
      identifier: identifier ?? UUID().uuidString,
      content: content,
      trigger: nil
    )

    UNUserNotificationCenter.current().add(request) { error in
      if let error = error {
        print("Failed to show notification: \(error)")
      }
    }
  }

  // MARK: - Private Methods

  private static func createNotificationContent(title: String, body: String)
    -> UNMutableNotificationContent
  {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    return content
  }
}
