import SwiftUI

private enum Constants {
  enum Strings {
    static let connectedDevices = "Connected Devices"
    static let availableDevices = "Available Devices"
    static let noConnectedDevicesHint =
      "Add another Mac from \"Available Devices\" below to start switching peripherals between them."
    static let noAvailableDevicesHint =
      "Make sure Blue Switch is running on your other Mac and both Macs are on the same Wi-Fi network. Then tap Refresh."
    static let connectionLimitMessage =
      "Only one device can be connected at a time. Remove the existing device first."
    static let notify = "Notify"
    static let add = "Add"
  }
}

/// View for managing network device connections and registrations
struct NetworkDeviceManagementView: View {
  // MARK: - Dependencies

  @ObservedObject private var networkStore = NetworkDeviceStore.shared

  // MARK: - State

  @State private var deviceToRemove: NetworkDevice?

  // MARK: - View Content

  private var formContent: some View {
    Form {
      RegisteredDevicesSectionView(
        devices: networkStore.networkDevices,
        onDeviceNotify: handleDeviceNotification,
        onDeviceRemoveRequest: { deviceToRemove = $0 },
        onTrustPending: handleTrustPending
      )

      AvailableDevicesSectionView(
        devices: networkStore.availableNetworkDevices,
        onDeviceRegister: handleDeviceRegistration
      )
    }
    .alert(item: $deviceToRemove) { device in
      Alert(
        title: Text("Remove \(device.name)?"),
        message: Text(
          "It will be removed from your registered list. You can add it again from Available Devices."
        ),
        primaryButton: .destructive(Text("Remove")) {
          networkStore.removeNetworkDevice(device: device)
        },
        secondaryButton: .cancel()
      )
    }
  }

  // MARK: - Tooltips

  fileprivate enum Help {
    static let notify = "Send a test notification to this Mac."
    static let add = "Add this Mac to your registered list."
    static let sync = "Send your peripheral list to this Mac so it knows about them."
    static let remove = "Remove this Mac from the registered list."
    static let refresh = "Re-scan the network for other Macs running Blue Switch."
    static let trust =
      "Pin the new pairing key. Only do this if you intentionally re-paired the other Mac."
    static let needsPairing = "Pair this Mac in the Pairing tab first."
  }

  var body: some View {
    if #available(macOS 13.0, *) {
      formContent
        .formStyle(.grouped)
    } else {
      formContent
    }
  }

  // MARK: - Private Methods

  private func handleDeviceNotification(_ device: NetworkDevice) {
    networkStore.sendNotification(to: device)
  }

  private func handleDeviceRegistration(_ device: NetworkDevice) {
    networkStore.registerNetworkDevice(device: device)
  }

  private func handleTrustPending(_ device: NetworkDevice) {
    networkStore.trustPendingFingerprint(for: device.id)
  }
}

// MARK: - Supporting Views

private struct RegisteredDevicesSectionView: View {
  // MARK: - Dependencies
  @ObservedObject private var bluetoothStore = BluetoothPeripheralStore.shared
  @ObservedObject private var networkStore = NetworkDeviceStore.shared

  // MARK: - Properties
  let devices: [NetworkDevice]
  let onDeviceNotify: (NetworkDevice) -> Void
  let onDeviceRemoveRequest: (NetworkDevice) -> Void
  let onTrustPending: (NetworkDevice) -> Void

  var body: some View {
    Section {
      if devices.isEmpty {
        Text(Constants.Strings.noConnectedDevicesHint)
          .font(.callout)
          .foregroundColor(.secondary)
      } else {
        NetworkDeviceListView(
          devices: devices,
          buttonTitle: Constants.Strings.notify,
          actionHelp: NetworkDeviceManagementView.Help.notify,
          requiresPairing: true,
          action: onDeviceNotify,
          onDelete: onDeviceRemoveRequest,
          onSyncPeripherals: { device in
            networkStore.sendPeripheralSync(
              peripherals: bluetoothStore.peripherals,
              to: device
            )
          },
          onTrustPending: onTrustPending
        )
      }
    } header: {
      Text(Constants.Strings.connectedDevices)
        .font(.headline)
    }
  }
}

