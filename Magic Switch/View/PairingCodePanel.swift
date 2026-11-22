import AppKit
import SwiftUI

/// A floating window telling the user which code to type on a keyboard that
/// is pairing. It can't appear over the lock screen. Main-only.
final class PairingCodePanel {
  static let shared = PairingCodePanel()

  private var panel: NSPanel?
  private var address: String?

  func show(for address: String, name: String, code: String, onCancel: @escaping () -> Void) {
    close()
    let view = PairingCodeView(name: name, code: code, onCancel: onCancel)
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
  }

  func close(for address: String) {
    guard self.address == address else { return }
    close()
  }

  private func close() {
    panel?.close()
    panel = nil
    address = nil
  }
}

private struct PairingCodeView: View {
  let name: String
  let code: String
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "keyboard")
        .font(.system(size: 28))
        .foregroundColor(.secondary)
      Text(code)
        .font(.system(size: 48, weight: .semibold, design: .monospaced))
        .accessibilityHidden(true)
      Text("Type \(code) on \(name), then press Return.")
        .font(.headline)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Text("Nothing appears on screen while you type.")
        .font(.callout)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Button("Cancel", action: onCancel)
        .padding(.top, 4)
    }
    .padding(24)
    .frame(width: 320)
  }
}
