import Combine
import Foundation

/// Best-effort check for a newer published release on GitHub.
///
/// Magic Switch ships via semantic-release, which publishes one GitHub Release
/// per `vX.Y.Z` tag, so `releases/latest` is the canonical "newest stable
/// version" — a single unauthenticated request, no pagination. The check is
/// silent: any network/parse failure leaves the last known state untouched and
/// is never surfaced to the user. An hourly timer re-evaluates a 24h gate
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
  }

  // MARK: - Published State

  /// Newest version advertised by GitHub (e.g. "2.4.0"), or nil if we've never
  /// fetched one successfully. Mutated on main only.
  @Published private(set) var latestVersion: String?

  // MARK: - Properties

  /// Browser URL for the latest release. `nil` only if the constant is ever
  /// malformed; callers guard on it.
  let releasePageURL = URL(string: Constants.latestReleasePage)

  /// Guards against overlapping in-flight checks within a session (e.g. the
  /// user reopening Settings repeatedly). Main-thread only.
  private var isChecking = false

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
    guard !isChecking else { return }
    if let last = UserDefaults.standard.object(forKey: Constants.lastCheckedKey) as? Date,
      Date().timeIntervalSince(last) < Constants.checkInterval
    {
      return
    }
    check()
  }

  // MARK: - Private Methods

  private func check() {
    #if DEBUG
      // Don't nag during development — a dev build's version is the "0.0.0"
      // placeholder, so every release would look newer. Mirrors
      // exodus-deps-tui suppressing the check when run from a source checkout.
      return
    #else
      guard let url = URL(string: Constants.latestReleaseAPI) else { return }
      isChecking = true

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
          // Only record success: a transient failure shouldn't suppress the
          // next launch's retry for a full 24h.
          guard let version = version else { return }
          UserDefaults.standard.set(Date(), forKey: Constants.lastCheckedKey)
          UserDefaults.standard.set(version, forKey: Constants.latestVersionKey)
          self.latestVersion = version
        }
      }.resume()
    #endif
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
