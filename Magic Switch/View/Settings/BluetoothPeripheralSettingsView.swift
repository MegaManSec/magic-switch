import SwiftUI

/// View responsible for managing Bluetooth peripheral device connections and settings
struct BluetoothPeripheralSettingsView: View {
  // MARK: - Dependencies

  @StateObject private var bluetoothStore = BluetoothPeripheralStore.shared

  // MARK: - State

  @State private var peripheralToRemove: BluetoothPeripheral?

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
    case .connecting:
      break  // Pairing in flight; button is disabled in the UI.
    }
  }

  private func handlePeripheralAdd(_ peripheral: BluetoothPeripheral) {
    bluetoothStore.addPeripheral(peripheral)
  }

  private func handleOnAppear() {
    bluetoothStore.fetchConnectedPeripherals()
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
    List {
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
}

/// Row view for displaying individual Bluetooth peripheral
private struct PeripheralRowView: View {
  let peripheral: BluetoothPeripheral
  let showConnectionStatus: Bool
  let primaryAction: () -> Void
  var secondaryAction: (() -> Void)?

  @ObservedObject private var store = BluetoothPeripheralStore.shared

  private var connectionState: PeripheralConnectionState {
    store.connectionState(for: peripheral.id)
  }

  var body: some View {
    HStack {
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
  }

  @ViewBuilder
  private var connectionButton: some View {
    switch connectionState {
    case .connected:
      Button("Disconnect", action: primaryAction)
        .help(
          "Release this peripheral from this Mac. If a peer Mac is paired, it'll take ownership automatically."
        )
    case .connecting:
      Button("Pairing…", action: {})
        .disabled(true)
        .help("Pairing in progress…")
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
