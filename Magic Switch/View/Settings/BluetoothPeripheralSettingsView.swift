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
      // peer to take it, so a "Remove from PC" actually hands the
      // peripheral over instead of leaving it floating.
      bluetoothStore.sendPeripheralToPeer(peripheral)
    case .disconnected:
      // Ask the peer to release first if it's holding the peripheral —
      // pairing locally without that step would just hang.
      bluetoothStore.takePeripheralFromPeer(peripheral)
    case .connecting, .releasing:
      break  // Handoff in flight; button is disabled in the UI.
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

  /// Whether a paired peer Mac is currently reachable to take a released
  /// peripheral. Releasing with no active peer just disconnects the peripheral
  /// from both Macs, so the Release button is disabled until a peer is present.
  /// Matches the handoff gate used elsewhere (e.g. `prepareForSleep`).
  private var hasActivePeer: Bool {
    networkStore.networkDevices.contains { $0.isActive }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        typeMenu
        Text(peripheral.name)
        Spacer()
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
      Image(systemName: resolvedType.symbolName)
        .frame(width: 22)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Set the icon for \(peripheral.name). Choose Automatic to detect it from the device.")
  }

  @ViewBuilder
  private var connectionButton: some View {
    switch connectionState {
    case .connected:
      Button("Release", action: primaryAction)
        .disabled(!hasActivePeer)
        .help(
          hasActivePeer
            ? "Release this peripheral from this Mac. The peer Mac will take ownership automatically."
            : "No peer Mac is currently available to take this peripheral. Releasing is disabled so it isn't left disconnected from both Macs."
        )
    case .connecting:
      Button("Pairing…", action: {})
        .disabled(true)
        .help("Pairing in progress…")
    case .releasing:
      Button("Releasing…", action: {})
        .disabled(true)
        .help("Handing this peripheral to the other Mac…")
    case .disconnected:
      Button("Connect", action: primaryAction)
        .help(
          "Connect this peripheral to this Mac. If a peer Mac currently holds it, the peer will be asked to release it first."
        )
    }
  }
}

// MARK: - Preview

#Preview {
  BluetoothPeripheralSettingsView()
}
