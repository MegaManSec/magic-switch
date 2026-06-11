import ServiceManagement
import SwiftUI

/// View responsible for displaying and managing miscellaneous application settings
struct OtherSettingsView: View {
  // MARK: - Properties

  @Environment(\.openURL) private var openURL
  @ObservedObject private var updateChecker = UpdateChecker.shared
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
      formContent
        .padding()
    }
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
