import AppKit
import Combine
import Foundation

@MainActor
final class TokenBarStore: ObservableObject {
    @Published var snapshot: AppSnapshot = .empty {
        didSet {
            activitySummaries.removeAll(keepingCapacity: true)
            codexActivityCache = nil
        }
    }
    @Published var isRefreshing = false
    @Published private(set) var isResettingQuota = false
    @Published private(set) var estimateFailures: [String: String] = [:]

    private let freshnessInterval: TimeInterval = 3 * 60
    private let previewScenario: PreviewScenario?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var profileSyncAt: Date?
    private var claudeProfiles: [ClaudeAccountProfile] = []
    // Extra folders signed in to the primary folder's login, which its weekly estimate also counts.
    private var claudePrimaryAliases: [URL] = []
    // Every extra Claude folder counts toward Claude totals, even one that repeats a login.
    private var claudeDirectories: [URL] = []
    private var codexProfiles: [CodexAccountProfile] = []
    private let environmentSources: [AccountSource]
    // Rendering and hover text share totals; a new snapshot or calendar interval replaces them.
    private var activitySummaries: [ProviderScope: [ActivityPeriod: ActivitySummary]] = [:]
    private var codexActivityCache: [(activity: TokenActivity, ledger: CostLedger?)]?

    private struct ActivitySummary {
        let interval: DateInterval
        let tokens: Int64
        let estimatedCost: Double?
        let unmatchedTokens: Int64
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        previewScenario = PreviewScenario.current(environment: environment)
        environmentSources = [(ProviderScope.claude, "CLAUDE_CONFIG_DIR"), (.codex, "CODEX_HOME")].compactMap {
            guard let path = environment[$1].map({ ($0 as NSString).expandingTildeInPath }),
                  path.hasPrefix("/") else { return nil }
            return AccountSource(provider: $0, directory: URL(fileURLWithPath: path).standardizedFileURL.path)
        }
        if let previewScenario {
            snapshot = previewScenario.snapshot
        } else {
            loadSnapshot()
            if syncAccountProfiles() { saveSnapshot() }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func start() {
        guard previewScenario == nil else { return }
        refresh(
            force: snapshot.updatedAt == nil
                || snapshot.codexCostLedger?.recordedTokensByDay == nil
                || (snapshot.additionalCodexAccounts ?? []).contains { $0.costLedger?.recordedTokensByDay == nil }
                || snapshot.claudeCostLedger == nil
                || snapshot.imageGenerationUsage == nil
                || snapshot.claudeWeeklyValue.map { $0.resetsAt == nil } == true
                || snapshot.codexWeeklyValue.map { $0.resetsAt == nil } == true
                || (snapshot.codexWeeklyEstimateSource == nil
                    && snapshot.codex.headlinePercent != nil)
        )
    }

    func refreshIfStale() {
        refresh(force: false)
    }

    func confirmWeeklyReset(provider: ProviderScope, source: String, name: String) {
        guard previewScenario == nil, provider != .overview, !isRefreshing, !isResettingQuota else { return }
        let directory = URL(fileURLWithPath: (source as NSString).expandingTildeInPath).standardizedFileURL
        let isPrimary = directory == AccountSource.primaryDirectory(for: provider)
        let claudeProfile = isPrimary ? nil : claudeProfiles.first { $0.configDirectory == directory }
        let accountID = provider == .claude
            ? (isPrimary ? snapshot.claude.resetAccountID : snapshot.additionalClaudeAccounts?
                .first { $0.sourceDirectory == directory.path }?.quota.resetAccountID)
            : (isPrimary ? snapshot.codex.resetAccountID : snapshot.additionalCodexAccounts?
                .first { $0.sourceDirectory == directory.path }?.quota.resetAccountID)
        guard let accountID else {
            let alert = NSAlert()
            alert.messageText = "Account identity unavailable"
            alert.informativeText = "Refresh this account before using a reset."
            alert.runModal()
            refresh(providers: [provider], accounts: [directory.path])
            return
        }

        isResettingQuota = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset \(name)?"
        alert.informativeText = "Use one reset credit for this account? This cannot be undone.\n\n\(directory.path)"
        alert.addButton(withTitle: "Use 1 reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            isResettingQuota = false
            return
        }

        // A quit or timeout after spending must not restore a usable cached button.
        if isPrimary {
            if provider == .claude { snapshot.claude.resetCreditsFetched = false }
            else { snapshot.codex.resetCreditsFetched = false }
        } else if provider == .claude,
                  let index = snapshot.additionalClaudeAccounts?.firstIndex(where: { $0.sourceDirectory == directory.path }) {
            snapshot.additionalClaudeAccounts?[index].quota.resetCreditsFetched = false
        } else if let index = snapshot.additionalCodexAccounts?.firstIndex(where: { $0.sourceDirectory == directory.path }) {
            snapshot.additionalCodexAccounts?[index].quota.resetCreditsFetched = false
        }
        saveSnapshot()

        Task {
            defer {
                isResettingQuota = false
                refresh(providers: [provider], accounts: [directory.path])
            }
            do {
                if provider == .claude {
                    try await ClaudeClient().consumeWeeklyReset(profile: claudeProfile, expectedAccountID: accountID)
                } else {
                    try await CodexAppServerClient().consumeWeeklyReset(codexHome: directory, expectedAccountID: accountID)
                }
            } catch {
                let date = Date()
                if isPrimary {
                    if provider == .claude { recordFailure(error, in: &snapshot.claude, at: date) }
                    else { recordFailure(error, in: &snapshot.codex, at: date) }
                } else if provider == .claude, let claudeProfile {
                    _ = applyClaudeAccountResults([(claudeProfile.id, .failure(error))], profiles: [claudeProfile], at: date)
                } else if let index = snapshot.additionalCodexAccounts?.firstIndex(where: { $0.sourceDirectory == directory.path }) {
                    applyCodexAccountResult(.failure(error), at: index, date: date)
                }
                saveSnapshot()
                let failure = NSAlert(error: error)
                failure.messageText = "Reset failed for \(name)"
                failure.runModal()
            }
        }
    }

    /// Returns the configuration directories whose quota was requested.
    /// `accounts` narrows the refresh to those directories, so activity in one account leaves the others alone.
    @discardableResult
    func refresh(
        force: Bool = true,
        providers: Set<ProviderScope>? = nil,
        accounts: Set<String>? = nil,
        scanLocal: Bool = false
    ) -> Set<String> {
        guard previewScenario == nil, !isRefreshing, !isResettingQuota else { return [] }

        let attemptedAt = Date()
        let profilesChanged = (force || profileSyncAt.map {
            attemptedAt.timeIntervalSince($0) >= freshnessInterval
        } != false) && syncAccountProfiles(at: attemptedAt)
        func includes(_ provider: ProviderScope, _ directory: URL) -> Bool {
            (providers?.contains(provider) ?? true) && (accounts?.contains(directory.path) ?? true)
        }
        let claudeHome = AccountSource.primaryDirectory(for: .claude)
        let codexHome = AccountSource.primaryDirectory(for: .codex)
        let scanCodex = includes(.codex, codexHome)
        let scanClaude = ([claudeHome] + claudePrimaryAliases).contains { includes(.claude, $0) }
        let shouldRefreshCodex = scanCodex
            && shouldAttempt(snapshot.codex, force: force, at: attemptedAt)
        let shouldRefreshClaude = scanClaude
            && shouldAttempt(snapshot.claude, force: force, at: attemptedAt)
        let claudeAccountsToRefresh = claudeProfiles.filter { profile in
            let quota = snapshot.additionalClaudeAccounts?
                .first(where: { $0.id == profile.id })?.quota ?? .empty
            return ([profile.configDirectory] + profile.aliases).contains { includes(.claude, $0) }
                && shouldAttempt(quota, force: force, at: attemptedAt)
        }
        let codexAccountsToRefresh = codexProfiles.filter { profile in
            let quota = snapshot.additionalCodexAccounts?
                .first(where: { $0.id == profile.id })?.quota ?? .empty
            return includes(.codex, profile.configDirectory) && shouldAttempt(quota, force: force, at: attemptedAt)
        }
        let shouldScanCodex = scanCodex && (scanLocal || shouldRefreshCodex)
        let codexProfilesToScan = codexProfiles.filter { profile in
            includes(.codex, profile.configDirectory)
                && (scanLocal || codexAccountsToRefresh.contains(where: { $0.id == profile.id }))
        }
        let shouldScanClaude = ([claudeHome] + claudeDirectories).contains { includes(.claude, $0) }
            && (scanLocal || shouldRefreshClaude || !claudeAccountsToRefresh.isEmpty)
        guard shouldScanCodex || shouldScanClaude
                || !claudeAccountsToRefresh.isEmpty || !codexProfilesToScan.isEmpty
        else {
            if profilesChanged { saveSnapshot() }
            return []
        }

        var attempted = Set((claudeAccountsToRefresh.map(\.configDirectory)
            + codexAccountsToRefresh.map(\.configDirectory)).map(\.path))
        if shouldRefreshCodex { attempted.insert(codexHome.path) }
        if shouldRefreshClaude { attempted.insert(claudeHome.path) }

        var attemptingSnapshot = snapshot
        if shouldRefreshCodex { attemptingSnapshot.codex.lastAttemptAt = attemptedAt }
        if shouldRefreshClaude { attemptingSnapshot.claude.lastAttemptAt = attemptedAt }
        for profile in claudeAccountsToRefresh {
            if let index = attemptingSnapshot.additionalClaudeAccounts?.firstIndex(where: { $0.id == profile.id }) {
                attemptingSnapshot.additionalClaudeAccounts?[index].quota.lastAttemptAt = attemptedAt
            }
        }
        for profile in codexAccountsToRefresh {
            if let index = attemptingSnapshot.additionalCodexAccounts?.firstIndex(where: { $0.id == profile.id }) {
                attemptingSnapshot.additionalCodexAccounts?[index].quota.lastAttemptAt = attemptedAt
            }
        }
        snapshot = attemptingSnapshot
        saveSnapshot()

        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true
        refreshTask = Task {
            defer {
                if refreshGeneration == generation {
                    isRefreshing = false
                    refreshTask = nil
                }
            }

            let codexReadings = codexAccountsToRefresh.count + (shouldRefreshCodex ? 1 : 0) > 1
                ? CodexQuotaReadings() : nil
            async let codexResult: Result<CodexFetchResult, Error>? = shouldRefreshCodex
                ? capture { try await CodexAppServerClient().fetch(readings: codexReadings) }
                : nil
            async let claudeResult: Result<ProviderSnapshot, Error>? = shouldRefreshClaude
                ? capture { try await ClaudeClient().fetch() }
                : nil
            async let additionalClaudeResults = fetchClaudeAccounts(claudeAccountsToRefresh)
            async let additionalCodexResults = fetchCodexAccounts(codexAccountsToRefresh, readings: codexReadings)
            async let claudeLedgerResult: ClaudeUsageLedger? = shouldScanClaude
                ? ClaudeMixSampler(configDirectories: [claudeHome] + claudeDirectories).update() : nil
            async let imageUsageResult: ImageGenerationUsage? = shouldScanCodex
                ? ImageGenerationSampler().update() : nil

            let (codex, claude, additionalClaude, additionalCodex, claudeLedger, imageUsage) = await (
                codexResult,
                claudeResult,
                additionalClaudeResults,
                additionalCodexResults,
                claudeLedgerResult,
                imageUsageResult
            )
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            if let imageUsage { snapshot.imageGenerationUsage = imageUsage }
            let catalog = PriceCatalog()

            var officialCodexActivity: TokenActivity?
            var codexSucceeded = false
            if let codex {
                switch codex {
                case let .success(result):
                    if let accountID = result.accountID, accountID != snapshot.codexAccountID {
                        resetCodexAccountIdentity(accountID)
                    }
                    switch result.quota {
                    case var .success(quota):
                        recordSuccess(&quota, at: attemptedAt)
                        if let reset = droppedWeeklyReset(from: snapshot.codex, to: quota) {
                            snapshot.codexWeeklyInvalidatedReset = reset
                            snapshot.codexAccountWindowBaselines = []
                        }
                        snapshot.codex = quota
                        codexSucceeded = true
                    case let .failure(error):
                        recordFailure(error, in: &snapshot.codex, at: attemptedAt)
                    }
                    switch result.activity {
                    case let .success(resultActivity):
                        let activity = TokenActivity(
                            lifetimeTokens: resultActivity.lifetimeTokens,
                            daily: recentBuckets(resultActivity.daily),
                            utcDays: true
                        )
                        snapshot.codex.connected = true
                        officialCodexActivity = activity
                        snapshot.codexActivityError = nil
                        snapshot.codexActivityLastSuccessAt = attemptedAt
                    case let .failure(error):
                        snapshot.codexActivityError = error.localizedDescription
                    }
                case let .failure(error):
                    recordFailure(error, in: &snapshot.codex, at: attemptedAt)
                    snapshot.codexActivityError = error.localizedDescription
                }
            }
            for (id, result) in additionalCodex {
                if let index = snapshot.additionalCodexAccounts?.firstIndex(where: { $0.id == id }) {
                    applyCodexAccountResult(result, at: index, date: attemptedAt)
                }
            }
            // A successful reading belongs to the login, including aliases not polled this refresh.
            let readings = [(snapshot.codexAccountID, snapshot.codex)]
                + (snapshot.additionalCodexAccounts ?? []).map { ($0.accountID, $0.quota) }
            let freshQuotas = Dictionary(readings.compactMap { id, quota -> (String, ProviderSnapshot)? in
                guard let id, !quota.isStale, quota.lastSuccessAt == attemptedAt else { return nil }
                return (id, quota)
            }, uniquingKeysWith: { first, _ in first })
            if let id = snapshot.codexAccountID, let quota = freshQuotas[id] {
                if let reset = droppedWeeklyReset(from: snapshot.codex, to: quota) {
                    snapshot.codexWeeklyInvalidatedReset = reset
                    snapshot.codexAccountWindowBaselines = []
                }
                snapshot.codex = quota
                codexSucceeded = true
                if officialCodexActivity == nil, let reading = snapshot.additionalCodexAccounts?.first(where: {
                    $0.accountID == id && $0.activityLastSuccessAt == attemptedAt
                }) {
                    officialCodexActivity = reading.tokenActivity
                    snapshot.codexActivityLastSuccessAt = attemptedAt
                    snapshot.codexActivityError = nil
                }
            }
            for index in (snapshot.additionalCodexAccounts ?? []).indices {
                guard let account = snapshot.additionalCodexAccounts?[index],
                      let id = account.accountID, let quota = freshQuotas[id] else { continue }
                if let reset = droppedWeeklyReset(from: account.quota, to: quota) {
                    snapshot.additionalCodexAccounts?[index].invalidatedReset = reset
                }
                snapshot.additionalCodexAccounts?[index].quota = quota
            }

            var codexUsageLedger: CodexUsageLedger?
            var scannedGroups = Set<String>()
            let changedCodexHomes = (shouldScanCodex ? [codexHome] : []) + codexProfilesToScan.map(\.configDirectory)
            for directory in changedCodexHomes {
                let (homes, accountID) = codexDirectories(for: directory)
                let groupKey = homes.map(\.path).joined(separator: "\n")
                guard scannedGroups.insert(groupKey).inserted else { continue }
                let usage = await CodexMixSampler(
                    codexHome: directory, additionalHomes: homes, accountID: accountID, weeklyResets: codexWeeklyResets()
                ).update()
                var costLedger = await catalog.costLedger(for: usage.mixLedger)
                costLedger.recordedTokensByDay = usage.recordedTokensByDay
                guard !Task.isCancelled, refreshGeneration == generation else { return }
                for home in homes { estimateFailures[AccountSource.title(for: home) + " local records"] = nil }
                let warningKey = AccountSource.title(for: homes[0]) + " local records"
                let missing = usage.unreconciledRecordCount
                estimateFailures[warningKey] = missing > 0
                    ? "\(missing) retained records need missing source logs to reconcile overlapping folders. Local totals are incomplete."
                    : usage.parseErrors > 0 ? "\(usage.parseErrors) local log entries could not be read." : nil
                if homes.contains(codexHome) {
                    codexUsageLedger = usage
                    if !costLedger.byDay.isEmpty { snapshot.codexCostLedger = costLedger }
                }
                for index in (snapshot.additionalCodexAccounts ?? []).indices {
                    if homes.contains(where: { $0.path == snapshot.additionalCodexAccounts?[index].sourceDirectory }),
                       !costLedger.byDay.isEmpty {
                        snapshot.additionalCodexAccounts?[index].costLedger = costLedger
                    }
                }
            }

            var codexWindows: [String: Result<CodexWindowLedger, Error>] = [:]
            @MainActor func codexWindow(for directory: URL, quota: ProviderSnapshot) async -> Result<CodexWindowLedger, Error>? {
                guard !quota.isStale, let window = weeklyWindow(in: quota),
                      let minutes = window.windowMinutes, let reset = window.resetsAt, reset > Date() else { return nil }
                let (homes, accountID) = codexDirectories(for: directory)
                let key = homes.map(\.path).joined(separator: "\n") + ":\(reset.timeIntervalSince1970):\(minutes)"
                if let result = codexWindows[key] { return result }
                let result = await capture {
                    try await CodexWindowSampler(
                        codexHome: directory, additionalHomes: homes, accountID: accountID,
                        weeklyResets: codexWeeklyResets()
                    ).update(
                        windowStartedAt: reset.addingTimeInterval(-Double(minutes) * 60), resetsAt: reset
                    )
                }
                codexWindows[key] = result
                return result
            }

            var claudeSucceeded = false
            var idleClaudeProfiles: [ClaudeAccountProfile?] = []
            if let claude {
                switch claude {
                case var .success(result):
                    recordSuccess(&result, at: attemptedAt)
                    snapshot.claude = result
                    claudeSucceeded = true
                    if hasIdleSessionWindow(result) { idleClaudeProfiles.append(nil) }
                case let .failure(error):
                    if case .credentialMissing? = error as? ClaudeClientError, snapshot.claudeAccountID == nil,
                       claudeProfiles.contains(where: { $0.accountID != nil }) {
                        // A signed-out ~/.claude beside other Claude logins only holds their shared history.
                        snapshot.claude = .empty
                        snapshot.claude.lastAttemptAt = attemptedAt
                    } else {
                        recordFailure(error, in: &snapshot.claude, at: attemptedAt)
                    }
                }
            }
            idleClaudeProfiles += applyClaudeAccountResults(
                additionalClaude, profiles: claudeAccountsToRefresh, at: attemptedAt
            ).map(Optional.init)
            startClaudeWindows(idleClaudeProfiles)
            for profile in claudeAccountsToRefresh {
                guard let account = snapshot.additionalClaudeAccounts?.first(where: { $0.id == profile.id })
                else { continue }
                var history = account.weeklyCapacityHistory ?? .empty
                let weeklyValue = await claudeProfileWeeklyValue(
                    quota: account.quota, profile: profile, catalog: catalog, history: &history
                )
                guard !Task.isCancelled, refreshGeneration == generation else { return }
                if let index = snapshot.additionalClaudeAccounts?.firstIndex(where: { $0.id == profile.id }) {
                    snapshot.additionalClaudeAccounts?[index].weeklyValue = weeklyValue
                    snapshot.additionalClaudeAccounts?[index].weeklyCapacityHistory = history
                }
            }
            var estimatedCodexGroups = Set<String>()
            for profile in codexProfilesToScan {
                guard let account = snapshot.additionalCodexAccounts?.first(where: { $0.id == profile.id }) else { continue }
                let homes = codexDirectories(for: profile.configDirectory).homes
                guard estimatedCodexGroups.insert(homes.map(\.path).joined(separator: "\n")).inserted else { continue }
                var weeklyValue: WeeklyValueEstimate?
                if let window = weeklyWindow(in: account.quota), window.usedPercent >= 3,
                   !sameReset(window.resetsAt, account.invalidatedReset),
                   case let .success(ledger)? = await codexWindow(for: profile.configDirectory, quota: account.quota),
                   ledger.isComplete, ledger.parseErrors == 0, ledger.unreconciledMessageHashes?.isEmpty != false {
                    let mix = await catalog.costMix(for: ledger.mixLedger)
                    if case let .available(estimate) = weeklyValueEstimate(
                        capacity: currentCapacity(window: window, observedTokens: ledger.observedTokens),
                        observedTokens: ledger.observedTokens, costMix: mix, requiresExactTokenMatch: true,
                        resetsAt: window.resetsAt
                    ) { weeklyValue = estimate }
                }
                guard !Task.isCancelled, refreshGeneration == generation else { return }
                for index in (snapshot.additionalCodexAccounts ?? []).indices {
                    if homes.contains(where: { $0.path == snapshot.additionalCodexAccounts?[index].sourceDirectory }) {
                        snapshot.additionalCodexAccounts?[index].weeklyValue = weeklyValue
                    }
                }
            }

            var codexWindowResult: Result<CodexWindowLedger, Error>?
            if codexSucceeded {
                codexWindowResult = await codexWindow(for: codexHome, quota: snapshot.codex)
            }

            var claudeWindowResult: Result<ClaudeWindowLedger, Error>?
            if claudeSucceeded,
               let weeklyWindow = weeklyWindow(in: snapshot.claude),
               let durationMinutes = weeklyWindow.windowMinutes,
               let resetsAt = weeklyWindow.resetsAt {
                snapshot.claudeWeeklyValueError = "Updating the exact local weekly window..."
                let windowStartedAt = resetsAt.addingTimeInterval(-Double(durationMinutes) * 60)
                let sampler = ClaudeWindowSampler(aliases: claudePrimaryAliases, accountID: snapshot.claudeAccountID)
                claudeWindowResult = await capture {
                    try await sampler.update(
                        windowStartedAt: windowStartedAt,
                        resetsAt: resetsAt
                    )
                }
            }

            let codexWindowLedger: CodexWindowLedger? = {
                guard case let .success(ledger)? = codexWindowResult else { return nil }
                return ledger
            }()
            let claudeWindowLedger: ClaudeWindowLedger? = {
                guard case let .success(ledger)? = claudeWindowResult else { return nil }
                return ledger
            }()
            let codexLedger: MixLedger = {
                guard codexUsageLedger != nil else { return .empty }
                if let codexWindowLedger, codexWindowLedger.observedTokens > 0 {
                    return codexWindowLedger.mixLedger
                }
                return CodexWindowSampler().lastKnownMixLedger() ?? .empty
            }()
            let claudeMixLedger = claudeLedger.map(mixLedger(from:)) ?? .empty
            if codexUsageLedger != nil {
                let codexMix = await catalog.costMix(for: codexLedger)
                guard !Task.isCancelled, refreshGeneration == generation else { return }
                if !codexLedger.byModel.isEmpty { snapshot.costMix = codexMix }
                if codexSucceeded {
                    let codexWeeklyMix = (codexWindowLedger?.observedTokens ?? 0) > 0
                        ? codexMix : .empty
                    updateCodexAccountEstimates(
                        activity: officialCodexActivity,
                        costMix: codexWeeklyMix,
                        localResult: codexWindowResult,
                        localLedger: codexWindowLedger,
                        observedAt: attemptedAt
                    )
                }
            }
            if let claudeLedger {
                let claudeWindowLedgerForPricing = claudeWindowLedger?.mixLedger ?? .empty
                let claudeCostLedger = await catalog.costLedger(for: claudeMixLedger)
                let claudeWindowMix = await catalog.costMix(for: claudeWindowLedgerForPricing)
                guard !Task.isCancelled, refreshGeneration == generation else { return }
                snapshot.claudeTokenActivity = tokenActivity(from: mixLedger(from: claudeLedger))
                snapshot.claudeCostMix = claudeCostLedger.overall
                if !claudeCostLedger.byDay.isEmpty {
                    snapshot.claudeCostLedger = claudeCostLedger
                }
                // A refresh for extra accounts alone must not clear the primary's estimate status.
                if scanClaude {
                    updateClaudeWeeklyValue(
                        result: claudeWindowResult,
                        ledger: claudeWindowLedger,
                        costMix: claudeWindowMix
                    )
                }
            }
            if let officialCodexActivity {
                snapshot.tokenActivity = officialCodexActivity
            }
            estimateFailures["Prices"] = catalog.refreshWarning
            snapshot.updatedAt = ([
                snapshot.claude.lastSuccessAt,
                snapshot.codex.lastSuccessAt,
            ] + (snapshot.additionalClaudeAccounts ?? []).map { $0.quota.lastSuccessAt }
                + (snapshot.additionalCodexAccounts ?? []).map { $0.quota.lastSuccessAt })
                .compactMap { $0 }
                .max()
            saveSnapshot()
        }
        return attempted
    }

    func cancelRefresh() {
        guard isRefreshing else { return }
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func nextAttemptDate(forAccount directory: String) -> Date {
        let provider = directory == AccountSource.primaryDirectory(for: .claude).path ? snapshot.claude
            : directory == AccountSource.primaryDirectory(for: .codex).path ? snapshot.codex
            : (snapshot.additionalClaudeAccounts ?? []).first(where: { $0.sourceDirectory == directory })?.quota
            ?? (snapshot.additionalCodexAccounts ?? []).first(where: { $0.sourceDirectory == directory })?.quota
            ?? .empty
        let freshnessDate = (provider.lastAttemptAt ?? provider.lastSuccessAt)?
            .addingTimeInterval(freshnessInterval) ?? .distantPast
        return max(freshnessDate, provider.nextAllowedRefreshAt ?? .distantPast)
    }

    func lastSuccessDate(for provider: ProviderScope) -> Date? {
        switch provider {
        case .claude:
            snapshot.claude.lastSuccessAt
        case .codex:
            snapshot.codex.lastSuccessAt
        case .overview:
            ([snapshot.claude.lastSuccessAt, snapshot.codex.lastSuccessAt]
                + (snapshot.additionalClaudeAccounts ?? []).map { $0.quota.lastSuccessAt }
                + (snapshot.additionalCodexAccounts ?? []).map { $0.quota.lastSuccessAt })
                .compactMap { $0 }
                .min()
        }
    }

    func isStale(_ provider: ProviderScope) -> Bool {
        switch provider {
        case .claude, .codex:
            // Every account's percentage feeds the header and All, so any stale one marks them.
            snapshot.accountRows(for: provider).contains { $0.quota.isStale }
        case .overview:
            isStale(.claude) || isStale(.codex)
        }
    }

    /// The error of the first stale account behind a provider's header.
    func staleError(_ provider: ProviderScope) -> String? {
        snapshot.accountRows(for: provider).map(\.quota).first(where: \.isStale)?.error
    }

    func tokens(for provider: ProviderScope, period: ActivityPeriod) -> Int64 {
        activitySummary(for: provider, period: period).tokens
    }

    func estimatedCost(for provider: ProviderScope, period: ActivityPeriod) -> Double? {
        activitySummary(for: provider, period: period).estimatedCost
    }

    private func activitySummary(for provider: ProviderScope, period: ActivityPeriod) -> ActivitySummary {
        let interval = period.interval()
        if let cached = activitySummaries[provider]?[period], cached.interval == interval { return cached }
        let summary: ActivitySummary
        if provider == .codex {
            let cost = codexCost(in: interval)
            let imageCost = snapshot.imageGenerationUsage?.cost(in: interval) ?? 0
            summary = ActivitySummary(
                interval: interval,
                tokens: codexUsage.reduce(0) { $0 + $1.activity.tokens(in: interval) },
                estimatedCost: cost.usd.map { $0 + imageCost },
                unmatchedTokens: cost.unmatchedTokens
            )
        } else {
            let activity = tokenActivity(for: provider)
            let mix = snapshot.claudeCostLedger?.mix(for: activity.dayKeys(in: interval)) ?? .empty
            let tokens = activity.tokens(in: interval)
            summary = ActivitySummary(
                interval: interval, tokens: tokens, estimatedCost: mix.estimate(tokens: tokens), unmatchedTokens: 0
            )
        }
        activitySummaries[provider, default: [:]][period] = summary
        return summary
    }

    // Activity freshness is independent of quota freshness. Each login contributes one account total.
    private var codexUsage: [(activity: TokenActivity, ledger: CostLedger?)] {
        if let codexActivityCache { return codexActivityCache }
        let accounts = [(id: snapshot.codexAccountID ?? "primary", activity: snapshot.tokenActivity,
                         ledger: snapshot.codexCostLedger, date: snapshot.codexActivityLastSuccessAt ?? .distantPast)]
            + (snapshot.additionalCodexAccounts ?? []).compactMap { account in
                guard let id = account.accountID else { return nil }
                return (id, account.tokenActivity ?? .empty, account.costLedger,
                        account.activityLastSuccessAt ?? .distantPast)
            }
        let usage = Dictionary(grouping: accounts, by: \.id).values.map { readings in
            let activity = readings.max { $0.date < $1.date }?.activity ?? .empty
            let ledger = readings.compactMap(\.ledger).max {
                $0.overall.sampledTokens < $1.overall.sampledTokens
            }
            return (activity.supplementing(with: ledger), ledger)
        }
        codexActivityCache = usage
        return usage
    }

    /// Each Codex login's current weekly reset by account ID; every token count records its login's reset.
    private func codexWeeklyResets() -> [String: Date] {
        let quotas = [(snapshot.codexAccountID, snapshot.codex)]
            + (snapshot.additionalCodexAccounts ?? []).map { ($0.accountID, $0.quota) }
        return quotas.reduce(into: [:]) { resets, entry in
            if let id = entry.0, let reset = weeklyWindow(in: entry.1)?.resetsAt { resets[id] = reset }
        }
    }

    private func codexDirectories(for directory: URL) -> (homes: [URL], accountID: String?) {
        let primary = AccountSource.primaryDirectory(for: .codex)
        let candidates: [(directory: String, account: String?)] = [(primary.path, snapshot.codexAccountID)]
            + (snapshot.additionalCodexAccounts ?? []).map { ($0.sourceDirectory, $0.accountID) }
        guard let id = candidates.first(where: { $0.directory == directory.path })?.account else { return ([directory], nil) }
        return (candidates.filter { $0.account == id }
            .map { URL(fileURLWithPath: $0.directory, isDirectory: true) }
            .sorted { $0.path < $1.path }, id)
    }

    // An account with no local mix in the period, such as one used only elsewhere, takes the others' rate;
    // an account whose mix lacks prices hides the total.
    private func codexCost(in interval: DateInterval) -> (usd: Double?, unmatchedTokens: Int64) {
        var usd = 0.0
        var pricedTokens: Int64 = 0
        var unmixedTokens: Int64 = 0
        var unmatched: Int64 = 0
        for usage in codexUsage {
            let cost = codexCost(of: usage.activity, ledger: usage.ledger, in: interval)
            let tokens = usage.activity.tokens(in: interval)
            unmatched += cost.unmatchedTokens
            if let accountUSD = cost.usd {
                usd += accountUSD
                pricedTokens += tokens
            } else if !cost.hasMix {
                unmixedTokens += tokens
            } else {
                return (nil, unmatched)
            }
        }
        guard unmixedTokens > 0 else { return (usd, unmatched) }
        guard pricedTokens > 0 else { return (nil, unmatched) }
        return (usd + Double(unmixedTokens) * usd / Double(pricedTokens), unmatched)
    }

    // The account reports no models, so each UTC day uses that day's local mix and days without one
    // use the period's average rate; unknown models still need 99.9% coverage across the period.
    private func codexCost(
        of activity: TokenActivity, ledger: CostLedger?, in interval: DateInterval
    ) -> (usd: Double?, unmatchedTokens: Int64, hasMix: Bool) {
        let buckets = activity.buckets(in: interval)
        var usd = 0.0
        var priced: Int64 = 0
        var unmatched: Int64 = 0
        for bucket in buckets {
            if let rate = ledger?.byDay[bucket.startDate]?.usdPerToken {
                usd += Double(bucket.tokens) * rate
                priced += bucket.tokens
            } else {
                unmatched += bucket.tokens
            }
        }
        guard priced + unmatched > 0 else { return (0, 0, true) }
        let mixes = buckets.compactMap { ledger?.byDay[$0.startDate] }
        guard priced > 0, CostMix.merged(mixes).hasPricedCoverage else { return (nil, unmatched, !mixes.isEmpty) }
        return (usd + Double(unmatched) * usd / Double(priced), unmatched, true)
    }

    func weeklyValues(for provider: ProviderScope) -> [WeeklyValueEstimate] {
        weeklyEstimates(for: provider).map(\.estimate)
    }

    /// Weekly percentage weighted by each account's estimated weekly tokens.
    /// An account without an estimate takes its provider's mean weight; with none, accounts count equally.
    func weeklyPercent(for provider: ProviderScope) -> Double? {
        var used = 0.0
        var total = 0.0
        for scope in provider == .overview ? [ProviderScope.claude, .codex] : [provider] {
            let estimates = weeklyEstimates(for: scope)
            let rows: [(percent: Double, tokens: Double?)] = snapshot.accountRows(for: scope).compactMap { account, quota in
                let tokens = estimates.first { $0.account == account }?.estimate.equivalentTokens
                return quota.weeklyPercent.map { ($0, tokens.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }) }
            }
            let known = rows.compactMap(\.tokens)
            // All compares the providers' capacities, so each needs at least one estimate.
            if provider == .overview, known.isEmpty { return nil }
            let fallback = known.isEmpty ? 1 : known.reduce(0, +) / Double(known.count)
            for row in rows {
                used += (row.tokens ?? fallback) * row.percent
                total += row.tokens ?? fallback
            }
        }
        return total > 0 ? min(100, max(0, used / total)) : nil
    }

    /// Current weekly estimates, one per confirmed login, keyed like `AppSnapshot.accountRows`.
    private func weeklyEstimates(for provider: ProviderScope) -> [(account: String?, estimate: WeeklyValueEstimate)] {
        switch provider {
        case .overview:
            return []
        case .claude:
            return [currentEstimate(snapshot.claudeWeeklyValue, quota: snapshot.claude, allowsPrior: true)]
                .compactMap { $0 }.map { (snapshot.claudeAccountID, $0) }
                + (snapshot.additionalClaudeAccounts ?? []).compactMap { account in
                    currentEstimate(account.weeklyValue, quota: account.quota, allowsPrior: true).map { (account.id, $0) }
                }
        case .codex:
            // Choose estimates independently of quota-row visibility, one per confirmed account.
            let candidates = [(snapshot.codexAccountID, snapshot.codex, snapshot.codexWeeklyValue)]
                + (snapshot.additionalCodexAccounts ?? []).map { ($0.accountID ?? $0.id, $0.quota, $0.weeklyValue) }
            // A mid-window percentage drop invalidates that account's window for every profile.
            let invalidations = [(snapshot.codexAccountID, snapshot.codexWeeklyInvalidatedReset)]
                + (snapshot.additionalCodexAccounts ?? []).map { ($0.accountID ?? $0.id, $0.invalidatedReset) }
            let invalidated = Set(invalidations.compactMap { id, reset -> String? in
                guard let id, let reset else { return nil }
                return "\(id):\(Int(reset.timeIntervalSince1970))"
            })
            var seen = Set<String>()
            return candidates.enumerated().compactMap { index, candidate in
                let (accountID, quota, cached) = candidate
                guard var estimate = currentEstimate(cached, quota: quota),
                      let reset = weeklyWindow(in: quota)?.resetsAt,
                      !invalidated.contains("\(accountID ?? ""):\(Int(reset.timeIntervalSince1970))"),
                      accountID.map({ seen.insert($0).inserted }) ?? true
                else { return nil }
                if index == 0, let interval = codexImageInterval {
                    let imageCost = snapshot.imageGenerationUsage?.cost(in: interval) ?? 0
                    estimate.observedCostUSD += imageCost
                    estimate.equivalentValueUSD += imageCost * 100 / estimate.usedPercent
                }
                return (accountID, estimate)
            }
        }
    }

    // A cached estimate counts only while it still describes the account's live weekly window.
    private func currentEstimate(
        _ estimate: WeeklyValueEstimate?, quota: ProviderSnapshot, allowsPrior: Bool = false
    ) -> WeeklyValueEstimate? {
        guard let estimate, !quota.isStale, let window = weeklyWindow(in: quota),
              let reset = window.resetsAt, reset > Date(),
              (allowsPrior || window.usedPercent >= 3), estimate.usedPercent == window.usedPercent,
              previewScenario != nil || sameReset(estimate.resetsAt, reset)
        else { return nil }
        return estimate
    }

    func imageCostHelp(for provider: ProviderScope, period: ActivityPeriod) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let utcDayStart = utc.startOfDay(for: Date()).formatted(date: .omitted, time: .shortened)
        var codexScope = "Codex tokens are each OpenAI account's totals by UTC day, which starts at \(utcDayStart) local time."
            + " Dollars price each account's day with that UTC day's local model mix from its Codex folder."
            + " Each day uses the larger of the account total and this Mac's deduplicated records, never their sum."
            + " Local totals remain provisional while account reporting lags; other devices may be missing."
        let cost = activitySummary(for: .codex, period: period)
        if cost.unmatchedTokens > 0, cost.estimatedCost != nil {
            codexScope += " \(compactTokens(cost.unmatchedTokens)) tokens fall on days without local model records"
                + " and use this period's average rate."
        }
        let scope: String
        switch provider {
        case .claude: scope = "Activity source: projects in every Claude folder."
        case .codex: scope = codexScope
        case .overview: scope = "Claude activity source: projects in every Claude folder. " + codexScope
        }
        guard provider != .claude else {
            return "Estimated API-equivalent cost of text-model usage. " + scope
        }
        let explanation = snapshot.imageGenerationUsage?.explanation(in: period.interval())
            ?? "ImageGen output estimates are updating."
        return explanation + " " + scope
    }

