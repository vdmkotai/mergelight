import AppKit
import MergelightKit
import Observation

/// Single source of truth for the UI: session, dashboard, per-row state and every user action.
///
/// Network work happens in `GitHubClient` off the main actor; this type only sequences it and
/// publishes results. Views and the status item observe it through Observation.
@MainActor
@Observable
final class AppModel {
  enum Session: Equatable {
    case loading
    case signedOut
    case signedIn(login: String)
  }

  enum Busy: Equatable {
    case merging, updatingBranch, rerunning, autoMerge, markingReady

    var title: String {
      switch self {
      case .merging: "Merging…"
      case .updatingBranch: "Updating…"
      case .rerunning: "Re-running…"
      case .autoMerge: "Saving…"
      case .markingReady: "Updating…"
      }
    }
  }

  enum DetailState: Equatable {
    case loading(previous: PullRequestDetail?)
    case loaded(PullRequestDetail, key: String)
    case failed(String, key: String)

    var detail: PullRequestDetail? {
      switch self {
      case .loading(let previous): previous
      case .loaded(let detail, _): detail
      case .failed: nil
      }
    }
  }

  struct MergeDraft: Equatable {
    let pr: PullRequest
    var method: MergeMethod
    var deleteBranch: Bool
    let asAdmin: Bool
  }

  struct Banner: Equatable, Identifiable {
    enum Kind { case info, error }
    let id = UUID()
    let kind: Kind
    let text: String
  }

  enum DeviceFlowState: Equatable {
    case starting
    case waiting(DeviceFlow.Code)
  }

  // MARK: - Observed state

  private(set) var session: Session = .loading
  var settings: AppSettings {
    didSet { settingsDidChange(from: oldValue) }
  }
  private(set) var dashboard: Dashboard?
  private(set) var isRefreshing = false
  private(set) var lastError: GitHubError?
  private(set) var details: [String: DetailState] = [:]
  private(set) var busy: [String: Busy] = [:]
  private(set) var banner: Banner?
  private(set) var deviceFlow: DeviceFlowState?
  private(set) var signInError: String?

  var selectedTab: SectionConfig.Tab = .mine
  var filter = ""
  var expanded: Set<String> = []
  var mergeDraft: MergeDraft?
  /// Tallest the panel may get on the current screen; set by the panel before showing.
  var panelMaxHeight: CGFloat = 640

  var panelVisible = false {
    didSet {
      guard panelVisible != oldValue else { return }
      if panelVisible { panelDidOpen() } else { scheduler.reschedule() }
    }
  }

  var isSignedIn: Bool {
    if case .signedIn = session { return true }
    return false
  }

  var viewerLogin: String? {
    if case .signedIn(let login) = session, !login.isEmpty { return login }
    return dashboard?.viewerLogin
  }

  /// Data is older than a few refresh cycles, e.g. while offline.
  var isStale: Bool {
    guard let fetchedAt = dashboard?.fetchedAt else { return lastError != nil }
    return Date.now.timeIntervalSince(fetchedAt) > max(settings.refreshInterval * 3, 180)
  }

  // MARK: - Private state

  @ObservationIgnored private var fetch: DashboardFetch?
  @ObservationIgnored private var client: GitHubClient?
  /// PRs merged or closed from this app, hidden until GitHub reports them closed.
  @ObservationIgnored private var locallyClosed: [String: Date] = [:]
  /// Dashboard the next refresh is diffed against for notifications.
  @ObservationIgnored private var diffBaseline: Dashboard?
  @ObservationIgnored private var consecutiveFailures = 0
  /// Bumped on every sign-in and sign-out. Async work started under an older value is dropped
  /// when it finishes, so one account's data never lands in another's session.
  @ObservationIgnored private var generation = 0
  /// Set when GitHub answers "rate limited"; no requests go out before this time.
  @ObservationIgnored private var rateLimitedUntil: Date?
  @ObservationIgnored private var deviceFlowID: UUID?
  @ObservationIgnored private var scheduler: RefreshScheduler!
  @ObservationIgnored private var systemEvents: SystemEvents?
  @ObservationIgnored private var saveSettingsTask: Task<Void, Never>?
  @ObservationIgnored private var saveSnapshotTask: Task<Void, Never>?
  @ObservationIgnored private var refetchTask: Task<Void, Never>?
  @ObservationIgnored private var bannerTask: Task<Void, Never>?
  @ObservationIgnored private var deviceFlowTask: Task<Void, Never>?

