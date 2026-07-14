import AppKit
import CoreGraphics
import SwiftUI

/// Watches which displays are physically connected and fires
/// `onTriggerDisplaysConnected` when one the user marked as a switch trigger
/// (Settings → Other) comes online — the "dock the MacBook at the desk, get
/// the desk's keyboard and trackpad" feature.
///
/// Displays are identified by their CoreGraphics display UUID
/// (`CGDisplayCreateUUIDFromDisplayID`), which is stable per physical panel
/// across replugs and reboots. Vendor/model numbers would match every unit of
/// the same monitor (useless in an office full of identical displays) and
/// EDID serial numbers are unreliably populated — the UUID sidesteps both,
/// and works for any display, not just Apple's.
///
/// Only a genuine absent → present *edge* fires the trigger:
/// - The set of displays online at launch is the baseline. A display that's
///   already attached when the app starts never fires — an app (re)start must
///   not yank peripherals from a Mac the user is actively working on.
/// - Reconfiguration callbacks are debounced and then *reconciled* against
///   `CGGetOnlineDisplayList`, so the remove/add churn of a resolution change
///   or a wake-time renegotiation nets out to no edge.
/// - Sleep: the present set is snapshotted at `willSleep`. For a settle
///   window after wake, a display in that snapshot re-enters silently —
///   staying docked across a sleep is not a dock, and must not steal the
///   peripherals from a peer the user switched to meanwhile. A display that
///   was *not* present at sleep still fires normally, which is exactly the
///   carry-the-MacBook-over, plug-in, lid-opens flow the feature exists for.
final class DisplayMonitor: ObservableObject {
  // MARK: - Singleton

  static let shared = DisplayMonitor()

  // MARK: - Types & Constants

  /// An online external display: `id` is the stable CoreGraphics display
  /// UUID string, `name` the user-facing name from `NSScreen`.
  struct ExternalDisplay: Identifiable, Equatable {
    let id: String
    let name: String
  }

  private enum Constants {
    /// How long after the last reconfiguration callback to wait before
    /// reconciling. Display changes arrive in bursts (begin/after passes,
    /// remove+add churn); coalescing them means one reconcile sees the
    /// settled end state, so transient churn produces no edge.
    static let reconcileDebounce: TimeInterval = 2
    /// How long after wake a display that was present at sleep may re-enter
    /// the present set silently. Wake-time renegotiation (Thunderbolt docks
    /// especially) can re-enumerate a display that never physically left,
    /// seconds after `didWake` — without this window that would read as a
    /// fresh dock and grab the peripherals on every wake-while-docked.
    /// Generous on purpose: it never delays a genuine trigger (a display
    /// absent at sleep is exempt); it only shields re-appearances.
    static let wakeSettleWindow: TimeInterval = 30
    /// Upper bound for `CGGetOnlineDisplayList`.
    static let maxDisplays: UInt32 = 16
  }

  /// `@AppStorage` key for the trigger-display map (display UUID →
  /// last-known name). Referenced by the Other settings tab too, so the key
  /// string lives here as the single source of truth.
  static let triggerDisplaysDefaultsKey = "displayTriggerDisplays"

  // MARK: - Properties

  /// External displays currently online, sorted by name — feeds the Settings
  /// rows. Updated by `reconcile()`.
  @Published private(set) var connectedDisplays: [ExternalDisplay] = []

  /// Displays the user marked as switch triggers: UUID → last-known name.
  /// The name is only a label (a remembered-but-disconnected row still needs
  /// one); matching is by UUID. Persisted.
  @Published private(set) var triggerDisplays: [String: String] = [:] {
    didSet { saveTriggerDisplays() }
  }

  @AppStorage(DisplayMonitor.triggerDisplaysDefaultsKey)
  private var triggerDisplaysData: Data = Data()

  /// Called on the main run loop with the names of trigger displays that
  /// just connected (usually one; a dock can bring up several at once).
  var onTriggerDisplaysConnected: (([String]) -> Void)?

