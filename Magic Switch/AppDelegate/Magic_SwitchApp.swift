import SwiftUI

/// Main application entry point and configuration
@main
struct Magic_SwitchApp: App {
  // MARK: - Dependencies

  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  // MARK: - Scene Configuration

  /// This `Settings` scene exists only because `App.body` requires at least
  /// one `Scene`. It is intentionally unreachable: the SwiftUI
  /// `Settings { ... }` + `NSApp.sendAction(showSettingsWindow:)` path
  /// silently fails to produce a visible window in this LSUIElement +
  /// `.accessory` configuration. `AppDelegate.openSettingsWindow` hosts
  /// `SettingsView` in a manually-built `NSWindow` instead. Do not route
  /// back through this scene without re-reading that comment first.
  var body: some Scene {
    Settings {
      SettingsView()
    }
  }
}