    func weeklyCostHelp(for provider: ProviderScope) -> String {
        let base = provider == .codex
            ? "Sum of available account projections. Integer quota percentages, speed modes"
                + " and other devices can affect accuracy."
            : "Sum of available account projections, each smoothed in dollars with its earlier weeks."
                + " Proportionality to subscription quota is an assumption."
        guard provider == .codex, snapshot.codexWeeklyValue != nil, !snapshot.codex.isStale,
              let usage = snapshot.imageGenerationUsage,
              let interval = codexImageInterval else { return base }
        return base + " " + usage.explanation(in: interval)
            + " The image component is extrapolated using the same weekly usage percentage."
    }

    private var codexImageInterval: DateInterval? {
        guard let reset = weeklyWindow(in: snapshot.codex)?.resetsAt,
              let sampledAt = snapshot.codex.lastSuccessAt else { return nil }
        let start = reset.addingTimeInterval(-7 * 24 * 60 * 60)
        let end = min(reset, sampledAt)
        return end > start ? DateInterval(start: start, end: end) : nil
    }

    private func updateClaudeWeeklyValue(
        result: Result<ClaudeWindowLedger, Error>?,
        ledger: ClaudeWindowLedger?,
        costMix: CostMix
    ) {
        estimateFailures["Claude estimate"] = nil
        guard let result else {
            if weeklyWindow(in: snapshot.claude) == nil {
                snapshot.claudeWeeklyValue = nil
                snapshot.claudeWeeklyValueError = "Weekly usage is unavailable."
            }
            return
        }
        if case let .failure(error) = result {
            snapshot.claudeWeeklyValueError = "Exact local scan failed: \(error.localizedDescription)"
            estimateFailures["Claude estimate"] = snapshot.claudeWeeklyValueError
            return
        }
        guard let ledger, ledger.isComplete else {
            snapshot.claudeWeeklyValueError = "The exact local weekly window is still updating."
            return
        }
        guard ledger.parseErrors == 0 else {
            snapshot.claudeWeeklyValueError = "The local window contains \(ledger.parseErrors) unreadable log entries."
            estimateFailures["Claude estimate"] = snapshot.claudeWeeklyValueError
            return
        }
        guard let window = weeklyWindow(in: snapshot.claude) else {
            snapshot.claudeWeeklyCapacity = nil
            snapshot.claudeWeeklyValue = nil
            snapshot.claudeWeeklyValueError = "Weekly usage is unavailable."
            return
        }

        guard ledger.observedTokens > 0 else {
            snapshot.claudeWeeklyValue = nil
            snapshot.claudeWeeklyValueError = "No local usage in this weekly window yet."
            return
        }
        guard costMix.sampledTokens == ledger.observedTokens,
              costMix.missingModels.isEmpty,
              let observedCost = costMix.estimate(tokens: ledger.observedTokens), observedCost > 0 else {
            snapshot.claudeWeeklyValue = nil
            snapshot.claudeWeeklyValueError = "Waiting for exact prices for the models used in this window."
            return
        }
        var history = snapshot.claudeWeeklyCapacityHistory ?? .empty
        let capacity = WeeklyCapacityEstimator.update(
            history: &history,
            window: window,
            observedTokens: ledger.observedTokens,
            observedCostUSD: observedCost,
            observedAt: ledger.observedAt,
            source: "local"
        )
        snapshot.claudeWeeklyCapacityHistory = history
        snapshot.claudeWeeklyCapacity = capacity
        snapshot.claudeWeeklyValue = nil
        let status = weeklyValueEstimate(
            capacity: capacity,
            observedTokens: ledger.observedTokens,
            costMix: costMix,
            requiresExactTokenMatch: true,
            resetsAt: window.resetsAt
        )
        switch status {
        case let .available(estimate):
            snapshot.claudeWeeklyValue = estimate
            snapshot.claudeWeeklyValueError = nil
        case let .unavailable(error):
            snapshot.claudeWeeklyValueError = error
        }
    }

