import SwiftUI

/// Latest inline action result for a device (Ping or Sync). Carried in
/// `operationResults` and rendered under the device row. Either action
/// overwrites the previous result, so there's only ever one status line
/// per row — whichever the user did most recently.
struct OperationResult {
  let success: Bool
  let message: String
}

private enum Constants {
  enum Strings {
    static let connectedDevices = "Your Other Mac"
    static let availableDevices = "Macs Found on the Network"
    static let noConnectedDevicesHint =
      "Add your other Mac from \"Macs Found on the Network\" below to start switching peripherals between them."
    static let noAvailableDevicesHint =
      "Make sure Magic Switch is running on your other Mac and both Macs are on the same Wi-Fi network. Then tap Refresh — or use the + button to add the Mac by IP address if your network blocks Bonjour."
    static let connectionLimitMessage =
      "Only one Mac can be connected at a time. Remove the existing one first."
    static let notify = "Ping"
    static let add = "Add"
  }
}

/// View for managing network device connections and registrations
struct NetworkDeviceManagementView: View {
  // MARK: - Dependencies

  @ObservedObject private var networkStore = NetworkDeviceStore.shared
  @ObservedObject private var pairing = PairingStore.shared
  @ObservedObject private var diagnostics = AdvertisingDiagnostics.shared
  @ObservedObject private var dialback = DialbackAddresses.shared

  // MARK: - State

  /// Single source of truth for the confirmation alert. Stacking two
  /// separate `.alert(item:)` modifiers on one view doesn't work — SwiftUI
  /// only honours the last one applied, so the Remove alert never fired and
  /// the trash button looked like a no-op. One enum-keyed alert avoids that.
  @State private var activeAlert: DeviceAlert?

  /// The two confirmation prompts the Macs tab can raise. `id` is unique
  /// per (kind, device) so re-triggering for a different device re-presents.
  private enum DeviceAlert: Identifiable {
    case remove(NetworkDevice)
    case trust(NetworkDevice)

    var id: String {
      switch self {
      case .remove(let device): return "remove-\(device.id)"
      case .trust(let device): return "trust-\(device.id)"
      }
    }
  }
  /// Last Ping/Sync result per device id, surfaced inline because the
  /// OS-level notification path is unreliable on ad-hoc-signed sandboxed
  /// builds.
  @State private var operationResults: [String: OperationResult] = [:]
  /// Used by `handleSyncPeripherals` to snapshot the count of peripherals
  /// being synced for the inline success message.
  @ObservedObject private var bluetoothStore = BluetoothPeripheralStore.shared

  // MARK: - View Content

  private var formContent: some View {
    Form {
      if !pairing.isPaired {
        Section {
          // Label + accent colour reads as "do this next" without alarming
          // (red/yellow would imply error, which this isn't). The user is
          // here to configure something; flag the missing prerequisite so
          // they don't have to figure out from disabled buttons + tooltips
          // why nothing works.
          Label(
            "Pair both Macs in the Pairing tab to enable Ping, Sync, and the menu-bar switch.",
            systemImage: "arrow.right.circle.fill"
          )
          .font(.callout.bold())
          .foregroundColor(.accentColor)
        }
      }

      if diagnostics.publishWarning != nil || diagnostics.searchWarning != nil {
        Section {
          // Advisory, not an error: INTRODUCE keeps an added Mac working
          // without Bonjour, so secondary rather than warning colours.
          // Only the publish advisory gets the dial-back values — it's the
          // one telling the user to type them on the other Mac; the search
          // advisory would need the *other* Mac's address, which is
          // unknowable here.
          if let warning = diagnostics.publishWarning {
            advisory(warning + dialbackHint)
          }
          if let warning = diagnostics.searchWarning {
            advisory(warning)
          }
        }
      }

      RegisteredDevicesSectionView(
        devices: networkStore.networkDevices,
        operationResults: operationResults,
        onDeviceNotify: handleDeviceNotification,
        onDeviceRemoveRequest: { activeAlert = .remove($0) },
        onSyncPeripherals: handleSyncPeripherals,
        onTrustPending: handleTrustPending
      )

      AvailableDevicesSectionView(
        devices: networkStore.availableNetworkDevices,
        onDeviceRegister: handleDeviceRegistration
      )
    }
    // Clear stale Ping/Sync *results* whenever the user comes back to this
    // tab (or first opens it). Keeps "<device> responded." / failure lines
    // from sticking around across Settings sessions when they're no longer
    // meaningful. Within a single tab visit, repeated actions still
    // overwrite each other (existing behaviour, unchanged). An in-progress
    // Ping/Sync is unaffected — that lives in `networkStore.inFlightOperations`,
    // not here, which is what lets its progress line survive a tab switch.
    .onAppear { operationResults.removeAll() }
    .alert(item: $activeAlert) { alert in
      switch alert {
      case .remove(let device):
        return Alert(
          title: Text("Remove \(device.name)?"),
          message: Text(
            "It will be removed from your registered list. You can add it again from \"Macs Found on the Network\"."
          ),
          primaryButton: .destructive(Text("Remove")) {
            networkStore.removeNetworkDevice(device: device)
          },
          secondaryButton: .cancel()
        )
      case .trust(let device):
        return Alert(
          title: Text("Trust new pairing key for \(device.name)?"),
          message: Text(trustAlertMessage(for: device)),
          primaryButton: .destructive(Text("Trust")) {
            networkStore.trustPendingFingerprint(for: device.id)
          },
          secondaryButton: .cancel()
        )
      }
    }
  }

