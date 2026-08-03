import AppKit
import Carbon.HIToolbox

/// A recorded global keyboard shortcut: the key plus its modifiers, with a
/// pre-computed display name for the key so rendering never needs to re-derive
/// a glyph from the key code (layout-dependent and fiddly at load time).
struct HotkeyShortcut: Codable, Equatable {
  let keyCode: UInt32
  /// `NSEvent.ModifierFlags.rawValue`, masked to device-independent flags.
  let modifierFlags: UInt
  /// Display name of the key alone, e.g. "K", "Space", "F5".
  let keyDisplay: String

  var modifiers: NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: modifierFlags)
  }

  /// Standard macOS ordering: ⌃ ⌥ ⇧ ⌘, then the key.
  var displayString: String {
    var parts = ""
    if modifiers.contains(.control) { parts += "⌃" }
    if modifiers.contains(.option) { parts += "⌥" }
    if modifiers.contains(.shift) { parts += "⇧" }
    if modifiers.contains(.command) { parts += "⌘" }
    return parts + keyDisplay
  }

  /// The same modifiers in Carbon's bit layout, for `RegisterEventHotKey`.
  var carbonModifiers: UInt32 {
    var carbon: UInt32 = 0
    if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
    if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
    if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
    if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
    return carbon
  }
}

/// Owns the app's global hotkeys end to end: persistence, Carbon
/// registration, and the record-a-new-shortcut flow driven from Settings →
/// Other. One optional shortcut per `SwitchDirection` — the same three
/// full-set actions as the URL scheme, with the same semantics (`send` and
/// `take` are idempotent; `toggle` mirrors clicking the Mac row in the menu).
///
/// Carbon `RegisterEventHotKey` is used deliberately: unlike a global NSEvent
/// monitor it needs no Accessibility/Input Monitoring permission and works in
/// the App Sandbox. Recording uses a *local* monitor (only sees this app's own
/// key events, no permission needed) while the Settings window is key.
final class HotkeyManager: ObservableObject {
  static let shared = HotkeyManager()

  /// The registered shortcuts; a missing key means that action has none.
  @Published private(set) var shortcuts: [SwitchDirection: HotkeyShortcut] = [:]

  /// The action whose shortcut is being recorded, nil when not recording.
  @Published private(set) var recordingDirection: SwitchDirection?

  /// Fired on the main queue when a hotkey is pressed. Assigned by
  /// `AppDelegate`, which routes it into the full-set switch path.
  var onHotkey: ((SwitchDirection) -> Void)?

  /// Stable order so each direction keeps its Carbon hotkey ID (index + 1).
  private static let directions: [SwitchDirection] = [.send, .take, .toggle]

  private static func defaultsKey(for direction: SwitchDirection) -> String {
    "switch-shortcut-\(direction.rawValue)"
  }

  private var hotKeyRefs: [SwitchDirection: EventHotKeyRef] = [:]
  private var eventHandlerRef: EventHandlerRef?
  private var recordingMonitor: Any?

  private init() {}

