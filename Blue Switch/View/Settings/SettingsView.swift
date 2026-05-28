import SwiftUI

/// Main settings view that handles all application configuration through tab-based navigation
struct SettingsView: View {
  // MARK: - Types

  /// Constants for tab items configuration
  private enum TabItem {
    /// Configuration for each tab
    static let devices = (image: "keyboard", text: "Peripheral")
    static let mac = (image: "desktopcomputer", text: "Device")
    static let pairing = (image: "lock.shield", text: "Pairing")
    static let other = (image: "ellipsis.circle", text: "Other")
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
        }
        .help("Manage Bluetooth peripherals (keyboards, mice) to switch between Macs.")
        .tag(0)

      NetworkDeviceManagementView()
        .tabItem {
          Label(TabItem.mac.text, systemImage: TabItem.mac.image)
        }
        .help("Manage the other Macs on your network.")
        .tag(1)

      PairingSettingsView()
        .tabItem {
          Label(TabItem.pairing.text, systemImage: TabItem.pairing.image)
        }
        .help("Set up the pairing key between this Mac and your other Mac.")
        .tag(2)

      OtherSettingsView()
        .tabItem {
          Label(TabItem.other.text, systemImage: TabItem.other.image)
        }
        .help("License and other settings.")
        .tag(3)
    }
    .frame(width: windowSize.width, height: windowSize.height)
  }
}

// MARK: - Preview

#Preview {
  SettingsView()
}