    private func updateCodexAccountEstimates(
        activity: TokenActivity?,
        costMix: CostMix,
        localResult: Result<CodexWindowLedger, Error>?,
        localLedger: CodexWindowLedger?,
        observedAt: Date
    ) {
        snapshot.codexWeeklyCapacity = nil
        snapshot.codexWeeklyValue = nil
        snapshot.codexWeeklyEstimateSource = nil
        estimateFailures["Codex estimate"] = nil
        guard let window = weeklyWindow(in: snapshot.codex),
              !sameReset(window.resetsAt, snapshot.codexWeeklyInvalidatedReset),
              let durationMinutes = window.windowMinutes,
              let resetsAt = window.resetsAt
        else {
            snapshot.codexWeeklyValueError = "Weekly usage is unavailable."
            return
        }
        guard localLedger?.unreconciledMessageHashes?.isEmpty != false else {
            snapshot.codexWeeklyValueError = "Overlapping local histories cannot be fully reconciled without their missing logs."
            return
        }
        guard let lifetimeTokens = activity?.lifetimeTokens else {
            updateCodexLocalFallback(
                result: localResult,
                ledger: localLedger,
                costMix: costMix
            )
            return
        }

        let windowStartedAt = resetsAt.addingTimeInterval(-Double(durationMinutes) * 60)
        let priorBaseline = snapshot.codexAccountWindowBaselines?.first(where: {
            $0.windowID == window.id
                && abs($0.windowStartedAt.timeIntervalSince(windowStartedAt)) < 2
                && abs($0.resetsAt.timeIntervalSince(resetsAt)) < 2
        })
        let lifetimeCounterReset = priorBaseline.map { lifetimeTokens < $0.lifetimeTokens } ?? false
        updateCodexAccountBaselines(lifetimeTokens: lifetimeTokens, observedAt: observedAt)
        guard let baseline = snapshot.codexAccountWindowBaselines?.first(where: {
            $0.windowID == window.id
                && abs($0.windowStartedAt.timeIntervalSince(windowStartedAt)) < 2
                && abs($0.resetsAt.timeIntervalSince(resetsAt)) < 2
        }) else {
            updateCodexLocalFallback(
                result: localResult,
                ledger: localLedger,
                costMix: costMix
            )
            return
        }
        guard !lifetimeCounterReset else {
            updateCodexLocalFallback(
                result: localResult,
                ledger: localLedger,
                costMix: costMix
            )
            return
        }
        guard baseline.startsAtWindowBoundary else {
            updateCodexLocalFallback(
                result: localResult,
                ledger: localLedger,
                costMix: costMix
            )
            return
        }

        let observedTokens = lifetimeTokens - baseline.lifetimeTokens
        let localObservedTokens = localLedger?.isComplete == true && localLedger?.parseErrors == 0
            ? localLedger?.observedTokens ?? 0 : 0
        guard observedTokens > 0, observedTokens >= localObservedTokens else {
            updateCodexLocalFallback(
                result: localResult,
                ledger: localLedger,
                costMix: costMix
            )
            return
        }
        let capacity = currentCapacity(window: window, observedTokens: observedTokens)
        if let capacity {
            snapshot.codexWeeklyCapacity = capacity
            snapshot.codexWeeklyEstimateSource = .accountLifetime
        }
        let status = weeklyValueEstimate(
            capacity: capacity,
            observedTokens: observedTokens,
            costMix: costMix,
            requiresExactTokenMatch: false,
            resetsAt: window.resetsAt
        )
        switch status {
        case let .available(estimate):
            snapshot.codexWeeklyValue = estimate
            snapshot.codexWeeklyValueError = nil
            snapshot.codexWeeklyEstimateSource = .accountLifetime
        case let .unavailable(error):
            snapshot.codexWeeklyValueError = error
        }
    }