  /// Load the persisted shortcuts (if any) and register them. Call once at launch.
  func start() {
    for direction in Self.directions {
      guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey(for: direction)),
        let stored = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
      else { continue }
      shortcuts[direction] = stored
    }
    syncRegistration()
  }

  /// Persist and activate `newShortcut` for `direction`; nil turns it off.
  /// A chord already bound to another action moves here (recording a taken
  /// chord means "rebind it", the way macOS's own shortcut panes behave).
  func setShortcut(_ newShortcut: HotkeyShortcut?, for direction: SwitchDirection) {
    if let newShortcut {
      for (other, existing) in shortcuts where other != direction && existing == newShortcut {
        shortcuts[other] = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey(for: other))
      }
    }
    shortcuts[direction] = newShortcut
    if let newShortcut, let data = try? JSONEncoder().encode(newShortcut) {
      UserDefaults.standard.set(data, forKey: Self.defaultsKey(for: direction))
    } else {
      UserDefaults.standard.removeObject(forKey: Self.defaultsKey(for: direction))
    }
    syncRegistration()
  }

  // MARK: - Recording

  /// Start capturing the next key press as `direction`'s shortcut. Esc
  /// cancels, Delete clears the existing shortcut, anything else needs
  /// ⌘/⌥/⌃ (shift alone would swallow ordinary typing system-wide).
  func startRecording(for direction: SwitchDirection) {
    guard recordingDirection == nil else { return }
    recordingDirection = direction
    // While recording, every hotkey is unregistered so pressing a chord
    // that's already bound re-records it instead of firing a switch.
    unregisterAll()
    recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self = self, self.recordingDirection != nil else { return event }
      self.handleRecordingKeyDown(event)
      return nil  // swallow the event — it was meant for the recorder
    }
  }

  func cancelRecording() {
    guard recordingDirection != nil else { return }
    stopRecording()
  }

  private func stopRecording() {
    recordingDirection = nil
    if let monitor = recordingMonitor {
      NSEvent.removeMonitor(monitor)
      recordingMonitor = nil
    }
    syncRegistration()
  }

  private func handleRecordingKeyDown(_ event: NSEvent) {
    guard let direction = recordingDirection else { return }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .intersection([.command, .option, .control, .shift])

    if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
      stopRecording()
      return
    }
    if event.keyCode == UInt16(kVK_Delete), modifiers.isEmpty {
      setShortcut(nil, for: direction)
      stopRecording()
      return
    }
    // Require a real chord: at least one of ⌘/⌥/⌃.
    guard !modifiers.intersection([.command, .option, .control]).isEmpty else { return }

    let captured = HotkeyShortcut(
      keyCode: UInt32(event.keyCode),
      modifierFlags: modifiers.rawValue,
      keyDisplay: Self.keyDisplay(for: event))
    setShortcut(captured, for: direction)
    stopRecording()
  }

  /// Human-readable name for the pressed key alone (no modifiers).
  private static func keyDisplay(for event: NSEvent) -> String {
    if let special = specialKeyNames[Int(event.keyCode)] { return special }
    if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
      return chars.uppercased()
    }
    return "Key \(event.keyCode)"
  }

  private static let specialKeyNames: [Int: String] = [
    kVK_Space: "Space",
    kVK_Return: "↩",
    kVK_Tab: "⇥",
    kVK_ForwardDelete: "⌦",
    kVK_Home: "↖",
    kVK_End: "↘",
    kVK_PageUp: "⇞",
    kVK_PageDown: "⇟",
    kVK_LeftArrow: "←",
    kVK_RightArrow: "→",
    kVK_DownArrow: "↓",
    kVK_UpArrow: "↑",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
    kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
    kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
  ]

  // MARK: - Carbon registration

  /// Re-derive the Carbon registrations from `shortcuts`. Unregister-all then
  /// register-all is idempotent and cheap (three hotkeys at most), which keeps
  /// every mutation path — set, clear, steal, record — trivially correct.
  /// No-op mid-recording; `stopRecording` calls back in when done.
  private func syncRegistration() {
    guard recordingDirection == nil else { return }
    unregisterAll()
    guard !shortcuts.isEmpty else { return }
    installEventHandlerIfNeeded()
    for (direction, shortcut) in shortcuts {
      register(shortcut, for: direction)
    }
  }

  private func register(_ shortcut: HotkeyShortcut, for direction: SwitchDirection) {
    guard let index = Self.directions.firstIndex(of: direction) else { return }
    // FourCharCode 'MSWH' — arbitrary but stable app-unique signature.
    let hotKeyID = EventHotKeyID(signature: 0x4D53_5748, id: UInt32(index + 1))
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      shortcut.keyCode,
      shortcut.carbonModifiers,
      hotKeyID,
      GetEventDispatcherTarget(),
      0,
      &ref)
    if status == noErr, let ref {
      hotKeyRefs[direction] = ref
    } else {
      // Most likely another app holds the same combo. The shortcut stays
      // stored (it may work next launch); log so the silence is explainable.
      NSLog(
        "Magic Switch: registering global hotkey \(shortcut.displayString) failed (\(status))")
    }
  }

  private func unregisterAll() {
    for ref in hotKeyRefs.values {
      UnregisterEventHotKey(ref)
    }
    hotKeyRefs.removeAll()
  }

  private func installEventHandlerIfNeeded() {
    guard eventHandlerRef == nil else { return }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetEventDispatcherTarget(),
      { _, event, userData -> OSStatus in
        guard let userData = userData, let event = event else { return noErr }
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID)
        let index = Int(hotKeyID.id) - 1
        guard HotkeyManager.directions.indices.contains(index) else { return noErr }
        let direction = HotkeyManager.directions[index]
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async { manager.onHotkey?(direction) }
        return noErr
      },
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandlerRef)
  }
}
