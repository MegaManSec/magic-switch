import ServiceManagement
import SwiftUI

/// View responsible for displaying and managing miscellaneous application settings
struct OtherSettingsView: View {
  // MARK: - Properties

  @Environment(\.openURL) private var openURL
  @ObservedObject private var updateChecker = UpdateChecker.shared
  @ObservedObject private var displayMonitor = DisplayMonitor.shared
  @State private var launchAtLogin: Bool = false
  @AppStorage(BluetoothPeripheralStore.releaseOnSleepDefaultsKey)
  private var releaseOnSleep: Bool = true
  @AppStorage(BluetoothPeripheralStore.autoReconnectDefaultsKey)
  private var autoReconnect: Bool = true

  // MARK: - View Content

  /// Form content containing setting options
  private var formContent: some View {
    Form {
      if #available(macOS 13.0, *) {
        Section {
          Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin, perform: setLaunchAtLogin)
            .help("Start Magic Switch automatically when you log in to this Mac.")
        }
      }
      Section {
        Toggle("Release peripherals when this Mac sleeps", isOn: $releaseOnSleep)
          .help(
            "When this Mac sleeps, hand its Magic peripherals back so your other Mac can take them. A sleeping Mac can't be asked to release them over the network, so Magic Switch releases them just before sleeping. Turn off to keep a peripheral bonded to this Mac while it sleeps."
          )
      }
      Section {
        Toggle("Reconnect peripherals if they drop", isOn: $autoReconnect)
          .help(
            "If a Magic peripheral that should be on this Mac drops — for example after closing the lid, or when you power-cycle a peripheral that got stuck — keep trying to reconnect it until it's back. When your other Mac goes to sleep or drops off the network, this Mac also adopts the peripherals it left behind. Magic Switch won't take a peripheral your other Mac is actively using."
          )
      }
      Section(
        header: Text("Take peripherals when a display connects")
          .help(
            "Displays connected to this Mac appear here. A display you mark acts as a docking trigger: whenever it connects to this Mac, Magic Switch switches your peripherals to this Mac automatically."
          )
      ) {
        if displayRows.isEmpty {
          Text("No external displays connected")
            .foregroundColor(.secondary)
            .help("Connect a display to this Mac and it will appear here.")
        } else {
          ForEach(displayRows) { row in
            displayToggle(for: row)
          }
        }
      }
      Section {
        SettingsRowView(
          title: "License Information",
          help: "Open the project license in your browser.",
          action: showLicenseInfo
        )
      }
      Section {
        if updateChecker.updateAvailable, let latest = updateChecker.latestVersion {
          SettingsRowView(
            title: "Update Available — v\(latest)",
            help:
              "A newer version of Magic Switch is available. Opens the release page in your browser.",
            action: openLatestRelease
          )
        }
        HStack {
          Text("Version")
          Spacer()
          Text(updateChecker.currentVersion)
            .foregroundColor(.secondary)
        }
        HStack {
          Button {
            updateChecker.checkNow()
          } label: {
            if updateChecker.isChecking {
              HStack(spacing: 6) {
                ProgressView()
                  .controlSize(.small)
                Text("Checking…")
              }
            } else {
              Text("Check for Updates")
            }
          }
          .disabled(updateChecker.isChecking)
          .help("Check GitHub for a newer release right now.")
          Spacer()
          updateStatus
        }
      }
    }
    .onAppear(perform: refreshOnAppear)
  }

  var body: some View {
    if #available(macOS 13.0, *) {
      formContent
        .formStyle(.grouped)
    } else {
      // Plain (non-grouped) Forms don't scroll on their own, and the tab now
      // holds more rows than the fixed Settings window shows at once.
      ScrollView {
        formContent
          .padding()
      }
    }
  }

  // MARK: - Display Trigger Rows

  /// A row in the display-trigger list: a connected external display, or one
  /// remembered as a trigger while disconnected.
  private struct DisplayRow: Identifiable {
    let id: String
    let name: String
    let isConnected: Bool
  }

  /// Connected external displays first (already name-sorted by the monitor),
  /// then remembered trigger displays that aren't currently connected —
  /// still labeled, still toggleable off.
  private var displayRows: [DisplayRow] {
    let connected = displayMonitor.connectedDisplays.map {
      DisplayRow(id: $0.id, name: $0.name, isConnected: true)
    }
    let connectedIDs = Set(connected.map { $0.id })
    let remembered = displayMonitor.triggerDisplays
      .filter { !connectedIDs.contains($0.key) }
      .map { DisplayRow(id: $0.key, name: $0.value, isConnected: false) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    return connected + remembered
  }

  @ViewBuilder
  private func displayToggle(for row: DisplayRow) -> some View {
    Toggle(isOn: triggerBinding(for: row)) {
      if row.isConnected {
        Text(row.name)
      } else {
        VStack(alignment: .leading, spacing: 2) {
          Text(row.name)
          Text("Not connected")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
    }
    .help(
      row.isConnected
        ? "When \(row.name) connects to this Mac — for example when you dock — automatically switch your Magic peripherals to this Mac, taking them from your other Mac if needed."
        : "\(row.name) isn't connected right now. It still triggers the switch when it next connects; turn off to forget it."
    )
  }

  private func triggerBinding(for row: DisplayRow) -> Binding<Bool> {
    Binding(
      get: { displayMonitor.triggerDisplays[row.id] != nil },
      set: { displayMonitor.setTriggerEnabled($0, id: row.id, name: row.name) }
    )
  }

  /// Trailing status beside the Check-for-Updates button. The "Update
  /// Available" row already covers the positive case, so this only reports a
  /// failed manual check or an up-to-date result.
  @ViewBuilder
  private var updateStatus: some View {
    if updateChecker.lastCheckFailed {
      Text("Couldn't check")
        .font(.caption)
        .foregroundColor(.red)
    } else if !updateChecker.isChecking, !updateChecker.updateAvailable,
      updateChecker.latestVersion != nil
    {
      Text("Up to date")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Private Methods

  private func showLicenseInfo() {
    guard let url = URL(string: "https://github.com/MegaManSec/magic-switch/blob/main/LICENSE")
    else { return }
    openURL(url)
  }

  private func openLatestRelease() {
    guard let url = updateChecker.releasePageURL else { return }
    openURL(url)
  }

  /// Refresh launch-at-login state and nudge the update check. `checkIfNeeded`
  /// respects the 24h cadence, so opening Settings rarely fires a real request.
  private func refreshOnAppear() {
    refreshLaunchAtLogin()
    updateChecker.checkIfNeeded()
  }

  private func refreshLaunchAtLogin() {
    if #available(macOS 13.0, *) {
      launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
  }

  @available(macOS 13.0, *)
  private func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      NSLog("Magic Switch: failed to update Launch at Login: \(error.localizedDescription)")
      launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
  }
}

// MARK: - Supporting Views

/// A reusable row component for settings items
private struct SettingsRowView: View {
  // MARK: - Properties

  let title: String
  let help: String
  let action: () -> Void

  // MARK: - View Content

  var body: some View {
    Button(action: action) {
      HStack {
        Text(title)
        Spacer()
        Image(systemName: "chevron.right")
          .foregroundColor(.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}

// MARK: - Preview

#Preview {
  OtherSettingsView()
}