private struct AvailableDevicesSectionView: View {
  // MARK: - Dependencies

  @ObservedObject private var networkStore = NetworkDeviceStore.shared

  // MARK: - Properties

  let devices: [NetworkDevice]
  let onDeviceRegister: (NetworkDevice) -> Void

  var body: some View {
    Section {
      if !networkStore.networkDevices.isEmpty {
        Text(Constants.Strings.connectionLimitMessage)
          .foregroundColor(.secondary)
      } else if devices.isEmpty {
        Text(Constants.Strings.noAvailableDevicesHint)
          .font(.callout)
          .foregroundColor(.secondary)
      } else {
        NetworkDeviceListView(
          devices: devices,
          buttonTitle: Constants.Strings.add,
          actionHelp: NetworkDeviceManagementView.Help.add,
          action: onDeviceRegister
        )
      }
    } header: {
      HStack {
        Text(Constants.Strings.availableDevices)
          .font(.headline)
        Spacer()
        Button(action: { networkStore.refreshDiscovery() }) {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help(NetworkDeviceManagementView.Help.refresh)
        .accessibilityLabel("Refresh available devices")
      }
    }
  }
}

private struct NetworkDeviceListView: View {
  // MARK: - Properties

  let devices: [NetworkDevice]
  let buttonTitle: String
  let actionHelp: String
  let requiresPairing: Bool
  let action: (NetworkDevice) -> Void
  let onDelete: ((NetworkDevice) -> Void)?
  let onSyncPeripherals: ((NetworkDevice) -> Void)?
  let onTrustPending: ((NetworkDevice) -> Void)?

  @ObservedObject private var pairing = PairingStore.shared

  init(
    devices: [NetworkDevice],
    buttonTitle: String,
    actionHelp: String,
    requiresPairing: Bool = false,
    action: @escaping (NetworkDevice) -> Void,
    onDelete: ((NetworkDevice) -> Void)? = nil,
    onSyncPeripherals: ((NetworkDevice) -> Void)? = nil,
    onTrustPending: ((NetworkDevice) -> Void)? = nil
  ) {
    self.devices = devices
    self.buttonTitle = buttonTitle
    self.actionHelp = actionHelp
    self.requiresPairing = requiresPairing
    self.action = action
    self.onDelete = onDelete
    self.onSyncPeripherals = onSyncPeripherals
    self.onTrustPending = onTrustPending
  }

  private var blockedByPairing: Bool {
    requiresPairing && !pairing.isPaired
  }

  var body: some View {
    List(devices) { device in
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(device.name)
          Spacer()
          Button(action: { action(device) }) {
            Text(buttonTitle)
          }
          .disabled(!device.isActive || blockedByPairing)
          .help(blockedByPairing ? NetworkDeviceManagementView.Help.needsPairing : actionHelp)

          if let onSync = onSyncPeripherals {
            Button(action: { onSync(device) }) {
              Image(systemName: "square.and.arrow.up")
                .foregroundColor(.blue)
            }
            .disabled(!device.isActive || blockedByPairing)
            .help(
              blockedByPairing
                ? NetworkDeviceManagementView.Help.needsPairing
                : NetworkDeviceManagementView.Help.sync
            )
            .accessibilityLabel("Send peripheral list to \(device.name)")
          }

          if let onDelete = onDelete {
            Button(action: { onDelete(device) }) {
              Image(systemName: "trash")
                .foregroundColor(.red)
            }
            .help(NetworkDeviceManagementView.Help.remove)
            .accessibilityLabel("Remove \(device.name)")
          }
        }

        if let onTrustPending = onTrustPending, device.pendingFingerprint != nil {
          HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundColor(.yellow)
              .accessibilityHidden(true)
            Text("New pairing key advertised.")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
            Button("Trust") {
              onTrustPending(device)
            }
            .help(NetworkDeviceManagementView.Help.trust)
            .accessibilityLabel("Trust new key for \(device.name)")
          }
          .padding(.vertical, 2)
        }
      }
    }
  }
}

// MARK: - Preview

#Preview {
  NetworkDeviceManagementView()
}