    private func updateCodexLocalFallback(
        result: Result<CodexWindowLedger, Error>?,
        ledger: CodexWindowLedger?,
        costMix: CostMix
    ) {
        if case let .failure(error)? = result {
            snapshot.codexWeeklyValueError = "Local fallback scan failed: \(error.localizedDescription)"
            estimateFailures["Codex estimate"] = snapshot.codexWeeklyValueError
            return
        }
        guard let ledger else {
            snapshot.codexWeeklyCapacity = nil
            snapshot.codexWeeklyValue = nil
            snapshot.codexWeeklyEstimateSource = nil
            snapshot.codexWeeklyValueError = "Waiting for a weekly account baseline or local fallback."
            return
        }

        guard ledger.isComplete else {
            snapshot.codexWeeklyValueError = "The local weekly fallback is still updating."
            return
        }
        guard ledger.parseErrors == 0 else {
            snapshot.codexWeeklyValueError = "The local fallback contains \(ledger.parseErrors) unreadable log entries."
            estimateFailures["Codex estimate"] = snapshot.codexWeeklyValueError
            return
        }
        guard let window = weeklyWindow(in: snapshot.codex) else {
            snapshot.codexWeeklyValueError = "Weekly usage is unavailable."
            return
        }

        let capacity = currentCapacity(window: window, observedTokens: ledger.observedTokens)
        if let capacity {
            snapshot.codexWeeklyCapacity = capacity
            snapshot.codexWeeklyEstimateSource = .localWindowFallback
        }
        let status = weeklyValueEstimate(
            capacity: capacity,
            observedTokens: ledger.observedTokens,
            costMix: costMix,
            requiresExactTokenMatch: true,
            resetsAt: window.resetsAt
        )
        switch status {
        case let .available(estimate):
            snapshot.codexWeeklyValue = estimate
            snapshot.codexWeeklyValueError = nil
            snapshot.codexWeeklyEstimateSource = .localWindowFallback
        case let .unavailable(error):
            if snapshot.codexWeeklyCapacity == nil {
                snapshot.codexWeeklyEstimateSource = nil
            }
            snapshot.codexWeeklyValueError = error
        }
    }