  /// Concrete values for the publish advisory's "use Add by Address on the
  /// other Mac" — with them in hand, the bootstrap needs no other screen.
  private var dialbackHint: String {
    guard let addresses = dialback.displayList(),
      let port = networkStore.localListeningPort
    else { return "" }
    return " Enter \(addresses), port \(String(port)) there."
  }

  private func advisory(_ text: String) -> some View {
    Label(text, systemImage: "info.circle")
      .font(.callout)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// Show both fingerprints so the "verify this was intentional" step can
  /// actually be performed: the new one should match what the other Mac's
  /// Pairing tab shows after the re-pair. Fingerprints are short hex strings
  /// (see `PairingStore.fingerprint(forKey:)`), fine for an alert body.
  private func trustAlertMessage(for device: NetworkDevice) -> String {
    var message =
      "Only do this if you intentionally re-paired the other Mac. Otherwise this could be an impersonation attempt — the fingerprint that previously identified \(device.name) has changed."
    if let pending = device.pendingFingerprint {
      message += "\n\nNew fingerprint: \(pending)"
      if let pinned = device.fingerprint {
        message += "\nPrevious fingerprint: \(pinned)"
      }
      message +=
        "\n\nThe new fingerprint should match the one shown in Settings → Pairing on \(device.name)."
    }
    return message
  }

  // MARK: - Tooltips

  fileprivate enum Help {
    static let notify =
      "Send a test message over the secure channel — confirms both Macs can reach each other."
    static let add = "Add this Mac to your registered list."
    static let sync = "Send your peripheral list to this Mac so it knows about them."
    static let remove = "Remove this Mac from the registered list."
    static let refresh = "Re-scan the network for other Macs running Magic Switch."
    static let addByAddress =
      "Add your other Mac by IP address — for networks that block Bonjour discovery."
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
    // The "Pinging…" progress line is driven by `networkStore.inFlightOperations`
    // (see `NetworkDeviceListView`) so it survives a tab switch; here we only
    // record the terminal result.
    networkStore.sendNotification(to: device) { result in
      switch result {
      case .success:
        operationResults[device.id] = OperationResult(
          success: true, message: "\(device.name) responded."
        )
      case .failure(let err):
        operationResults[device.id] = OperationResult(
          success: false, message: err.userMessage
        )
      }
    }
  }

  private func handleDeviceRegistration(_ device: NetworkDevice) {
    networkStore.registerNetworkDevice(device: device)
  }

  private func handleTrustPending(_ device: NetworkDevice) {
    // Request the confirmation alert; actual promotion happens in its
    // primaryButton. TOFU pin overrides are destructive — we won't do it
    // without explicit acknowledgement.
    activeAlert = .trust(device)
  }

  private func handleSyncPeripherals(_ device: NetworkDevice) {
    let peripherals = bluetoothStore.peripherals
    let count = peripherals.count
    let noun = count == 1 ? "peripheral" : "peripherals"
    // "Syncing…" progress comes from `networkStore.inFlightOperations`; record
    // only the terminal result here.
    networkStore.sendPeripheralSync(peripherals: peripherals, to: device) { result in
      switch result {
      case .success:
        operationResults[device.id] = OperationResult(
          success: true,
          message: "Synced \(count) \(noun) to \(device.name)."
        )
      case .failure(let err):
        operationResults[device.id] = OperationResult(
          success: false,
          message: err.userMessage
        )
      }
    }
  }
}

// MARK: - Supporting Views

private struct RegisteredDevicesSectionView: View {
  // MARK: - Properties
  let devices: [NetworkDevice]
  let operationResults: [String: OperationResult]
  let onDeviceNotify: (NetworkDevice) -> Void
  let onDeviceRemoveRequest: (NetworkDevice) -> Void
  let onSyncPeripherals: (NetworkDevice) -> Void
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
          operationResults: operationResults,
          action: onDeviceNotify,
          onDelete: onDeviceRemoveRequest,
          onSyncPeripherals: onSyncPeripherals,
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
  @ObservedObject private var pairing = PairingStore.shared

