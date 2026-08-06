import Combine
import Foundation

/// Best-effort check for a newer published release on GitHub.
///
/// Magic Switch ships via semantic-release, which publishes one GitHub Release
/// per `vX.Y.Z` tag, so `releases/latest` is the canonical "newest stable
/// version" — a single unauthenticated request, no pagination. Automatic
/// checks are silent (a network/parse failure leaves the last known state
/// untouched); a manual check — the Check-for-Updates button — surfaces its
/// result. An hourly timer re-evaluates a 24h gate
/// (both persisted in `UserDefaults`), so the network is hit at most once per
/// day, while a transient failure — which doesn't advance the gate — is retried
/// on the next tick instead of waiting for a relaunch. Results drive the
/// right-click menu and the Settings → Other tab; we never auto-update, just
/// link to the release page.
final class UpdateChecker: ObservableObject {
  // MARK: - Singleton

  static let shared = UpdateChecker()

  // MARK: - Constants

  private enum Constants {
    /// Owner/repo whose published Releases define the latest version. Casing
    /// matches the existing GitHub links elsewhere in the app; GitHub treats
    /// owner/repo case-insensitively regardless.
    static let repoSlug = "MegaManSec/magic-switch"
    /// `releases/latest` resolves to the most recent non-draft, non-prerelease
    /// release — exactly what semantic-release publishes.
    static let latestReleaseAPI = "https://api.github.com/repos/\(repoSlug)/releases/latest"
    /// Browser page the menu / Settings open. `/releases/latest` redirects to
    /// the newest release, so it's correct without parsing anything.
    static let latestReleasePage = "https://github.com/\(repoSlug)/releases/latest"
    /// GitHub's API rejects requests without a User-Agent (403).
    static let userAgent = "Magic-Switch"
    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// Timer cadence. Each tick just re-checks the 24h gate, so it rarely fires
    /// a real request; it mainly bounds how soon a failed check is retried.
    static let pollInterval: TimeInterval = 60 * 60
    static let requestTimeout: TimeInterval = 10
    /// Persisted state, namespaced like the rest of the app's UserDefaults keys.
    static let lastCheckedKey = "com.magicswitch.updatecheck.lastChecked"
    static let latestVersionKey = "com.magicswitch.updatecheck.latestVersion"
    /// Last version announced via system notification — one banner per
    /// version, however many checks rediscover it.
    static let notifiedVersionKey = "com.magicswitch.updatecheck.notifiedVersion"
    /// Stable notification identifier, so re-posts replace rather than stack
    /// and a delivered banner can be retired once the update is installed.
    static let updateNotificationID = "update-available"
  }

  // MARK: - Published State

  /// Newest version advertised by GitHub (e.g. "2.4.0"), or nil if we've never
  /// fetched one successfully. Mutated on main only.
  @Published private(set) var latestVersion: String?

  // MARK: - Properties

  /// Browser URL for the latest release. `nil` only if the constant is ever
  /// malformed; callers guard on it.
  let releasePageURL = URL(string: Constants.latestReleasePage)

  /// Stable identifier of the update notification, exposed so the
  /// notification-click router in `AppDelegate` can match on it.
  static var updateNotificationIdentifier: String { Constants.updateNotificationID }

  /// True while a check is in flight; drives the "Checking…" state on the
  /// manual Check-for-Updates button, and guards against overlapping checks.
  /// Main-thread only.
  @Published private(set) var isChecking = false

  /// Set when a *manual* check fails to reach GitHub, so the button can say so.
  /// Automatic checks stay silent. Main-thread only.
  @Published private(set) var lastCheckFailed = false

  /// Hourly poll, retained for the singleton's lifetime, so a long-running app
  /// re-checks (and retries failures) without needing a relaunch.
  private var pollTimer: DispatchSourceTimer?

  // MARK: - Computed Properties