    private func updateCodexAccountBaselines(lifetimeTokens: Int64, observedAt: Date) {
        let windows = allWindows(in: snapshot.codex).filter {
            $0.windowMinutes != nil && $0.resetsAt != nil
        }
        let existing = snapshot.codexAccountWindowBaselines ?? []
        let startTolerance: TimeInterval = 15 * 60
        snapshot.codexAccountWindowBaselines = windows.compactMap { window in
            guard let durationMinutes = window.windowMinutes,
                  let resetsAt = window.resetsAt
            else {
                return nil
            }
            let windowStartedAt = resetsAt.addingTimeInterval(-Double(durationMinutes) * 60)
            if let baseline = existing.first(where: {
                $0.windowID == window.id
                    && abs($0.windowStartedAt.timeIntervalSince(windowStartedAt)) < 2
                    && abs($0.resetsAt.timeIntervalSince(resetsAt)) < 2
                    && lifetimeTokens >= $0.lifetimeTokens
                    && window.usedPercent >= ($0.usedPercent ?? 0)
            }) {
                return baseline
            }
            return CodexAccountWindowBaseline(
                windowID: window.id,
                windowMinutes: durationMinutes,
                windowStartedAt: windowStartedAt,
                resetsAt: resetsAt,
                lifetimeTokens: lifetimeTokens,
                observedAt: observedAt,
                startsAtWindowBoundary: abs(observedAt.timeIntervalSince(windowStartedAt)) <= startTolerance
                    || window.usedPercent <= 0.5,
                usedPercent: window.usedPercent
            )
        }
    }

