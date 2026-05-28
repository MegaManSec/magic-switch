import SwiftUI

private enum Constants {
  enum Strings {
    static let connectedDevices = "Connected Devices"
    static let availableDevices = "Available Devices"
    static let noConnectedDevices = "No connected devices"
    static let noAvailableDevices = "No available devices found"
    static let notify = "Notify"
    static let connect = "Connect"
    static let connectionLimitMessage =
      "Only one device can be connected at a time. Please remove existing device first."
  }
}

/// View for managing network device connections and registrations
struct NetworkDeviceManagementView: View {
  // MARK: - Dependencies

  @ObservedObject private var networkStore = NetworkDeviceStore.shared

  // MARK: - View Content

  private var formContent: some View {
    Form {
      RegisteredDevicesSectionView(
        devices: networkStore.networkDevices,
        onDeviceNotify: handleDeviceNotification,
        onDeviceRemove: networkStore.removeNetworkDevice
      )

      AvailableDevicesSectionView(
        devices: networkStore.availableNetworkDevices,
        onDeviceRegister: handleDeviceRegistration
      )
    }
  }

  // MARK: - Tooltips

  fileprivate enum Help {
    static let notify = "Send a test notification to this Mac."
    static let connect = "Add this Mac to your registered list."
    static let sync = "Send your peripheral list to this Mac."
    static let remove = "Remove this Mac from the registered list."
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
}

// MARK: - Supporting Views

private struct RegisteredDevicesSectionView: View {
  // MARK: - Dependencies
  @ObservedObject private var bluetoothStore = BluetoothPeripheralStore.shared
  @ObservedObject private var networkStore = NetworkDeviceStore.shared

  // MARK: - Properties
  let devices: [NetworkDevice]
  let onDeviceNotify: (NetworkDevice) -> Void
  let onDeviceRemove: (NetworkDevice) -> Void

  var body: some View {
    Section {
      if devices.isEmpty {
        Text(Constants.Strings.noConnectedDevices)
          .foregroundColor(.secondary)
      } else {
        NetworkDeviceListView(
          devices: devices,
          buttonTitle: Constants.Strings.notify,
          actionHelp: NetworkDeviceManagementView.Help.notify,
          requiresPairing: true,
          action: onDeviceNotify,
          onDelete: onDeviceRemove,
          onSyncPeripherals: { device in
            networkStore.sendPeripheralSync(
              peripherals: bluetoothStore.peripherals,
              to: device
            )
          }
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
    Section(header: Text(Constants.Strings.availableDevices).font(.headline)) {
      if !self.networkStore.networkDevices.isEmpty {
        Text(Constants.Strings.connectionLimitMessage)
          .foregroundColor(.secondary)
      } else if devices.isEmpty {
        Text(Constants.Strings.noAvailableDevices)
          .foregroundColor(.secondary)
      } else {
        NetworkDeviceListView(
          devices: devices,
          buttonTitle: Constants.Strings.connect,
          actionHelp: NetworkDeviceManagementView.Help.connect,
          action: onDeviceRegister
        )
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

  @ObservedObject private var pairing = PairingStore.shared

  init(
    devices: [NetworkDevice],
    buttonTitle: String,
    actionHelp: String,
    requiresPairing: Bool = false,
    action: @escaping (NetworkDevice) -> Void,
    onDelete: ((NetworkDevice) -> Void)? = nil,
    onSyncPeripherals: ((NetworkDevice) -> Void)? = nil
  ) {
    self.devices = devices
    self.buttonTitle = buttonTitle
    self.actionHelp = actionHelp
    self.requiresPairing = requiresPairing
    self.action = action
    self.onDelete = onDelete
    self.onSyncPeripherals = onSyncPeripherals
  }

  private var blockedByPairing: Bool {
    requiresPairing && !pairing.isPaired
  }

  var body: some View {
    List(devices) { device in
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
            Image(systemName: "arrow.triangle.2.circlepath")
              .foregroundColor(.blue)
          }
          .disabled(!device.isActive || blockedByPairing)
          .help(
            blockedByPairing
              ? NetworkDeviceManagementView.Help.needsPairing
              : NetworkDeviceManagementView.Help.sync
          )
        }

        if let onDelete = onDelete {
          Button(action: { onDelete(device) }) {
            Image(systemName: "trash")
              .foregroundColor(.red)
          }
          .help(NetworkDeviceManagementView.Help.remove)
        }
      }
    }
  }
}

// MARK: - Preview

#Preview {
  NetworkDeviceManagementView()
}
