import AppKit
import SwiftUI

/// A floating window telling the user which code to type on a keyboard that
/// is pairing, then confirming once it connects. It can't appear over the
/// lock screen. Main-only.
final class PairingCodePanel {
  static let shared = PairingCodePanel()

  private static let connectedLinger: TimeInterval = 1.5

  private var panel: NSPanel?
  private var address: String?
  private var model: PairingCodeModel?

  func show(for address: String, name: String, code: String, onCancel: @escaping () -> Void) {
    close()
    let model = PairingCodeModel()
    let view = PairingCodeView(model: model, name: name, code: code, onCancel: onCancel)
    let hosting = NSHostingView(rootView: view)
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
      styleMask: [.titled, .closable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = hosting
    panel.title = String(localized: "Pairing \(name)")
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.center()
    panel.orderFrontRegardless()
    self.panel = panel
    self.address = address
    self.model = model
  }

  /// Switches `address`'s window to the connected confirmation, then closes it.
  func showConnected(for address: String) {
    guard self.address == address, let panel, let model else { return }
    model.connected = true
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectedLinger) { [weak self] in
      guard let self, self.panel === panel else { return }
      self.close()
    }
  }

  func close(for address: String) {
    guard self.address == address else { return }
    close()
  }

  private func close() {
    panel?.close()
    panel = nil
    address = nil
    model = nil
  }
}

private final class PairingCodeModel: ObservableObject {
  @Published var connected = false
}

private struct PairingCodeView: View {
  @ObservedObject var model: PairingCodeModel
  let name: String
  let code: String
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "keyboard")
        .font(.system(size: 28))
        .foregroundColor(.secondary)
      ZStack {
        Text(code)
          .font(.system(size: 48, weight: .semibold, design: .monospaced))
          .opacity(model.connected ? 0 : 1)
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 44))
          .foregroundColor(.green)
          .opacity(model.connected ? 1 : 0)
      }
      .accessibilityHidden(true)
      ZStack {
        Text("Type \(code) on \(name), then press Return.")
          .opacity(model.connected ? 0 : 1)
          .accessibilityHidden(model.connected)
        Text("\(name) is connected.")
          .opacity(model.connected ? 1 : 0)
          .accessibilityHidden(!model.connected)
      }
      .font(.headline)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      Text("Nothing appears on screen while you type.")
        .font(.callout)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(model.connected ? 0 : 1)
        .accessibilityHidden(model.connected)
      Button("Cancel", action: onCancel)
        .padding(.top, 4)
        .opacity(model.connected ? 0 : 1)
        .disabled(model.connected)
    }
    .padding(24)
    .frame(width: 320)
    .animation(.easeInOut(duration: 0.2), value: model.connected)
  }
}
