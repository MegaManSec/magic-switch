import ServiceManagement
import SwiftUI

/// View responsible for displaying and managing miscellaneous application settings
struct OtherSettingsView: View {
  // MARK: - Properties

  @Environment(\.openURL) private var openURL
  @ObservedObject private var updateChecker = UpdateChecker.shared
  @ObservedObject private var displayMonitor = DisplayMonitor.shared
  @ObservedObject private var hotkey = HotkeyManager.shared
  @State private var launchAtLogin: Bool = false
  @State private var notificationsDenied: Bool = false
  @AppStorage(BluetoothPeripheralStore.releaseOnSleepDefaultsKey)
  private var releaseOnSleep: Bool = true
  @AppStorage(BluetoothPeripheralStore.autoReconnectDefaultsKey)
  private var autoReconnect: Bool = true

  // MARK: - View Content

  /// Form content containing setting options
  private var formContent: some View {
    Form {
      if notificationsDenied {
        Section {
          // Failure feedback (cancelled switches, identity mismatches) only
          // arrives via notifications, so a denied permission means silent
          // failures — worth flagging where the user can act on it.
          Label(
            "Notifications are off, so you won't hear when a switch fails. Enable them for Magic Switch in System Settings → Notifications.",
            systemImage: "bell.slash"
          )
          .font(.callout)
          .foregroundColor(.secondary)
        }
      }
      if #available(macOS 13.0, *) {
        Section(header: Text("General")) {
          Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin, perform: setLaunchAtLogin)
            .help("Start Magic Switch automatically when you log in to this Mac.")
        }
      }
      Section(header: Text("Peripheral handling")) {
        Toggle("Release peripherals when this Mac sleeps", isOn: $releaseOnSleep)
          .help(
            "When this Mac sleeps, hand its Magic peripherals back so your other Mac can take them. A sleeping Mac can't be asked to release them over the network, so Magic Switch releases them just before sleeping. Turn off to keep a peripheral bonded to this Mac while it sleeps."
          )
        Toggle("Reconnect peripherals if they drop", isOn: $autoReconnect)
          .help(
            "If a Magic peripheral that should be on this Mac drops — for example after closing the lid, or when you power-cycle a peripheral that got stuck — keep trying to reconnect it until it's back. When your other Mac goes to sleep or drops off the network, this Mac also adopts the peripherals it left behind. Magic Switch won't take a peripheral your other Mac is actively using."
          )
      }
      Section(header: Text("Keyboard shortcuts")) {
        ShortcutRecorderRow(
          direction: .send,
          title: "Send peripherals to the other Mac",
          help:
            "Press anywhere in macOS to hand every registered peripheral to the other Mac. Pressing it again once they're there does nothing."
        )
        ShortcutRecorderRow(
          direction: .take,
          title: "Take peripherals to this Mac",
          help:
            "Press anywhere in macOS to bring every registered peripheral to this Mac — it works even while the other Mac is asleep. Pressing it again once they're here does nothing."
        )
        ShortcutRecorderRow(
          direction: .toggle,
          title: "Toggle peripherals between Macs",
          help:
            "Press anywhere in macOS to move the peripherals to whichever Mac doesn't have them — exactly like clicking the other Mac in the menu. Note that pressing it twice moves them there and back."
        )
      }
      Section {
        if displayRows.isEmpty {
          Text("No external displays connected")
            .foregroundColor(.secondary)
            .help("Connect a display to this Mac and it will appear here.")
        } else {
          ForEach(displayRows) { row in
            displayRow(for: row)
          }
        }
      } header: {
        HStack {
          Text("Take peripherals when a display connects")
            .help(
              "Displays connected to this Mac appear here. A display you mark acts as a docking trigger: whenever it connects to this Mac, Magic Switch switches your peripherals to this Mac automatically."
            )
          Spacer()
          Button(action: { displayMonitor.refreshNow() }) {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help("Re-scan the displays connected to this Mac.")
          .accessibilityLabel("Refresh connected displays")
        }
      }
      Section(header: Text("About")) {
        SettingsRowView(
          title: "License Information",
          help: "Open the project license in your browser.",
          action: showLicenseInfo
        )
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
    .onDisappear { hotkey.cancelRecording() }
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
  /// still labeled, removable with their trash button.
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

  /// A connected display gets the trigger toggle; a remembered-but-
  /// disconnected one gets a trash button instead — with nothing to toggle
  /// *to* (unmarking is forgetting; the trigger map is the only memory),
  /// a toggle would just be a remove control in disguise.
  @ViewBuilder
  private func displayRow(for row: DisplayRow) -> some View {
    if row.isConnected {
      Toggle(row.name, isOn: triggerBinding(for: row))
        .help(
          "When \(row.name) connects to this Mac — for example when you dock — automatically switch your Magic peripherals to this Mac, taking them from your other Mac if needed. Display ID: \(row.id)."
        )
    } else {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(row.name)
          Text("Not connected")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .help(
          "\(row.name) isn't connected right now. It still triggers the switch when it next connects. Display ID: \(row.id)."
        )
        Spacer()
        Button(action: { displayMonitor.setTriggerEnabled(false, id: row.id, name: row.name) }) {
          Image(systemName: "trash")
            .foregroundColor(.red)
        }
        .help("Forget \(row.name) — it will no longer trigger a switch when it connects.")
        .accessibilityLabel("Forget \(row.name)")
      }
    }
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

  /// Refresh launch-at-login state, the display list, and nudge the update
  /// check. `checkIfNeeded` respects the 24h cadence, so opening Settings
  /// rarely fires a real request.
  private func refreshOnAppear() {
    refreshLaunchAtLogin()
    displayMonitor.refreshNow()
    updateChecker.checkIfNeeded()
    NotificationManager.checkAuthorizationDenied { notificationsDenied = $0 }
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

/// One row of the Keyboard shortcuts section: the action's name, a recorder
/// button showing the current chord (or the record/recording prompt), and a
/// clear button while a chord is set. Recording state lives in
/// `HotkeyManager` so only one row can record at a time.
private struct ShortcutRecorderRow: View {
  let direction: SwitchDirection
  let title: String
  let help: String

  @ObservedObject private var hotkey = HotkeyManager.shared

  private var isRecording: Bool { hotkey.recordingDirection == direction }
  private var shortcut: HotkeyShortcut? { hotkey.shortcuts[direction] }

  private var buttonTitle: String {
    if isRecording { return "Type Shortcut…" }
    return shortcut?.displayString ?? "Record Shortcut"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        // Clear button sits left of the recorder so the recorder buttons
        // stay pinned to the trailing edge whether or not it's visible.
        if shortcut != nil, !isRecording {
          Button(action: { hotkey.setShortcut(nil, for: direction) }) {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.secondary)
          }
          .buttonStyle(.borderless)
          .help("Remove this shortcut.")
          .accessibilityLabel("Remove shortcut: \(title)")
        }
        Button(action: toggleRecording) {
          // Fixed-width label so the three recorder buttons form an aligned
          // column no matter what each one currently displays.
          Text(buttonTitle)
            .frame(width: 130)
        }
        .help(help)
      }
      if isRecording {
        Text("Press a key with ⌘, ⌥, or ⌃. Esc cancels; ⌫ removes the shortcut.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
  }

  private func toggleRecording() {
    if isRecording {
      hotkey.cancelRecording()
    } else {
      hotkey.startRecording(for: direction)
    }
  }
}

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
