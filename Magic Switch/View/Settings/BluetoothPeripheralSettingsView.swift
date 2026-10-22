import SwiftUI

/// View responsible for managing Bluetooth peripheral device connections and settings
struct BluetoothPeripheralSettingsView: View {
  // MARK: - Dependencies

  @StateObject private var bluetoothStore = BluetoothPeripheralStore.shared

  // MARK: - State

  @State private var peripheralToRemove: BluetoothPeripheral?

  /// Polls live Bluetooth state while the tab is visible (see `handleOnAppear`).
  @State private var refreshTimer: Timer?

  // MARK: - View Content

  private var content: some View {
    Form {
      RegisteredPeripheralsSectionView(
        peripherals: bluetoothStore.peripherals,
        onPeripheralToggleConnection: handlePeripheralToggleConnection,
        onPeripheralRemoveRequest: { peripheralToRemove = $0 }
      )

      AvailablePeripheralsSectionView(
        peripherals: bluetoothStore.availablePeripherals,
        onPeripheralAdd: handlePeripheralAdd
      )
    }
    .onAppear(perform: handleOnAppear)
    .onDisappear(perform: stopRefreshTimer)
    .alert(item: $peripheralToRemove) { peripheral in
      Alert(
        title: Text("Remove \(peripheral.name)?"),
        message: Text(
          "It will be removed from Magic Switch's list. Bluetooth pairing with your Mac is not affected; you can add it again from Available Peripherals."
        ),
        primaryButton: .destructive(Text("Remove")) {
          bluetoothStore.removeFromList(peripheral)
        },
        secondaryButton: .cancel()
      )
    }
  }

  var body: some View {
    if #available(macOS 13.0, *) {
      content.formStyle(.grouped)
    } else {
      content
    }
  }

  // MARK: - Private Methods

  private func handlePeripheralToggleConnection(_ peripheral: BluetoothPeripheral) {
    switch bluetoothStore.connectionState(for: peripheral.id) {
    case .connected:
      // Symmetric to the disconnected case: release locally then ask the
      // peer to take it, so a "Send" actually hands the
      // peripheral over instead of leaving it floating.
      bluetoothStore.sendPeripheralToPeer(peripheral)
    case .disconnected:
      // Ask the peer to release first if it's holding the peripheral —
      // pairing locally without that step would just hang.
      bluetoothStore.takePeripheralFromPeer(peripheral)
    case .connecting, .releasing:
      break  // In flight; the button cancels (pairing) or is disabled (sending).
    }
  }

  private func handlePeripheralAdd(_ peripheral: BluetoothPeripheral) {
    bluetoothStore.addPeripheral(peripheral)
  }

  private func handleOnAppear() {
    bluetoothStore.fetchConnectedPeripherals()
    startRefreshTimer()
  }

  /// Re-snapshot Bluetooth every couple of seconds while this tab is on screen,
  /// so a device renamed in System Settings → Bluetooth updates here live (and
  /// connection states stay fresh) without having to switch tabs. The snapshot
  /// no-ops `@Published` state when nothing changed, and `.default`-mode timers
  /// don't fire while a menu is tracking, so an open type picker is undisturbed.
  private func startRefreshTimer() {
    refreshTimer?.invalidate()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
      BluetoothPeripheralStore.shared.fetchConnectedPeripherals()
    }
  }

  private func stopRefreshTimer() {
    refreshTimer?.invalidate()
    refreshTimer = nil
  }
}

// MARK: - Supporting Views

/// Section for displaying registered Bluetooth peripherals
private struct RegisteredPeripheralsSectionView: View {
  // MARK: - Properties

  let peripherals: [BluetoothPeripheral]
  let onPeripheralToggleConnection: (BluetoothPeripheral) -> Void
  let onPeripheralRemoveRequest: (BluetoothPeripheral) -> Void