  @ObservationIgnored private let tokenStore = KeychainTokenStore()
  @ObservationIgnored private let cache = SnapshotCache(fileURL: SnapshotCache.defaultURL)
  @ObservationIgnored private let defaults = UserDefaults.standard
  @ObservationIgnored let notifier = Notifier()

  private static let settingsKey = "settings.v1"
  /// Hide locally merged PRs at most this long if GitHub never confirms.
  private static let locallyClosedTTL: TimeInterval = 120
  /// Cached snapshots older than this are shown but not diffed, to avoid a burst of stale alerts.
  private static let baselineMaxAge: TimeInterval = 600

  init() {
    settings =
      UserDefaults.standard.data(forKey: Self.settingsKey)
      .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    scheduler = RefreshScheduler(
      perform: { [weak self] trigger in await self?.refresh(trigger) },
      nextDelay: { [weak self] in self?.nextDelay() ?? 60 })
  }

  // MARK: - Lifecycle

  func start() {
    if let cached = cache.load() {
      fetch = cached
      rebuild()
      if Date.now.timeIntervalSince(cached.fetchedAt) < Self.baselineMaxAge {
        diffBaseline = dashboard
      }
    }
    systemEvents = SystemEvents(
      onWake: { [weak self] in
        // Give Wi-Fi a moment to come back before the first request.
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(3))
          self?.scheduler.fire(.full)
        }
      },
      onNetworkRestored: { [weak self] in self?.scheduler.fire(.full) })

    Task { await restoreSession() }
  }

  private func restoreSession() async {
    // Keychain calls can block on a system prompt; keep them off the main thread.
    let store = tokenStore
    let token: String?
    do {
      token = try await Task.detached { try store.read() }.value
    } catch {
      token = nil
      signInError = "Couldn't read the token from Keychain: \(error.localizedDescription)"
    }
    guard let token else {
      session = .signedOut
      return
    }
    client = GitHubClient(token: token)
    session = .signedIn(login: fetch?.viewerLogin ?? "")
    if settings.sections.isEmpty { await createDefaultSections() }
    if settings.notifications.anyEnabled { notifier.requestAuthorization() }
    scheduler.start()
  }

  // MARK: - Sign in / out

  func signInWithGitHubCLI() async {
    signInError = nil
    do {
      try await signIn(token: GitHubCLI.token())
    } catch {
      signInError = error.localizedDescription
    }
  }

  func signIn(withPastedToken token: String) async {
    signInError = nil
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { return }
    do {
      try await signIn(token: token)
    } catch {
      signInError = error.localizedDescription
    }
  }

  func startDeviceFlow() {
    guard let clientID = AppInfo.gitHubClientID else { return }
    signInError = nil
    deviceFlow = .starting
    deviceFlowTask?.cancel()
    let id = UUID()
    deviceFlowID = id
    deviceFlowTask = Task {
      let flow = DeviceFlow(clientID: clientID)
      do {
        let code = try await flow.start()
        guard deviceFlowID == id else { return }
        deviceFlow = .waiting(code)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.userCode, forType: .string)
        NSWorkspace.shared.open(code.verificationURL)
        let token = try await flow.waitForToken(code)
        try await signIn(token: token)
      } catch is CancellationError {
      } catch let error as URLError where error.code == .cancelled {
      } catch {
        if deviceFlowID == id { signInError = error.localizedDescription }
      }
      // A newer flow may have started meanwhile; leave its state alone.
      if deviceFlowID == id { deviceFlow = nil }
    }
  }

  func cancelDeviceFlow() {
    deviceFlowTask?.cancel()
    deviceFlowID = nil
    deviceFlow = nil
  }

  private func signIn(token: String) async throws {
    let client = GitHubClient(token: token)
    let viewer = try await client.viewer()
    let store = tokenStore
    try await Task.detached { try store.write(token) }.value
    generation += 1
    scheduler.stop()
    self.client = client
    if fetch?.viewerLogin != viewer.login {
      clearData()
    }
    // Default sections embed the login and organizations; another account needs its own.
    let otherAccount = settings.sectionsOwner.map { $0 != viewer.login } ?? false
    if settings.sections.isEmpty || otherAccount {
      settings.sections = DefaultSections.make(login: viewer.login, organizations: viewer.organizations)
    }
    settings.sectionsOwner = viewer.login
    rateLimitedUntil = nil
    consecutiveFailures = 0
    session = .signedIn(login: viewer.login)
    lastError = nil
    if settings.notifications.anyEnabled { notifier.requestAuthorization() }
    scheduler.start()
  }

  func signOut() {
    generation += 1
    scheduler.stop()
    let store = tokenStore
    Task.detached { try? store.delete() }
    client = nil
    clearData()
    session = .signedOut
  }

  private func clearData() {
    fetch = nil
    dashboard = nil
    diffBaseline = nil
    details = [:]
    expanded = []
    locallyClosed = [:]
    // Through the save chain, so a queued save can't recreate the file afterwards.
    let cache = cache
    let previousSave = saveSnapshotTask
    saveSnapshotTask = Task.detached(priority: .utility) {
      await previousSave?.value
      cache.clear()
    }
  }

  private func createDefaultSections() async {
    guard let client else { return }
    do {
      let viewer = try await client.viewer()
      if settings.sections.isEmpty {
        settings.sections = DefaultSections.make(login: viewer.login, organizations: viewer.organizations)
        settings.sectionsOwner = viewer.login
      }
    } catch {
      lastError = error
    }
  }

  func resetSectionsToDefaults() async {
    guard let client else { return }
    do {
      let viewer = try await client.viewer()
      settings.sections = DefaultSections.make(login: viewer.login, organizations: viewer.organizations)
      settings.sectionsOwner = viewer.login
    } catch {
      show(.error, error.localizedDescription)
    }
  }

  // MARK: - Refresh

  func refreshNow() { scheduler.fire(.full) }

  private func panelDidOpen() {
    reloadExpandedDetails()
    let policy = RefreshPolicy(baseInterval: settings.refreshInterval)
    switch policy.kindOnPanelOpen(searchedAt: fetch?.searchedAt, fetchedAt: fetch?.fetchedAt) {
    case .full: scheduler.fire(.full)
    case .status: scheduler.fire(.status)
    case nil: scheduler.reschedule()
    }
  }

  private func nextDelay() -> TimeInterval {
    let delay = RefreshPolicy(baseInterval: settings.refreshInterval).nextDelay(
      hasActivity: dashboard?.hasActivity ?? false, panelVisible: panelVisible,
      consecutiveFailures: consecutiveFailures, rateLimit: fetch?.rateLimit)
    guard let until = rateLimitedUntil else { return delay }
    return max(delay, until.timeIntervalSinceNow + 1)
  }

  private func refresh(_ trigger: RefreshScheduler.Trigger) async {
    guard let client, isSignedIn else { return }
    // Rate limited: every trigger (panel open, follow-ups) waits for the reset.
    if let until = rateLimitedUntil, until > .now { return }
    let generation = generation
    let configs = settings.sections.filter(\.isEnabled)
    let policy = RefreshPolicy(baseInterval: settings.refreshInterval)
    let kind: RefreshPolicy.Kind =
      switch trigger {
      case .full: .full
      case .status, .scheduled:
        // Results answering outdated queries need a search no matter what was asked.
        if let fetch, configs.allSatisfy({ fetch.results[$0.id]?.query == $0.effectiveQuery }) {
          trigger == .status ? .status : policy.kind(searchedAt: fetch.searchedAt)
        } else {
          .full
        }
      }

    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let result: DashboardFetch
      if kind == .status, let fetch {
        result = try await client.refreshStatuses(of: fetch)
      } else {
        result = try await client.dashboard(sections: configs)
      }
      guard generation == self.generation else { return }
      consecutiveFailures = 0
      lastError = nil
      rateLimitedUntil = nil
      apply(result)
    } catch {
      guard generation == self.generation else { return }
      consecutiveFailures += 1
      lastError = error
      if case .rateLimited(let resetAt) = error {
        rateLimitedUntil = resetAt ?? .now.addingTimeInterval(60)
      }
      if error == .unauthorized {
        scheduler.stop()
        session = .signedOut
        signInError = error.localizedDescription
      }
    }
  }

  private func apply(_ result: DashboardFetch) {
    let new = result.carryingOver(from: fetch)
    // GitHub reports a PR we merged as merged (or it vanished): stop hiding it manually.
    let open = Set(new.results.values.flatMap(\.pullRequests).filter { $0.state == .open }.map(\.id))
    locallyClosed = locallyClosed.filter { id, date in
      open.contains(id) && Date.now.timeIntervalSince(date) < Self.locallyClosedTTL
    }

    fetch = new
    if settings.sectionsOwner == nil { settings.sectionsOwner = new.viewerLogin }
    rebuild()
    // After a long gap (sleep, offline) the changes are old news; don't replay them.
    if let baseline = diffBaseline, let dashboard,
      baseline.sections.map(\.id) == dashboard.sections.map(\.id),
      new.fetchedAt.timeIntervalSince(baseline.fetchedAt) < Self.baselineMaxAge
    {
      handle(SnapshotDiff.events(from: baseline, to: dashboard))
    }
    diffBaseline = dashboard
    if panelVisible { reloadExpandedDetails() }

    // Chained so writes land in order; an older snapshot never overwrites a newer one.
    let cache = cache
    let previousSave = saveSnapshotTask
    saveSnapshotTask = Task.detached(priority: .utility) {
      await previousSave?.value
      try? cache.save(new)
    }
  }

  /// Re-derives the dashboard from the last fetch and current settings. Cheap; no network.
  private func rebuild() {
    guard let fetch else {
      dashboard = nil
      return
    }
    let new = Dashboard(
      fetch: fetch, configs: settings.sections, excluding: Set(locallyClosed.keys),
      showDrafts: settings.showDrafts)
    if new != dashboard { dashboard = new }
  }

  private func handle(_ events: [PullRequestEvent]) {
    var disappeared: [PullRequest] = []
    for event in events {
      if case .disappeared(let pr) = event {
        disappeared.append(pr)
      } else {
        notifier.post(event, settings: settings.notifications)
      }
    }
    guard settings.notifications.merged, !disappeared.isEmpty, let client else { return }
    let viewer = viewerLogin
    let generation = generation
    Task {
      guard let states = try? await client.states(of: disappeared.map(\.id)),
        generation == self.generation
      else { return }
      for state in states where state.state == .merged {
        guard let pr = disappeared.first(where: { $0.id == state.id }) else { continue }
        // Your own merges from the browser aren't news; auto-merges and other people's are.
        if state.mergedBy != viewer || pr.merge.autoMerge != nil {
          notifier.postMerged(pr, by: state.mergedBy)
        }
      }
    }
  }

  // MARK: - Settings

  private func settingsDidChange(from old: AppSettings) {
    saveSettingsTask?.cancel()
    saveSettingsTask = Task {
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      saveSettingsNow()
    }

    if settings.changesMembership(comparedTo: old) {
      // PRs moved between tabs or in and out of view: that's not news.
      diffBaseline = nil
    }
    if settings.requiresRefetch(comparedTo: old) {
      rebuild()
      // Debounced so typing a query doesn't fire a search per keystroke.
      refetchTask?.cancel()
      refetchTask = Task {
        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled else { return }
        scheduler.fire(.full)
      }
    } else {
      rebuild()
    }
    if settings.refreshInterval != old.refreshInterval { scheduler.reschedule() }
    if settings.notifications.anyEnabled && !old.notifications.anyEnabled {
      notifier.requestAuthorization()
    }
  }

  /// Writes settings immediately; also called on quit so a last-second change isn't lost.
  func saveSettingsNow() {
    saveSettingsTask?.cancel()
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: Self.settingsKey)
  }

  func toggleCollapsed(_ sectionID: UUID) {
    if settings.collapsedSectionIDs.contains(sectionID) {
      settings.collapsedSectionIDs.remove(sectionID)
    } else {
      settings.collapsedSectionIDs.insert(sectionID)
    }
  }

  // MARK: - Rows

  /// A click opens the PR in the default browser; ⌥-click shows its details instead.
  func rowClicked(_ pr: PullRequest) {
    if NSEvent.modifierFlags.contains(.option) {
      toggleExpanded(pr)
    } else {
      open(pr)
    }
  }

  func toggleExpanded(_ pr: PullRequest) {
    if expanded.contains(pr.id) {
      expanded.remove(pr.id)
    } else {
      expanded.insert(pr.id)
      loadDetail(pr)
    }
  }

  func loadDetail(_ pr: PullRequest, force: Bool = false) {
    guard let client else { return }
    let key = Self.detailKey(pr)
    if !force {
      switch details[pr.id] {
      case .loaded(_, let loadedKey) where loadedKey == key: return
      // A failure (e.g. SAML) is retried when the PR changes or on demand, not every refresh.
      case .failed(_, let failedKey) where failedKey == key: return
      case .loading: return
      default: break
      }
    }
    details[pr.id] = .loading(previous: details[pr.id]?.detail)
    let generation = generation
    Task {
      let state: DetailState
      do {
        state = .loaded(try await client.detail(pullRequestID: pr.id), key: key)
      } catch {
        state = .failed(error.localizedDescription, key: key)
      }
      guard generation == self.generation else { return }
      details[pr.id] = state
    }
  }

  /// Detail is reloaded only when something it shows could have changed.
  private static func detailKey(_ pr: PullRequest) -> String {
    let ci = pr.ci
    return [
      pr.headRefOid, "\(ci.passed)/\(ci.failed)/\(ci.running)", pr.merge.status.rawValue,
      pr.review.reviewers.map { "\($0.login)=\($0.state.rawValue)" }.joined(separator: ","),
      "\(pr.commentCount)", "\(pr.merge.autoMerge != nil)",
    ].joined(separator: "|")
  }

  private func reloadExpandedDetails() {
    guard let dashboard else { return }
    let visible = Dictionary(
      dashboard.sections.flatMap(\.pullRequests).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    expanded = expanded.filter { visible[$0] != nil }
    details = details.filter { visible[$0.key] != nil }
    for id in expanded { if let pr = visible[id] { loadDetail(pr) } }
  }

  // MARK: - Actions

  func open(_ pr: PullRequest) { NSWorkspace.shared.open(pr.url) }

  func open(_ url: URL) { NSWorkspace.shared.open(url) }

  func copyBranch(_ pr: PullRequest) {
    copy(pr.headRefName)
    show(.info, "Copied \(pr.headRefName)")
  }

  func copyURL(_ pr: PullRequest) {
    copy(pr.url.absoluteString)
    show(.info, "Copied link to #\(pr.number)")
  }

  private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }

  /// Merge entry point for buttons: merges right away in one-click mode, otherwise asks first.
  /// Admin merges and PRs with failing or running checks always ask.
  func requestMerge(_ pr: PullRequest, method: MergeMethod? = nil, asAdmin: Bool = false) {
    let method = method ?? pr.defaultMergeMethod(preferred: settings.preferredMergeMethod)
    let draft = MergeDraft(
      pr: pr, method: method, deleteBranch: settings.deleteBranchAfterMerge, asAdmin: asAdmin)
    if settings.mergeConfirmation == .oneClick && !asAdmin && pr.readiness == .ready {
      Task { await merge(draft) }
    } else {
      mergeDraft = draft
    }
  }

  func confirmMerge() {
    guard let draft = mergeDraft else { return }
    mergeDraft = nil
    Task { await merge(draft) }
  }

  private func merge(_ draft: MergeDraft) async {
    let pr = draft.pr
    let merged = await perform(.merging, on: pr, failure: "Couldn't merge #\(pr.number)") {
      client in try await client.merge(pr, method: draft.method)
    }
    guard merged, let client else { return }

    // Hide it now; the count in the menu bar drops before GitHub's search catches up.
    locallyClosed[pr.id] = .now
    rebuild()
    diffBaseline = dashboard
    show(.info, "Merged #\(pr.number)")

    if draft.deleteBranch && !pr.repository.deletesBranchOnMerge && !pr.isCrossRepository {
      do {
        try await client.deleteBranch(pr)
      } catch {
        show(.error, "Merged, but couldn't delete \(pr.headRefName): \(error.localizedDescription)")
      }
    }
    scheduler.fire(.status, followUps: [5, 20])
  }

  func updateBranch(_ pr: PullRequest) {
    Task {
      if await perform(.updatingBranch, on: pr, failure: "Couldn't update #\(pr.number)", { client in
        try await client.updateBranch(pr)
      }) {
        show(.info, "Updating #\(pr.number) with \(pr.baseRefName)")
        scheduler.fire(.status, followUps: [5, 15])
      }
    }
  }

  func markReady(_ pr: PullRequest) {
    Task {
      if await perform(.markingReady, on: pr, failure: "Couldn't mark #\(pr.number) ready", { client in
        try await client.markReadyForReview(pr)
      }) {
        scheduler.fire(.status, followUps: [5])
      }
    }
  }

  func setAutoMerge(_ pr: PullRequest, enabled: Bool) {
    let method = pr.defaultMergeMethod(preferred: settings.preferredMergeMethod)
    Task {
      if await perform(.autoMerge, on: pr, failure: "Couldn't change auto-merge for #\(pr.number)", { client in
        if enabled {
          try await client.enableAutoMerge(pr, method: method)
        } else {
          try await client.disableAutoMerge(pr)
        }
      }) {
        show(.info, enabled ? "Auto-merge enabled for #\(pr.number)" : "Auto-merge disabled for #\(pr.number)")
        scheduler.fire(.status, followUps: [5])
      }
    }
  }

  func rerunFailedChecks(_ pr: PullRequest) {
    Task {
      guard let client else { return }
      let detail: PullRequestDetail
      if let loaded = details[pr.id]?.detail {
        detail = loaded
      } else {
        do { detail = try await client.detail(pullRequestID: pr.id) } catch {
          show(.error, error.localizedDescription)
          return
        }
      }
      let runs = detail.failedWorkflowRunIDs
      guard !runs.isEmpty else {
        show(.error, "No failed GitHub Actions runs to re-run on #\(pr.number).")
        return
      }
      if await perform(.rerunning, on: pr, failure: "Couldn't re-run checks on #\(pr.number)", { client in
        try await client.rerunFailedJobs(pr, runIDs: runs)
      }) {
        show(.info, "Re-running \(runs.count == 1 ? "1 workflow" : "\(runs.count) workflows") on #\(pr.number)")
        scheduler.fire(.status, followUps: [5, 15])
      }
    }
  }

  /// Runs one mutation for a PR with a spinner in its row. Returns whether it succeeded.
  private func perform(
    _ kind: Busy, on pr: PullRequest, failure: String,
    _ operation: @escaping (GitHubClient) async throws -> Void
  ) async -> Bool {
    guard let client, busy[pr.id] == nil else { return false }
    let generation = generation
    busy[pr.id] = kind
    defer { busy[pr.id] = nil }
    do {
      try await operation(client)
      return generation == self.generation
    } catch {
      show(.error, "\(failure): \(error.localizedDescription)")
      scheduler.fire(.status)
      return false
    }
  }

  // MARK: - Banner

  func show(_ kind: Banner.Kind, _ text: String) {
    banner = Banner(kind: kind, text: text)
    bannerTask?.cancel()
    bannerTask = Task {
      try? await Task.sleep(for: .seconds(kind == .error ? 8 : 3))
      guard !Task.isCancelled else { return }
      banner = nil
    }
  }

  func dismissBanner() {
    bannerTask?.cancel()
    banner = nil
  }

  // MARK: - Derived view data

  /// Sections of the selected tab, with the filter applied.
  func visibleSections(for tab: SectionConfig.Tab) -> [Dashboard.Section] {
    guard let dashboard else { return [] }
    let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
    return dashboard.sections(in: tab).compactMap { section in
      guard !query.isEmpty else { return section.isVisible ? section : nil }
      let matches = section.pullRequests.filter { Self.matches($0, query) }
      guard !matches.isEmpty else { return nil }
      return section.filtered(to: matches)
    }
  }

  func count(in tab: SectionConfig.Tab) -> Int {
    Set(dashboard?.pullRequests(in: tab).map(\.id) ?? []).count
  }

  private static func matches(_ pr: PullRequest, _ query: String) -> Bool {
    if query.hasPrefix("#") { return "#\(pr.number)".hasPrefix(query) }
    return pr.title.lowercased().contains(query)
      || pr.repository.nameWithOwner.lowercased().contains(query)
      || pr.headRefName.lowercased().contains(query)
      || "\(pr.number)" == query
      || (pr.author?.login.lowercased().contains(query) ?? false)
  }
}