  // MARK: - Properties

  let devices: [NetworkDevice]
  let onDeviceRegister: (NetworkDevice) -> Void

  @State private var showingAddByAddress = false

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
        Button(action: { showingAddByAddress = true }) {
          Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .disabled(!pairing.isPaired)
        .help(
          pairing.isPaired
            ? NetworkDeviceManagementView.Help.addByAddress
            : NetworkDeviceManagementView.Help.needsPairing
        )
        .accessibilityLabel("Add a Mac by address")
        .sheet(isPresented: $showingAddByAddress) {
          AddByAddressSheet(isPresented: $showingAddByAddress)
        }
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

private struct AddByAddressSheet: View {
  @Binding var isPresented: Bool
  @ObservedObject private var networkStore = NetworkDeviceStore.shared
  @ObservedObject private var dialback = DialbackAddresses.shared

  @State private var host = ""
  @State private var port = String(ServicePublisher.defaultPort)
  @State private var inProgress = false
  @State private var errorMessage: String?

  private var canSubmit: Bool {
    !host.trimmingCharacters(in: .whitespaces).isEmpty && (UInt16(port) ?? 0) > 0 && !inProgress
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add a Mac by Address")
        .font(.headline)
      Text(
        "For networks that block Bonjour. Pair both Macs with the same code first, then enter the other Mac's IP address."
      )
      .font(.callout)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        TextField("IP address", text: $host)
        TextField("Port", text: $port)
          .frame(width: 64)
      }
      .textFieldStyle(RoundedBorderTextFieldStyle())
      .disabled(inProgress)

      if let localPort = networkStore.localListeningPort {
        // The reverse-direction values, phrased as an instruction for the
        // other machine so nobody types this Mac's own address into the
        // fields above.
        Text(
          dialback.displayList().map {
            "On your other Mac, add this Mac as \($0), port \(String(localPort))."
          } ?? "This Mac accepts connections on port \(String(localPort))."
        )
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      if inProgress {
        Text("Connecting…")
          .font(.caption)
          .foregroundColor(.secondary)
      } else if let errorMessage = errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundColor(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
          .keyboardShortcut(.cancelAction)
        Button("Add") { submit() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canSubmit)
      }
    }
    .padding(20)
    .frame(width: 360)
  }

  private func submit() {
    guard let portValue = UInt16(port), portValue > 0 else { return }
    inProgress = true
    errorMessage = nil
    networkStore.addPeerManually(
      host: host.trimmingCharacters(in: .whitespaces), port: portValue
    ) { result in
      inProgress = false
      switch result {
      case .success:
        isPresented = false
      case .failure(let error):
        errorMessage = error.userMessage
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
  let operationResults: [String: OperationResult]
  let action: (NetworkDevice) -> Void
  let onDelete: ((NetworkDevice) -> Void)?
  let onSyncPeripherals: ((NetworkDevice) -> Void)?
  let onTrustPending: ((NetworkDevice) -> Void)?

  @ObservedObject private var pairing = PairingStore.shared
  @ObservedObject private var networkStore = NetworkDeviceStore.shared

  init(
    devices: [NetworkDevice],
    buttonTitle: String,
    actionHelp: String,
    requiresPairing: Bool = false,
    operationResults: [String: OperationResult] = [:],
    action: @escaping (NetworkDevice) -> Void,
    onDelete: ((NetworkDevice) -> Void)? = nil,
    onSyncPeripherals: ((NetworkDevice) -> Void)? = nil,
    onTrustPending: ((NetworkDevice) -> Void)? = nil
  ) {
    self.devices = devices
    self.buttonTitle = buttonTitle
    self.actionHelp = actionHelp
    self.requiresPairing = requiresPairing
    self.operationResults = operationResults
    self.action = action
    self.onDelete = onDelete
    self.onSyncPeripherals = onSyncPeripherals
    self.onTrustPending = onTrustPending
  }

  private var blockedByPairing: Bool {
    requiresPairing && !pairing.isPaired
  }

  /// Hover text for the row's name. Only the registered section has a Trust
  /// affordance and a reachability signal — `pollReachability` probes
  /// `networkDevices` alone — so discovered rows get the weaker claim their
  /// data actually supports.
  private func nameHelp(for device: NetworkDevice) -> String {
    // The Trust button and the warning row below are gated on this same
    // closure, so it's the honest test for "can the user act on a mismatch
    // here": pointing a discovered row at Trust would name a control that
    // section doesn't have.
    let canTrust = onTrustPending != nil
    if device.pendingFingerprint != nil {
      return canTrust
        ? "\(device.name) is advertising a new pairing key. Switching from this Mac is paused until you choose Trust, or until \(device.name) proves over the secure channel that it holds this Mac's current key."
        : "\(device.name) is advertising a pairing key that doesn't match the one seen earlier, so it can't be added. Use Refresh to re-scan."
    }
    guard canTrust else {
      return device.isActive
        ? "\(device.name) is advertising itself on the network."
        : "\(device.name) has stopped advertising on the network."
    }
    // Mirror the menu's verdict rather than `isActive`: a fresh-looking
    // Bonjour record only says the peer advertised, while the ping poll is
    // what proves it answers. A peer that died without withdrawing — or one
    // sleeping behind a Bonjour sleep proxy that answers for it — still looks
    // advertised indefinitely, and claiming "reachable" there would
    // contradict the greyed row in the menu.
    return networkStore.isReachable(device.id)
      ? "\(device.name) is answering at \(endpoint(for: device))."
      : "\(device.name) isn't reachable on the network right now."
  }

  /// `host:port`, with IPv6 bracketed so the address's own colons don't run
  /// into the port number.
  private func endpoint(for device: NetworkDevice) -> String {
    device.host.contains(":")
      ? "[\(device.host)]:\(device.port)"
      : "\(device.host):\(device.port)"
  }

  var body: some View {
    // Rows go straight into the enclosing Form Section — a nested List here
    // gives each row a taller default height than its content, which
    // top-aligns the row contents instead of centering them in the pill.
    // Letting the Form own the row layout keeps content vertically centered.
    ForEach(devices) { device in
      // A Ping/Sync in flight disables both buttons (they share one secure
      // channel and one status line) and drives the progress line below.
      let inFlight = networkStore.inFlightOperations[device.id]
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          // The buttons each explain themselves, but the name — most of the
          // row — said nothing on hover. Surface the state that drives the
          // row's enablement, since a greyed button gives no clue why.
          Text(device.name)
            .help(nameHelp(for: device))
          Spacer()
          Button(action: { action(device) }) {
            Text(buttonTitle)
          }
          .disabled(!device.isActive || blockedByPairing || inFlight != nil)
          .help(blockedByPairing ? NetworkDeviceManagementView.Help.needsPairing : actionHelp)

          if let onSync = onSyncPeripherals {
            // An explicit foregroundColor overrides the automatic disabled
            // dimming, so pick the colour from the same condition that
            // disables the button — otherwise an unreachable Mac's sync
            // icon stays bright blue while silently ignoring clicks.
            let syncEnabled = device.isActive && !blockedByPairing && inFlight == nil
            // Not `square.and.arrow.up` — that's the system Share glyph, which
            // misreads as a share sheet. Circular arrows say "sync".
            Button(action: { onSync(device) }) {
              Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(syncEnabled ? .blue : .secondary)
            }
            .disabled(!syncEnabled)
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

        if let inFlight = inFlight {
          Text(progressMessage(for: inFlight, device: device))
            .font(.caption)
            .foregroundColor(.secondary)
        } else if let result = operationResults[device.id] {
          Text(result.message)
            .font(.caption)
            .foregroundColor(result.success ? .secondary : .red)
        }
      }
    }
  }

  private func progressMessage(for op: DeviceOperation, device: NetworkDevice) -> String {
    switch op {
    case .ping:
      return "Pinging \(device.name)…"
    case .sync(let count):
      let noun = count == 1 ? "peripheral" : "peripherals"
      return "Syncing \(count) \(noun) to \(device.name)…"
    }
  }
}

// MARK: - Preview

#Preview {
  NetworkDeviceManagementView()
}
