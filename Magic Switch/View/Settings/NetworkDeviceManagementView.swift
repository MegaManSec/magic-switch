import SwiftUI

/// Latest inline Ping result for a device. Carried in `pingResults` and
/// rendered under the device row in the Registered list.
struct PingResult {
  let success: Bool
  let message: String
}

private enum Constants {
  enum Strings {
    static let connectedDevices = "Connected Devices"
    static let availableDevices = "Available Devices"
    static let noConnectedDevicesHint =
      "Add another Mac from \"Available Devices\" below to start switching peripherals between them."
    static let noAvailableDevicesHint =
      "Make sure Magic Switch is running on your other Mac and both Macs are on the same Wi-Fi network. Then tap Refresh."
    static let connectionLimitMessage =
      "Only one device can be connected at a time. Remove the existing device first."
    static let notify = "Ping"
    static let add = "Add"
  }
}

/// View for managing network device connections and registrations
struct NetworkDeviceManagementView: View {
  // MARK: - Dependencies

  @ObservedObject private var networkStore = NetworkDeviceStore.shared
  @ObservedObject private var pairing = PairingStore.shared

  // MARK: - State

  @State private var deviceToRemove: NetworkDevice?
  /// Last Ping result per device id, surfaced inline because the OS-level
  /// notification path is unreliable on ad-hoc-signed sandboxed builds.
  @State private var pingResults: [String: PingResult] = [:]

  // MARK: - View Content

  private var formContent: some View {
    Form {
      if !pairing.isPaired {
        Section {
          Text(
            "Pair both Macs in the Pairing tab to enable Notify, Sync, and the menu-bar switch."
          )
          .font(.callout)
          .foregroundColor(.secondary)
        }
      }

      RegisteredDevicesSectionView(
        devices: networkStore.networkDevices,
        pingResults: pingResults,
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
    static let notify =
      "Send a test message over the secure channel — confirms both Macs can reach each other."
    static let add = "Add this Mac to your registered list."
    static let sync = "Send your peripheral list to this Mac so it knows about them."
    static let remove = "Remove this Mac from the registered list."
    static let refresh = "Re-scan the network for other Macs running Magic Switch."
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
    pingResults[device.id] = PingResult(success: true, message: "Pinging \(device.name)…")
    networkStore.sendNotification(to: device) { result in
      switch result {
      case .success:
        pingResults[device.id] = PingResult(
          success: true, message: "\(device.name) responded."
        )
      case .failure(let err):
        pingResults[device.id] = PingResult(
          success: false, message: err.userMessage
        )
      }
    }
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
  let pingResults: [String: PingResult]
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
          pingResults: pingResults,
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
  let pingResults: [String: PingResult]
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
    pingResults: [String: PingResult] = [:],
    action: @escaping (NetworkDevice) -> Void,
    onDelete: ((NetworkDevice) -> Void)? = nil,
    onSyncPeripherals: ((NetworkDevice) -> Void)? = nil,
    onTrustPending: ((NetworkDevice) -> Void)? = nil
  ) {
    self.devices = devices
    self.buttonTitle = buttonTitle
    self.actionHelp = actionHelp
    self.requiresPairing = requiresPairing
    self.pingResults = pingResults
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

        if let ping = pingResults[device.id] {
          Text(ping.message)
            .font(.caption)
            .foregroundColor(ping.success ? .secondary : .red)
        }
      }
    }
  }
}

// MARK: - Preview

#Preview {
  NetworkDeviceManagementView()
}