  var body: some View {
    Section(header: Text("Registered Peripherals")) {
      if peripherals.isEmpty {
        Text(
          "Add a paired Bluetooth peripheral from \"Available Peripherals\" below to manage it from the menu bar."
        )
        .font(.callout)
        .foregroundColor(.secondary)
      } else {
        PeripheralListView(
          peripherals: peripherals,
          showConnectionStatus: true,
          primaryAction: onPeripheralToggleConnection,
          secondaryAction: onPeripheralRemoveRequest
        )
      }
    }
  }
}

/// Section for displaying available Bluetooth peripherals
private struct AvailablePeripheralsSectionView: View {
  let peripherals: [BluetoothPeripheral]
  let onPeripheralAdd: (BluetoothPeripheral) -> Void

  var body: some View {
    Section(header: Text("Available Peripherals")) {
      if peripherals.isEmpty {
        Text(
          "No Bluetooth peripherals to add. Pair a keyboard, mouse, or trackpad with this Mac in System Settings first."
        )
        .font(.callout)
        .foregroundColor(.secondary)
      } else {
        PeripheralListView(
          peripherals: peripherals,
          showConnectionStatus: false,
          primaryAction: onPeripheralAdd
        )
      }
    }
  }
}

/// List view for displaying Bluetooth peripherals
private struct PeripheralListView: View {
  let peripherals: [BluetoothPeripheral]
  let showConnectionStatus: Bool
  let primaryAction: (BluetoothPeripheral) -> Void
  var secondaryAction: ((BluetoothPeripheral) -> Void)?

  var body: some View {
    // Rows go straight into the enclosing Form Section — a nested List here
    // gives each row a taller default height than its content, which
    // top-aligns short rows (e.g. the icon-only Available row) instead of
    // centering them. Letting the Form own the row layout keeps content
    // vertically centered.
    ForEach(peripherals) { peripheral in
      PeripheralRowView(
        peripheral: peripheral,
        showConnectionStatus: showConnectionStatus,
        primaryAction: { primaryAction(peripheral) },
        secondaryAction: secondaryAction.map { action in
          { action(peripheral) }
        }
      )
    }
  }
}

/// Row view for displaying individual Bluetooth peripheral
private struct PeripheralRowView: View {
  let peripheral: BluetoothPeripheral
  let showConnectionStatus: Bool
  let primaryAction: () -> Void
  var secondaryAction: (() -> Void)?

  @ObservedObject private var store = BluetoothPeripheralStore.shared
  @ObservedObject private var networkStore = NetworkDeviceStore.shared

  private var connectionState: PeripheralConnectionState {
    store.connectionState(for: peripheral.id)
  }

  private var resolvedType: PeripheralType {
    store.peripheralType(for: peripheral)
  }

  /// Whether the other Mac can take a released peripheral: the same gate as
  /// the menu's peripheral rows, so Send is never offered where the menu
  /// greys the row out. Sending with no reachable peer would just disconnect
  /// the peripheral from both Macs.
  private var canSend: Bool {
    networkStore.networkDevices.contains { networkStore.isSwitchable($0) }
  }

  /// The peer this Mac hands peripherals to, for the "Sending to …" line.
  private var peerName: String? {
    networkStore.networkDevices.first?.name
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        typeMenu
        Text(peripheral.name)
        Spacer()
        // Published store state, not a direct registry read: the level often
        // appears in the registry a beat after `.connected`, and only a
        // `@Published` change re-renders this row when that happens. The
        // tab's 2s snapshot timer keeps it fresh from there.
        if showConnectionStatus, connectionState == .connected,
          let battery = store.batteryLevels[peripheral.id]
        {
          Text("\(battery)%")
            .font(.caption)
            .foregroundColor(.secondary)
            .help("Battery level of \(peripheral.name).")
        }
        if showConnectionStatus {
          connectionButton
          Button(action: { secondaryAction?() }) {
            Image(systemName: "minus.circle")
              .foregroundColor(.red)
          }
          .help("Remove this peripheral from Magic Switch's list.")
          .accessibilityLabel("Remove \(peripheral.name) from list")
        } else {
          Button(action: primaryAction) {
            Image(systemName: "plus.circle")
              .foregroundColor(.blue)
          }
          .help("Add this peripheral to Magic Switch's list.")
          .accessibilityLabel("Add \(peripheral.name) to list")
        }
      }

