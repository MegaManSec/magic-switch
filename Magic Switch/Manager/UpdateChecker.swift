import Combine
import Foundation

#if !APP_STORE
  import Sparkle
#endif

/// In-app updates for the GitHub build, through Sparkle. App Store builds
/// update through the App Store and only report their version.
final class UpdateChecker: NSObject, ObservableObject {
  // MARK: - Singleton

  static let shared = UpdateChecker()

  // MARK: - Computed Properties

  var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }

  #if !APP_STORE
    // MARK: - Constants

    static let updateNotificationIdentifier = "update-available"
    static let updateInstalledNotificationIdentifier = "update-installed"
    private static let availableVersionKey = "com.magicswitch.updatecheck.latestVersion"
    private static let notifiedVersionKey = "com.magicswitch.updatecheck.notifiedVersion"
    private static let lastLaunchedVersionKey = "com.magicswitch.updatecheck.lastLaunchedVersion"

    // MARK: - Published State

    /// Version found by a scheduled check that the user hasn't looked at yet.
    @Published private(set) var availableVersion: String?
    @Published private(set) var canCheckForUpdates = false

    // MARK: - Properties

    private var controller: SPUStandardUpdaterController?
    private var canCheckObserver: AnyCancellable?
    private var checkWhenReady = false

    var installedReleaseNotesURL: URL? {
      URL(string: "https://github.com/MegaManSec/magic-switch/releases/tag/v\(currentVersion)")
    }

    var automaticallyChecksForUpdates: Bool {
      get { controller?.updater.automaticallyChecksForUpdates ?? false }
      set {
        objectWillChange.send()
        controller?.updater.automaticallyChecksForUpdates = newValue
      }
    }

    // MARK: - Public Methods

    func start() {
      guard controller == nil else { return }
      restoreAnnouncement()
      announceInstalledUpdate()
      let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
      self.controller = controller
      canCheckObserver = controller.updater.publisher(for: \.canCheckForUpdates)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] canCheck in self?.canCheckForUpdatesChanged(canCheck) }
      controller.startUpdater()
      objectWillChange.send()
    }

    /// Checks now, or brings an update Sparkle already found back into focus.
    /// While Sparkle is busy the request waits until it can act on it.
    func checkForUpdates() {
      guard let controller, controller.updater.canCheckForUpdates else {
        checkWhenReady = true
        return
      }
      checkWhenReady = false
      controller.checkForUpdates(nil)
    }

    // MARK: - Private Methods

    private func canCheckForUpdatesChanged(_ canCheck: Bool) {
      canCheckForUpdates = canCheck
      if canCheck, checkWhenReady { checkForUpdates() }
    }

    private func restoreAnnouncement() {
      if let version = UserDefaults.standard.string(forKey: Self.availableVersionKey),
        SUStandardVersionComparator.default.compareVersion(version, toVersion: currentVersion)
          == .orderedDescending
      {
        availableVersion = version
      } else {
        UserDefaults.standard.removeObject(forKey: Self.availableVersionKey)
        NotificationManager.removeNotification(identifier: Self.updateNotificationIdentifier)
      }
    }

    private func announceInstalledUpdate() {
      guard currentVersion != "0.0.0" else { return }
      let previous = UserDefaults.standard.string(forKey: Self.lastLaunchedVersionKey)
      UserDefaults.standard.set(currentVersion, forKey: Self.lastLaunchedVersionKey)
      // Sparkle sets SUHasLaunchedBefore when its updater first starts, so with
      // no recorded version it means an earlier Sparkle-enabled version ran.
      let updated =
        previous.map {
          SUStandardVersionComparator.default.compareVersion(currentVersion, toVersion: $0)
            == .orderedDescending
        } ?? UserDefaults.standard.bool(forKey: "SUHasLaunchedBefore")
      guard updated else { return }
      NotificationManager.showNotification(
        title: String(localized: "Magic Switch Updated"),
        body: String(localized: "You're now on v\(currentVersion). Click to see what's new."),
        identifier: Self.updateInstalledNotificationIdentifier
      )
    }

    private func announce(_ version: String) {
      availableVersion = version
      UserDefaults.standard.set(version, forKey: Self.availableVersionKey)
      guard UserDefaults.standard.string(forKey: Self.notifiedVersionKey) != version else { return }
      NotificationManager.showNotification(
        title: String(localized: "Update Available"),
        body: String(
          localized:
            "Magic Switch v\(version) is available (you have v\(currentVersion)). Click to install it."
        ),
        identifier: Self.updateNotificationIdentifier
      ) { error in
        guard error == nil else { return }
        UserDefaults.standard.set(version, forKey: Self.notifiedVersionKey)
      }
    }

    private func clearAnnouncement() {
      availableVersion = nil
      UserDefaults.standard.removeObject(forKey: Self.availableVersionKey)
      NotificationManager.removeNotification(identifier: Self.updateNotificationIdentifier)
    }
  #endif
}

#if !APP_STORE
  // MARK: - SPUUpdaterDelegate

  extension UpdateChecker: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
      #if DEBUG
        if updateCheck == .updatesInBackground {
          throw NSError(
            domain: "com.megamansec.magic-switch.updates", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Debug builds only check for updates on request."]
          )
        }
      #endif
    }
  }

  // MARK: - SPUStandardUserDriverDelegate

  extension UpdateChecker: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
      _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
      false
    }

    func standardUserDriverWillHandleShowingUpdate(
      _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
      guard !state.userInitiated else { return }
      announce(update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
      clearAnnouncement()
    }

    func standardUserDriverWillFinishUpdateSession() {
      clearAnnouncement()
    }
  }
#endif