  /// The running app's marketing version, e.g. "2.3.1". Debug builds report
  /// the placeholder "0.0.0" (semantic-release patches `MARKETING_VERSION`
  /// only in CI), which is one reason the check is suppressed in `#if DEBUG`.
  var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }

  /// True when GitHub advertises a strictly-greater semantic version.
  var updateAvailable: Bool {
    guard let latest = latestVersion else { return false }
    return Self.isNewer(latest, than: currentVersion)
  }

  // MARK: - Initialization

  private init() {
    // Surface the cached result immediately so the menu / Settings reflect the
    // last successful check without waiting for a network round trip.
    latestVersion = UserDefaults.standard.string(forKey: Constants.latestVersionKey)
    if !updateAvailable {
      // The cached "newer" version is usually the one now running — the user
      // just updated — so retire a delivered update banner rather than leave
      // it stale in Notification Centre.
      NotificationManager.removeNotification(identifier: Constants.updateNotificationID)
    }
    startPolling()
  }

  /// Tick hourly and let `checkIfNeeded` decide whether the 24h gate has
  /// opened. A failed attempt doesn't advance the gate, so a transient error
  /// self-heals on the next tick (~1h) instead of waiting for a relaunch. The
  /// first tick is one interval out — app launch does the immediate check.
  private func startPolling() {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    timer.schedule(deadline: .now() + Constants.pollInterval, repeating: Constants.pollInterval)
    timer.setEventHandler { [weak self] in self?.checkIfNeeded() }
    timer.resume()
    pollTimer = timer
  }

  // MARK: - Public Methods

  /// Fetch the latest release if it's been at least 24h since the last
  /// successful check. Returns immediately; `latestVersion` updates
  /// asynchronously on success. Called on the main thread from app launch, the
  /// Settings `onAppear`, and the hourly `pollTimer`.
  func checkIfNeeded() {
    if let last = UserDefaults.standard.object(forKey: Constants.lastCheckedKey) as? Date,
      Date().timeIntervalSince(last) < Constants.checkInterval
    {
      return
    }
    check()
  }

  /// Force a check now, ignoring the 24h cadence — the manual "Check for
  /// Updates" button. Runs in Debug too (it's an explicit user action, not an
  /// auto-nag), so the button works in every build.
  func checkNow() {
    performCheck(manual: true)
  }

  // MARK: - Private Methods

  /// Automatic check — suppressed in Debug so a dev build (version "0.0.0")
  /// doesn't nag that every release is newer. Mirrors exodus-deps-tui skipping
  /// the check when run from a source checkout.
  private func check() {
    #if DEBUG
      return
    #else
      performCheck(manual: false)
    #endif
  }

  /// The actual network fetch. A `manual` check surfaces success/failure on the
  /// button; automatic ones stay silent. One in-flight request at a time.
  private func performCheck(manual: Bool) {
    guard !isChecking else { return }
    guard let url = URL(string: Constants.latestReleaseAPI) else { return }
    isChecking = true
    if manual { lastCheckFailed = false }

    var request = URLRequest(url: url)
    request.timeoutInterval = Constants.requestTimeout
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue(Constants.userAgent, forHTTPHeaderField: "User-Agent")

    URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
      let version: String? = {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
          let data = data, let tag = Self.parseTagName(from: data)
        else { return nil }
        return Self.normalize(tag)
      }()

      DispatchQueue.main.async {
        guard let self = self else { return }
        self.isChecking = false
        guard let version = version else {
          // Only a manual check surfaces the failure; auto checks stay silent
          // and just retry on the next hourly tick.
          if manual { self.lastCheckFailed = true }
          return
        }
        // Only record success: a transient failure shouldn't suppress the
        // next launch's retry for a full 24h.
        UserDefaults.standard.set(Date(), forKey: Constants.lastCheckedKey)
        UserDefaults.standard.set(version, forKey: Constants.latestVersionKey)
        self.latestVersion = version
        self.reconcileUpdateNotification(manual: manual)
      }
    }.resume()
  }

  /// One notification per discovered version, and only from automatic checks —
  /// a manual check's result is already on screen next to the button that
  /// triggered it. The version is recorded as announced only once the banner
  /// is accepted for delivery, so a post lost to the launch-time permission
  /// race (or to denied notifications) stays eligible for the next automatic
  /// check. A check that finds no update retires any delivered banner
  /// (the update was installed, or GitHub stopped advertising it). Main-only,
  /// called from `performCheck`'s completion.
  private func reconcileUpdateNotification(manual: Bool) {
    guard updateAvailable, let latest = latestVersion else {
      NotificationManager.removeNotification(identifier: Constants.updateNotificationID)
      return
    }
    guard !manual,
      UserDefaults.standard.string(forKey: Constants.notifiedVersionKey) != latest
    else { return }
    NotificationManager.showNotification(
      title: "Update Available",
      body:
        "Magic Switch v\(latest) is available (you have v\(currentVersion)). Click to open the download page.",
      identifier: Constants.updateNotificationID
    ) { error in
      guard error == nil else { return }
      UserDefaults.standard.set(latest, forKey: Constants.notifiedVersionKey)
    }
  }

  /// Pull `tag_name` out of the `releases/latest` JSON without a model type.
  private static func parseTagName(from data: Data) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tag = obj["tag_name"] as? String
    else { return nil }
    return tag
  }

  /// Strip a leading "v" so a `vX.Y.Z` tag compares against the bare
  /// `CFBundleShortVersionString`.
  private static func normalize(_ tag: String) -> String {
    tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
  }

  /// Numeric per-component semver compare. Missing/non-numeric components are
  /// treated as 0, so "2.4" < "2.4.1" and a longer prefix-equal version wins.
  static func isNewer(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
      let x = i < pa.count ? pa[i] : 0
      let y = i < pb.count ? pb[i] : 0
      if x != y { return x > y }
    }
    return false
  }
}