    /// Applies additional Claude readings and returns the profiles whose 5-hour window is idle.
    private func applyClaudeAccountResults(
        _ results: [(String, Result<ProviderSnapshot, Error>)],
        profiles: [ClaudeAccountProfile],
        at date: Date
    ) -> [ClaudeAccountProfile] {
        var idle: [ClaudeAccountProfile] = []
        for (id, result) in results {
            guard let index = snapshot.additionalClaudeAccounts?.firstIndex(where: { $0.id == id }) else { continue }
            var quota = snapshot.additionalClaudeAccounts?[index].quota ?? .empty
            switch result {
            case let .success(fetched):
                quota = fetched
                recordSuccess(&quota, at: date)
                if hasIdleSessionWindow(fetched), let profile = profiles.first(where: { $0.id == id }) {
                    idle.append(profile)
                }
            case let .failure(error):
                recordFailure(error, in: &quota, at: date)
            }
            snapshot.additionalClaudeAccounts?[index].quota = quota
        }
        return idle
    }

    private func applyCodexAccountResult(_ result: Result<CodexFetchResult, Error>, at index: Int, date: Date) {
        guard var account = snapshot.additionalCodexAccounts?[index] else { return }
        switch result {
        case let .success(fetched):
            let previous = account
            if let accountID = fetched.accountID {
                // Another login in the same folder starts with a clean reading.
                if accountID != previous.accountID {
                    account.quota = .empty
                    account.invalidatedReset = nil
                    account.tokenActivity = nil
                    account.costLedger = nil
                    account.activityLastSuccessAt = nil
                }
                account.accountID = accountID
            }
            switch fetched.quota {
            case var .success(reading):
                if fetched.accountID == previous.accountID,
                   let reset = droppedWeeklyReset(from: previous.quota, to: reading) {
                    account.invalidatedReset = reset
                }
                recordSuccess(&reading, at: date)
                account.quota = reading
            case let .failure(error):
                recordFailure(error, in: &account.quota, at: date)
            }
            switch fetched.activity {
            case let .success(activity):
                account.tokenActivity = TokenActivity(
                    lifetimeTokens: activity.lifetimeTokens, daily: recentBuckets(activity.daily), utcDays: true
                )
                account.activityLastSuccessAt = date
                estimateFailures["\(account.name) usage"] = nil
            case let .failure(error):
                let message = error.localizedDescription
                estimateFailures["\(account.name) usage"] = message == account.quota.error ? nil : message
            }
        case let .failure(error):
            recordFailure(error, in: &account.quota, at: date)
        }
        snapshot.additionalCodexAccounts?[index] = account
    }

