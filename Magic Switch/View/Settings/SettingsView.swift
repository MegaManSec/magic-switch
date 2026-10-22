import SwiftUI

/// Main settings view that handles all application configuration through tab-based navigation
struct SettingsView: View {
  // MARK: - Types

  /// Constants for tab items configuration
  private enum TabItem {
    /// Configuration for each tab
    static let devices = (image: "keyboard", text: String(localized: "Peripherals"))
    static let mac = (image: "desktopcomputer", text: String(localized: "Macs"))
    static let pairing = (image: "lock.shield", text: String(localized: "Pairing"))
    static let other = (
      image: "ellipsis.circle",
      text: String(
        localized: "Other", comment: "Settings tab title: other settings (plural noun phrase)")
    )
  }

  // MARK: - Properties

  /// Window dimensions for the settings view
  private let windowSize = CGSize(width: 600, height: 400)

  /// Persisted across launches so reopening Settings returns to the same tab.
  @AppStorage("settings-selected-tab") private var selectedTab: Int = 0

  // MARK: - View Content

  var body: some View {
    TabView(selection: $selectedTab) {
      BluetoothPeripheralSettingsView()
        .tabItem {
          Label(TabItem.devices.text, systemImage: TabItem.devices.image)
            .help("Choose which Bluetooth peripherals Magic Switch manages.")
        }
        .tag(0)

      NetworkDeviceManagementView()
        .tabItem {
          Label(TabItem.mac.text, systemImage: TabItem.mac.image)
            .help("The other Mac you switch peripherals with.")
        }
        .tag(1)

      PairingSettingsView()
        .tabItem {
          Label(TabItem.pairing.text, systemImage: TabItem.pairing.image)
            .help(
              "Link this Mac to your other Mac. Separate from Bluetooth pairing in System Settings."
            )
        }
        .tag(2)

      OtherSettingsView()
        .tabItem {
          Label(TabItem.other.text, systemImage: TabItem.other.image)
            .help("Startup, peripheral handling, shortcuts, display triggers, and updates.")
        }
        .tag(3)
    }
    .frame(width: windowSize.width, height: windowSize.height)
  }
}

// MARK: - Preview

#Preview {
  SettingsView()
}
