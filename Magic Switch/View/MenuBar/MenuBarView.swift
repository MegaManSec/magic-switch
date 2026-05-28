import SwiftUI

protocol MenuBarPresentable {
  func showMenu(statusItem: NSStatusItem)
}

final class MenuBarView: MenuBarPresentable {
  // MARK: - Constants

  private enum Constants {
    enum Menu {
      static let macsHeader = "Macs"
      static let peripheralsHeader = "Peripherals"
      static let settings = "Settings..."
      static let quit = "Quit"
    }

    enum KeyEquivalents {
      static let settings = ","
      static let quit = "q"
    }

    enum Symbols {
      static let mac = "desktopcomputer"
      static let peripheral = "keyboard"
      static let settings = "gearshape"
      static let quit = "power"
    }
  }

  // MARK: - Dependencies

  private let networkStore = NetworkDeviceStore.shared
  private let bluetoothStore = BluetoothPeripheralStore.shared

  // MARK: - Public Methods

  func showMenu(statusItem: NSStatusItem) {
    let menu = createMenu()
    presentMenu(menu, for: statusItem)
  }

  // MARK: - Private Methods

  private func createMenu() -> NSMenu {
    let menu = NSMenu()

    let macs = networkStore.networkDevices
    if !macs.isEmpty {
      menu.addItem(makeSectionHeader(Constants.Menu.macsHeader))
      for device in macs {
        // Click opens Settings → Device. Enabled state is driven by
        // `validateMenuItem` on AppDelegate using `device.isActive`, so a
        // peer that's gone offline greys out for a meaningful reason
        // instead of "this row has no action wired up".
        let item = makeItem(
          title: device.name,
          symbol: Constants.Symbols.mac,
          action: #selector(AppDelegate.handleMacMenuClick(_:)))
        item.representedObject = device.id
        item.toolTip =
          device.isActive
          ? "Open Settings → Device"
          : "\(device.name) isn't reachable on the network right now."
        menu.addItem(item)
      }
      menu.addItem(.separator())
    }

    let peripherals = bluetoothStore.peripherals
    if !peripherals.isEmpty {
      menu.addItem(makeSectionHeader(Constants.Menu.peripheralsHeader))
      for peripheral in peripherals {
        let state = bluetoothStore.connectionState(for: peripheral.id)
        let title = state == .connecting ? "\(peripheral.name) (Pairing…)" : peripheral.name
        // Disable while pairing; otherwise wire to the per-peripheral switch.
        let item = makeItem(
          title: title,
          symbol: Constants.Symbols.peripheral,
          action: state == .connecting
            ? nil : #selector(AppDelegate.handlePeripheralMenuClick(_:)))
        // Checkmark for "currently on this Mac" so users can see at a
        // glance which side holds which peripheral.
        item.state = state == .connected ? .on : .off
        // Pass the MAC down to the action handler; clicking dispatches
        // take-from-peer or send-to-peer based on current state.
        item.representedObject = peripheral.id
        menu.addItem(item)
      }
      menu.addItem(.separator())
    }

    menu.addItem(
      makeItem(
        title: Constants.Menu.settings,
        symbol: Constants.Symbols.settings,
        action: #selector(AppDelegate.openSettingsWindow(_:)),
        keyEquivalent: Constants.KeyEquivalents.settings))

    // Route through AppDelegate so the status-bar Quit really exits;
    // `applicationShouldTerminate` cancels other terminate sources
    // (Cmd+Q with Settings focused, Dock-icon → Quit) and just closes
    // the Settings window instead.
    menu.addItem(
      makeItem(
        title: Constants.Menu.quit,
        symbol: Constants.Symbols.quit,
        action: #selector(AppDelegate.quitFromStatusBar(_:)),
        keyEquivalent: Constants.KeyEquivalents.quit))

    return menu
  }

  private func makeItem(
    title: String,
    symbol: String,
    action: Selector?,
    keyEquivalent: String = ""
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
      item.image = img
    }
    return item
  }

  /// Bold, disabled, non-selectable section header. Uses the native
  /// `NSMenuItem.sectionHeader(title:)` on macOS 14+ and a manual styled
  /// item on earlier versions.
  private func makeSectionHeader(_ title: String) -> NSMenuItem {
    if #available(macOS 14.0, *) {
      return NSMenuItem.sectionHeader(title: title)
    }
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
    item.isEnabled = false
    return item
  }

  private func presentMenu(_ menu: NSMenu, for statusItem: NSStatusItem) {
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }
}