    /// An extra account's estimate from its login's current-window records in every folder signed in to it,
    /// smoothed with its own earlier windows like the primary account's.
    private func claudeProfileWeeklyValue(
        quota: ProviderSnapshot, profile: ClaudeAccountProfile, catalog: PriceCatalog,
        history: inout WeeklyCapacityHistory
    ) async -> WeeklyValueEstimate? {
        guard !quota.isStale, let window = weeklyWindow(in: quota),
              let minutes = window.windowMinutes, let reset = window.resetsAt, reset > Date()
        else { return nil }
        let sampler = ClaudeWindowSampler(
            configDirectory: profile.configDirectory, aliases: profile.aliases, accountID: profile.accountID
        )
        guard let ledger = try? await sampler.update(
                  windowStartedAt: reset.addingTimeInterval(-Double(minutes) * 60), resetsAt: reset
              ),
              ledger.isComplete, ledger.parseErrors == 0, ledger.observedTokens > 0
        else { return nil }
        let mix = await catalog.costMix(for: ledger.mixLedger)
        // Only an exactly priced window may enter the history that later weeks are smoothed with.
        guard mix.sampledTokens == ledger.observedTokens, mix.missingModels.isEmpty,
              let observedCost = mix.estimate(tokens: ledger.observedTokens), observedCost > 0
        else { return nil }
        let capacity = WeeklyCapacityEstimator.update(
            history: &history, window: window, observedTokens: ledger.observedTokens,
            observedCostUSD: observedCost, observedAt: ledger.observedAt, source: "local"
        )
        guard case let .available(estimate) = weeklyValueEstimate(
            capacity: capacity, observedTokens: ledger.observedTokens, costMix: mix,
            requiresExactTokenMatch: true, resetsAt: reset
        ) else { return nil }
        return estimate
    }

    private func currentCapacity(
        window: LimitWindow,
        observedTokens: Int64
    ) -> WeeklyTokenCapacityEstimate? {
        guard observedTokens > 0,
              window.usedPercent.isFinite,
              window.usedPercent >= 3
        else { return nil }
        let equivalentTokens = Double(observedTokens) * 100 / window.usedPercent
        guard equivalentTokens.isFinite, equivalentTokens > 0 else { return nil }
        return WeeklyTokenCapacityEstimate(
            usedPercent: window.usedPercent,
            observedTokens: observedTokens,
            equivalentTokens: equivalentTokens
        )
    }

    private func weeklyValueEstimate(
        capacity: WeeklyTokenCapacityEstimate?,
        observedTokens: Int64,
        costMix: CostMix,
        requiresExactTokenMatch: Bool,
        resetsAt: Date?
    ) -> WeeklyValueStatus {
        guard let capacity else {
            return .unavailable("Waiting for enough weekly observations.")
        }
        guard observedTokens > 0 else {
            return .unavailable("No local usage in this weekly window yet.")
        }
        guard costMix.missingModels.isEmpty,
              (!requiresExactTokenMatch || costMix.sampledTokens == observedTokens),
              let rate = costMix.usdPerToken,
              let observedCost = costMix.estimate(tokens: observedTokens)
        else {
            return .unavailable("Waiting for exact prices for the models used in this window.")
        }

        let equivalentValue = capacity.equivalentValueUSD ?? capacity.equivalentTokens * rate
        guard equivalentValue.isFinite else {
            return .unavailable("The local estimate is temporarily unavailable.")
        }

        return .available(WeeklyValueEstimate(
            usedPercent: capacity.usedPercent,
            observedTokens: observedTokens,
            observedCostUSD: observedCost,
            equivalentTokens: capacity.equivalentTokens,
            equivalentValueUSD: equivalentValue,
            resetsAt: resetsAt
        ))
    }

    private func weeklyWindow(in provider: ProviderSnapshot) -> LimitWindow? {
        allWindows(in: provider)
            .first { $0.windowMinutes == 7 * 24 * 60 && $0.limitID?.hasPrefix("claude:") != true }
    }

    // A falling percentage within one reset window means earlier spend cannot be attributed to it.
    private func droppedWeeklyReset(from old: ProviderSnapshot, to new: ProviderSnapshot) -> Date? {
        guard let previous = weeklyWindow(in: old), let current = weeklyWindow(in: new),
              sameReset(previous.resetsAt, current.resetsAt), current.usedPercent < previous.usedPercent
        else { return nil }
        return current.resetsAt
    }

    private func sameReset(_ first: Date?, _ second: Date?) -> Bool {
        guard let first, let second else { return false }
        return abs(first.timeIntervalSince(second)) < 2
    }

    private func allWindows(in provider: ProviderSnapshot) -> [LimitWindow] {
        [provider.longWindow, provider.shortWindow].compactMap { $0 } + provider.extraWindows
    }

    private func shouldAttempt(
        _ provider: ProviderSnapshot,
        force: Bool,
        at date: Date
    ) -> Bool {
        if let nextAllowed = provider.nextAllowedRefreshAt, nextAllowed > date {
            return false
        }
        if force { return true }
        guard let previous = provider.lastAttemptAt ?? provider.lastSuccessAt else {
            return true
        }
        return date.timeIntervalSince(previous) >= freshnessInterval
    }

    private func recordSuccess(_ provider: inout ProviderSnapshot, at date: Date) {
        provider.lastAttemptAt = date
        provider.lastSuccessAt = date
        provider.nextAllowedRefreshAt = nil
        provider.consecutiveRateLimits = 0
        provider.stale = false
        provider.error = nil
    }

    // An idle 5-hour window reports no reset time, or one that has already passed.
    private func hasIdleSessionWindow(_ provider: ProviderSnapshot) -> Bool {
        guard let session = provider.shortWindow else { return false }
        return (session.resetsAt.map { $0 <= Date() } ?? true) && (provider.longWindow?.usedPercent ?? 0) < 100
    }

    private func startClaudeWindows(_ profiles: [ClaudeAccountProfile?]) {
        guard !profiles.isEmpty else { return }
        // Refresh does not await these CLI prompts, so they never delay quota display.
        Task {
            var started = false
            for profile in profiles {
                if let id = profile?.id, !claudeProfiles.contains(where: { $0.id == id }) { continue }
                do {
                    if try await ClaudeWindowStarter.shared.start(profile: profile) { started = true }
                } catch {
                    // A newer refresh may already show the window running.
                    if let id = profile?.id {
                        guard let index = snapshot.additionalClaudeAccounts?.firstIndex(where: { $0.id == id }),
                              let quota = snapshot.additionalClaudeAccounts?[index].quota,
                              hasIdleSessionWindow(quota)
                        else { continue }
                        snapshot.additionalClaudeAccounts?[index].quota.error = error.localizedDescription
                    } else {
                        guard hasIdleSessionWindow(snapshot.claude) else { continue }
                        snapshot.claude.error = error.localizedDescription
                    }
                    saveSnapshot()
                }
            }
            // Read the new reset times instead of showing idle windows until a later refresh.
            guard started else { return }
            try? await Task.sleep(for: .seconds(5))
            refresh(providers: [.claude])
        }
    }

    private func recordFailure(
        _ error: Error,
        in provider: inout ProviderSnapshot,
        at date: Date
    ) {
        provider.lastAttemptAt = date
        provider.error = error.localizedDescription
        provider.stale = provider.headlinePercent != nil
        if provider.headlinePercent == nil {
            provider.connected = false
        }

        guard let claudeError = error as? ClaudeClientError,
              case let .rateLimited(retryAfter) = claudeError
        else {
            provider.nextAllowedRefreshAt = nil
            provider.consecutiveRateLimits = 0
            return
        }

        let failureCount = max(1, (provider.consecutiveRateLimits ?? 0) + 1)
        provider.consecutiveRateLimits = failureCount
        let exponent = min(2, failureCount - 1)
        let fallback = min(60 * 60, 15 * 60 * pow(2, Double(exponent)))
        let delay = max(fallback, retryAfter ?? 0)
        provider.nextAllowedRefreshAt = date.addingTimeInterval(delay)
    }

    private func tokenActivity(for provider: ProviderScope) -> TokenActivity {
        provider == .claude ? (snapshot.claudeTokenActivity ?? .empty) : snapshot.tokenActivity
    }

