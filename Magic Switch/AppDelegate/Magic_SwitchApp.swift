import SwiftUI

/// Main application entry point and configuration
@main
struct Magic_SwitchApp: App {
  // MARK: - Dependencies

  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  // MARK: - Scene Configuration

  var body: some Scene {
    Settings {
      SettingsView()
    }
  }
}