  /// Display UUIDs believed present. The trigger fires only for additions to
  /// this set. Deliberately *not* rebuilt from scratch on wake — see the
  /// sleep handling below. Main-only.
  private var presentUUIDs: Set<String> = []

  /// `presentUUIDs` as of the last `willSleep` — taken before the sleep
  /// transition can churn it. Members re-appearing during the wake settle
  /// window are restorations, not docks. Main-only.
  private var presentAtSleep: Set<String> = []

  /// End of the post-wake settle window. Main-only.
  private var wakeSettleDeadline: Date = .distantPast

  /// Debounce timer for `reconcile()`; see `Constants.reconcileDebounce`.
  private var reconcileTimer: DispatchSourceTimer?

  private var started = false
  private var workspaceObservers: [NSObjectProtocol] = []

  // MARK: - Lifecycle

  private init() {
    loadTriggerDisplays()
  }

  /// Begin monitoring. Snapshots the currently-online displays as the
  /// no-edge baseline, then registers for reconfiguration callbacks and the
  /// sleep/wake notifications the settle logic needs.
  func start() {
    guard !started else { return }
    started = true

    let online = Self.onlineExternalDisplays()
    presentUUIDs = Set(online.map { $0.id })
    connectedDisplays = online
    refreshTriggerNames(from: online)

    let refCon = Unmanaged.passUnretained(self).toOpaque()
    let error = CGDisplayRegisterReconfigurationCallback(Self.reconfigurationCallback, refCon)
    if error != .success {
      print("DisplayMonitor: CGDisplayRegisterReconfigurationCallback failed: \(error)")
    }

    // NSWorkspace rather than IOKit on purpose: unlike `SleepMonitor` we
    // don't need to hold the power transition, only to bracket it — the
    // snapshot is instantaneous and the settle window absorbs ordering slack.
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(
      center.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.noteWillSleep() })
    workspaceObservers.append(
      center.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.noteDidWake() })
  }

  deinit {
    // The shared instance lives for the process; this is defensive only.
    if started {
      CGDisplayRemoveReconfigurationCallback(
        Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.forEach { center.removeObserver($0) }
  }

  // MARK: - Trigger Configuration

  /// Mark (or, with `false`, unmark) the display with `id` as a switch
  /// trigger. `name` is remembered so the Settings row keeps its label while
  /// the display is disconnected. Persisted immediately via the
  /// `triggerDisplays` didSet. Main-thread (Settings UI) only.
  func setTriggerEnabled(_ enabled: Bool, id: String, name: String) {
    if enabled {
      triggerDisplays[id] = name
    } else {
      triggerDisplays.removeValue(forKey: id)
    }
  }

  // MARK: - Reconfiguration Handling

  /// The C callback can't capture context, so `self` is recovered from the
  /// `userInfo` we registered with. It fires at least twice per change (a
  /// begin pass and an after pass, per display); every non-begin pass just
  /// (re)schedules the debounced reconcile — presence diffing does the rest,
  /// so the per-display add/remove flags don't need interpreting here.
  private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = {
    _, flags, userInfo in
    guard !flags.contains(.beginConfigurationFlag), let userInfo = userInfo else { return }
    let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { monitor.scheduleReconcile() }
  }

  private func scheduleReconcile() {
    reconcileTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + Constants.reconcileDebounce)
    timer.setEventHandler { [weak self] in self?.reconcile() }
    timer.resume()
    reconcileTimer = timer
  }

  /// Diff the online displays against `presentUUIDs` (runs on main).
  /// Additions are dock edges unless the wake settle window says they're
  /// re-appearances; removals just leave the set — undocking takes no action
  /// (closing the lid usually follows, and the sleep handoff owns that).
  private func reconcile() {
    reconcileTimer?.cancel()
    reconcileTimer = nil

    let online = Self.onlineExternalDisplays()
    let onlineIDs = Set(online.map { $0.id })
    let appeared = onlineIDs.subtracting(presentUUIDs)
    presentUUIDs = onlineIDs
    if connectedDisplays != online { connectedDisplays = online }
    refreshTriggerNames(from: online)

    guard !appeared.isEmpty else { return }
    let settling = Date() < wakeSettleDeadline
    let triggered = online.filter { display in
      appeared.contains(display.id)
        && triggerDisplays[display.id] != nil
        && !(settling && presentAtSleep.contains(display.id))
    }
    guard !triggered.isEmpty else { return }
    print("DisplayMonitor: trigger display(s) connected: \(triggered.map { $0.name })")
    onTriggerDisplaysConnected?(triggered.map { $0.name })
  }

  // MARK: - Sleep Handling

  /// Snapshot what's present *before* the sleep transition churns it, and
  /// drop any pending reconcile — acting between here and the actual sleep
  /// would race the radio/network teardown. Whatever really changed is
  /// re-observed by the wake reconcile; that includes a display plugged in
  /// moments before the lid closed, which (correctly) fires at wake because
  /// this pre-churn snapshot doesn't contain it.
  private func noteWillSleep() {
    reconcileTimer?.cancel()
    reconcileTimer = nil
    presentAtSleep = presentUUIDs
  }

  /// Open the settle window and force a reconcile: if the display picture
  /// changed while we slept there may be no further callback to prompt one,
  /// and a reconcile cancelled by `noteWillSleep` must not stay lost.
  private func noteDidWake() {
    wakeSettleDeadline = Date().addingTimeInterval(Constants.wakeSettleWindow)
    scheduleReconcile()
  }

  // MARK: - Display Enumeration

  /// Online external displays, by stable UUID, sorted by name. "Online"
  /// (`CGGetOnlineDisplayList`) deliberately includes mirrored and sleeping
  /// displays — presence is about the cable, not what's drawn. Built-in
  /// panels are excluded: they can't be docked, so they can't be triggers.
  private static func onlineExternalDisplays() -> [ExternalDisplay] {
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(Constants.maxDisplays))
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(Constants.maxDisplays, &ids, &count) == .success else {
      print("DisplayMonitor: CGGetOnlineDisplayList failed")
      return []
    }
    let displays: [ExternalDisplay] = ids.prefix(Int(count)).compactMap { id in
      guard CGDisplayIsBuiltin(id) == 0 else { return nil }
      guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
        // Virtual/headless entries can lack a UUID; they can't be triggers.
        return nil
      }
      return ExternalDisplay(
        id: CFUUIDCreateString(nil, uuid) as String,
        name: displayName(for: id))
    }
    return displays.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// User-facing name for a display, from the matching `NSScreen`. A display
  /// that's online but not active has no screen; fall back to a generic label.
  private static func displayName(for id: CGDirectDisplayID) -> String {
    let match = NSScreen.screens.first { screen in
      let key = NSDeviceDescriptionKey("NSScreenNumber")
      return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == id
    }
    return match?.localizedName ?? "External Display"
  }

  // MARK: - Persistence

  /// Keep remembered names in sync with what the OS reports, so a renamed or
  /// re-localized display doesn't leave a stale label in Settings.
  private func refreshTriggerNames(from online: [ExternalDisplay]) {
    var updated = triggerDisplays
    for display in online where updated[display.id] != nil && updated[display.id] != display.name {
      updated[display.id] = display.name
    }
    if updated != triggerDisplays { triggerDisplays = updated }
  }

  private func saveTriggerDisplays() {
    do {
      triggerDisplaysData = try JSONEncoder().encode(triggerDisplays)
    } catch {
      print("Failed to save trigger displays: \(error)")
    }
  }

  private func loadTriggerDisplays() {
    guard !triggerDisplaysData.isEmpty else { return }
    do {
      triggerDisplays = try JSONDecoder().decode([String: String].self, from: triggerDisplaysData)
    } catch {
      print("Failed to load trigger displays: \(error)")
    }
  }
}