    private func resetCodexAccountIdentity(_ accountID: String) {
        snapshot.codexAccountID = accountID
        snapshot.codex = .empty
        snapshot.tokenActivity = .empty
        snapshot.codexCostLedger = nil
        snapshot.codexAccountWindowBaselines = []
        snapshot.codexWeeklyInvalidatedReset = nil
        snapshot.codexWeeklyCapacity = nil
        snapshot.codexWeeklyValue = nil
        snapshot.codexWeeklyEstimateSource = nil
        snapshot.codexWeeklyValueError = nil
        snapshot.codexActivityError = nil
        snapshot.codexActivityLastSuccessAt = nil
    }

    @discardableResult
    private func syncAccountProfiles(at date: Date = Date()) -> Bool {
        var next = snapshot
        let claudeID = ClaudeAccountProfile.primaryAccountID
        if claudeID != next.claudeAccountID {
            next.claudeAccountID = claudeID
            next.claude = .empty
            next.claudeWeeklyCapacity = nil
            next.claudeWeeklyCapacityHistory = nil
            next.claudeWeeklyValue = nil
            next.claudeWeeklyValueError = nil
        }
        let sources = environmentSources + AccountSource.detected()
        func directories(for provider: ProviderScope) -> [URL] {
            let primary = AccountSource.primaryDirectory(for: provider).path
            var seen: Set<String> = [primary]
            return sources.filter { $0.provider == provider && seen.insert($0.directory).inserted }.map(\.url)
        }
        claudeDirectories = directories(for: .claude)
        (claudeProfiles, claudePrimaryAliases) = ClaudeAccountProfile.discover(in: claudeDirectories, primaryID: claudeID)
        let previousClaude = snapshot.additionalClaudeAccounts ?? []
        let claudeAccounts = claudeProfiles.map { profile in
            let cached = previousClaude.first(where: { $0.id == profile.id })
            return ClaudeAccountSnapshot(
                id: profile.id, name: profile.name,
                sourceDirectory: profile.configDirectory.path,
                quota: cached?.quota ?? .empty,
                weeklyValue: cached?.weeklyValue,
                weeklyCapacityHistory: cached?.weeklyCapacityHistory
            )
        }
        next.additionalClaudeAccounts = claudeAccounts.isEmpty ? nil : claudeAccounts

        codexProfiles = CodexAccountProfile.discover(in: directories(for: .codex))
        let previousCodex = snapshot.additionalCodexAccounts ?? []
        let codexAccounts = codexProfiles.map { profile in
            let cached = previousCodex.first(where: { $0.id == profile.id })
            return CodexAccountSnapshot(
                id: profile.id, name: profile.name,
                sourceDirectory: profile.configDirectory.path,
                accountID: cached?.accountID,
                quota: cached?.quota ?? .empty,
                weeklyValue: cached?.weeklyValue,
                invalidatedReset: cached?.invalidatedReset,
                tokenActivity: cached?.tokenActivity,
                costLedger: cached?.costLedger,
                activityLastSuccessAt: cached?.activityLastSuccessAt
            )
        }
        next.additionalCodexAccounts = codexAccounts.isEmpty ? nil : codexAccounts
        // Usage warnings are keyed by account name, so drop those of folders that are gone or renamed.
        let usageWarnings = Set(codexAccounts.flatMap { ["\($0.name) usage", "\($0.name) local records"] }
            + ["Codex local records"])
        estimateFailures = estimateFailures.filter {
            (!$0.key.hasSuffix(" usage") && !$0.key.hasSuffix(" local records")) || usageWarnings.contains($0.key)
        }
        profileSyncAt = date
        guard next.claudeAccountID != snapshot.claudeAccountID
                || next.additionalClaudeAccounts != snapshot.additionalClaudeAccounts
                || next.additionalCodexAccounts != snapshot.additionalCodexAccounts
        else { return false }
        snapshot = next
        return true
    }

    private func loadSnapshot() {
        guard
            let data = UserDefaults.standard.data(forKey: StorageKeys.snapshot),
            let cached = try? JSONDecoder().decode(AppSnapshot.self, from: data)
        else {
            return
        }
        snapshot = cached
        migrateProviderFreshness()
        migrateCodexWeeklyEstimate()
        // Earlier snapshots hold local-day Codex data, which cannot price UTC account days,
        // and images from CODEX_HOME rather than ~/.codex.
        if snapshot.tokenActivity.utcDays != true {
            snapshot.tokenActivity.daily = []
            snapshot.codexCostLedger = nil
            snapshot.imageGenerationUsage = nil
        }
    }

    private func migrateProviderFreshness() {
        guard let legacyUpdatedAt = snapshot.updatedAt else { return }
        if snapshot.claude.lastSuccessAt == nil, snapshot.claude.headlinePercent != nil {
            snapshot.claude.lastSuccessAt = legacyUpdatedAt
        }
        if snapshot.codex.lastSuccessAt == nil, snapshot.codex.headlinePercent != nil {
            snapshot.codex.lastSuccessAt = legacyUpdatedAt
        }
        if snapshot.claude.stale == nil, snapshot.claude.error != nil, snapshot.claude.headlinePercent != nil {
            snapshot.claude.stale = true
        }
        if snapshot.codex.error != nil, snapshot.codex.headlinePercent != nil {
            snapshot.codex.stale = true
        }
    }

    private func migrateCodexWeeklyEstimate() {
        guard snapshot.codexWeeklyEstimateVersion != 5 else { return }
        snapshot.codexWeeklyEstimateVersion = 5
        snapshot.claudeWeeklyCapacityHistory = .empty
        snapshot.claudeWeeklyCapacity = nil
        snapshot.claudeWeeklyValue = nil
        snapshot.claudeTokenActivity = nil
        snapshot.claudeCostLedger = nil
        snapshot.codexCostLedger = nil
        snapshot.tokenActivity.daily = []
        for index in (snapshot.additionalCodexAccounts ?? []).indices {
            snapshot.additionalCodexAccounts?[index].weeklyValue = nil
        }
        snapshot.codexWeeklyCapacity = nil
        snapshot.codexWeeklyValue = nil
        snapshot.codexWeeklyEstimateSource = nil
        saveSnapshot()
    }

    private func saveSnapshot() {
        guard previewScenario == nil else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: StorageKeys.snapshot)
    }

    private func recentBuckets(_ buckets: [DailyUsageBucket]) -> [DailyUsageBucket] {
        let cutoff = min(ActivityPeriod.year.interval().start, ActivityPeriod.week.interval().start)
        let cutoffKey = TokenActivity.utcDayFormatter.string(from: cutoff.addingTimeInterval(-24 * 60 * 60))
        return buckets.filter { $0.startDate >= cutoffKey }
    }

    private func mixLedger(from ledger: ClaudeUsageLedger) -> MixLedger {
        MixLedger(byDayAndModel: ledger.byDayAndModel)
    }

    private func tokenActivity(from ledger: MixLedger) -> TokenActivity {
        let daily = ledger.byDayAndModel.map { day, models in
            DailyUsageBucket(
                startDate: day,
                tokens: models.values.reduce(0) { $0 + $1.total }
            )
        }.sorted { $0.startDate < $1.startDate }
        return TokenActivity(lifetimeTokens: nil, daily: daily)
    }
}

private func fetchClaudeAccounts(
    _ profiles: [ClaudeAccountProfile]
) async -> [(String, Result<ProviderSnapshot, Error>)] {
    await fetchAccountProfiles(profiles) { profile in
        (profile.id, await capture { try await ClaudeClient().fetch(profile: profile) })
    }
}

private func fetchCodexAccounts(
    _ profiles: [CodexAccountProfile], readings: CodexQuotaReadings?
) async -> [(String, Result<CodexFetchResult, Error>)] {
    await fetchAccountProfiles(profiles) { profile in
        (profile.id, await capture {
            try await CodexAppServerClient().fetch(codexHome: profile.configDirectory, readings: readings)
        })
    }
}

private func fetchAccountProfiles<Profile: Sendable, Output>(
    _ profiles: [Profile],
    fetch: @escaping @Sendable (Profile) async -> (String, Result<Output, Error>)
) async -> [(String, Result<Output, Error>)] {
    await withTaskGroup(of: (String, Result<Output, Error>).self) { group in
        var remaining = profiles.makeIterator()
        // Limit simultaneous credential reads and app-server children for large profile lists.
        for _ in 0..<2 {
            if let profile = remaining.next() { group.addTask { await fetch(profile) } }
        }
        var results: [(String, Result<Output, Error>)] = []
        while let result = await group.next() {
            results.append(result)
            if !Task.isCancelled, let profile = remaining.next() {
                group.addTask { await fetch(profile) }
            }
        }
        return results
    }
}

private func capture<T>(_ work: () async throws -> T) async -> Result<T, Error> {
    do {
        return .success(try await work())
    } catch {
        return .failure(error)
    }
}