      // Name the destination Mac while a handoff is in flight — the button
      // only shows "Sending…", which doesn't say where it's going.
      if connectionState == .releasing {
        Text(
          peerName.map { String(localized: "Sending to \($0)…") }
            ?? String(localized: "Sending…")
        )
        .font(.caption)
        .foregroundColor(.secondary)
      }

      // Mirrors the dropdown's inline failure line. The store auto-fades the
      // message after 5s (and clears it on a fresh attempt), so this appears
      // and disappears on its own — no extra state to manage here.
      if let error = store.peripheralOperationError[peripheral.id] {
        Text(error)
          .font(.caption)
          .foregroundColor(.red)
      }
    }
  }

  /// Leading icon that doubles as a type picker. Shows the resolved glyph;
  /// tapping it overrides the auto-detected type (or resets to Automatic). The
  /// override is stored per address, so setting it on an Available peripheral
  /// carries over once it's added.
  private var typeMenu: some View {
    Menu {
      Button {
        store.setTypeOverride(nil, for: peripheral.id)
      } label: {
        Label("Automatic", systemImage: "wand.and.stars")
      }
      Divider()
      ForEach(PeripheralType.selectable, id: \.self) { type in
        Button {
          store.setTypeOverride(type, for: peripheral.id)
        } label: {
          Label(type.label, systemImage: type.symbolName)
        }
      }
    } label: {
      Text("")
    }
    .menuStyle(.borderlessButton)
    // Native menus ignore image-label frames. Keep the native arrow in a
    // fixed-width menu and draw the icon separately so its center stays fixed.
    .frame(width: 40)
    .overlay(alignment: .leading) {
      Image(systemName: resolvedType.symbolName)
        .font(.system(size: 15))
        .frame(width: 22)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .accessibilityLabel("Set the icon for \(peripheral.name)")
    .help("Set the icon for \(peripheral.name). Choose Automatic to detect it from the device.")
  }

  /// Shared fixed-width label so the pill is the same size across its
  /// resting states ("Send", "Take") instead of hugging each title, so rows
  /// align and a Send ↔ Take flip doesn't nudge. The floor clears "Pairing…"
  /// (51.9pt at the 13pt control font) with a couple of points of headroom
  /// against font-metric drift; sizing it to the rarely-seen "Sending…"
  /// instead would leave the two resting titles swimming in dead space, and
  /// the brief growth during a send reads as activity rather than jitter.
  private func actionLabel(_ title: String) -> some View {
    Text(title).frame(minWidth: 54)
  }

  @ViewBuilder
  private var connectionButton: some View {
    switch connectionState {
    case .connected:
      Button(action: primaryAction) {
        actionLabel(
          String(localized: "Send", comment: "Button: send this peripheral to the other Mac"))
      }
      .disabled(!canSend)
      .help(
        canSend
          ? String(
            localized:
              "Send this peripheral to the other Mac, which takes it over automatically."
          )
          : String(
            localized:
              "The other Mac isn't reachable to take this peripheral. Sending is disabled so it isn't left disconnected from both Macs."
          )
      )
    case .connecting:
      Button(action: { store.cancelConnect(peripheral) }) {
        actionLabel(String(localized: "Pairing…"))
      }
      .help("Pairing in progress. Click to cancel.")
    case .releasing:
      Button(action: {}) { actionLabel(String(localized: "Sending…")) }
        .disabled(true)
        .help("Sending this peripheral to the other Mac…")
    case .disconnected:
      Button(action: primaryAction) {
        actionLabel(String(localized: "Take", comment: "Button: take this peripheral to this Mac"))
      }
      .help(
        "Take this peripheral to this Mac. If the other Mac currently holds it, it will be asked to release it first."
      )
    }
  }
}

// MARK: - Preview

#Preview {
  BluetoothPeripheralSettingsView()
}
