import Combine
import Foundation

@MainActor
final class TokenBarStore: ObservableObject {
    @Published var snapshot: AppSnapshot = .empty
    @Published var isRefreshing = false

    private let freshnessInterval: TimeInterval = 3 * 60
    private let previewScenario: PreviewScenario?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        previewScenario = PreviewScenario.current(environment: environment)
        if let previewScenario {
            snapshot = previewScenario.snapshot
        } else {
            loadSnapshot()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func start() {
        guard previewScenario == nil else { return }
        refresh(
            force: snapshot.updatedAt == nil
                || snapshot.codexCostLedger == nil
                || snapshot.claudeCostLedger == nil
                || (snapshot.codexWeeklyEstimateSource == nil
                    && snapshot.codex.headlinePercent != nil)
        )
    }

    func refreshIfStale() {
        refresh(force: false)
    }

    func refresh(force: Bool = true) {
        guard previewScenario == nil else { return }
        guard !isRefreshing else { return }

        let attemptedAt = Date()
        let shouldRefreshCodex = shouldAttempt(snapshot.codex, force: force, at: attemptedAt)
        let claudeCredentialChanged = ClaudeClient.credentialWasModified(
            after: snapshot.claude.lastAttemptAt
        )
        let shouldRefreshClaude = shouldAttempt(
            snapshot.claude,
            force: force,
            at: attemptedAt,
            externalStateChanged: claudeCredentialChanged
        )
        guard shouldRefreshCodex || shouldRefreshClaude else { return }

        if shouldRefreshCodex { snapshot.codex.lastAttemptAt = attemptedAt }
        if shouldRefreshClaude { snapshot.claude.lastAttemptAt = attemptedAt }
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

            async let codexResult: Result<CodexFetchResult, Error>? = shouldRefreshCodex
                ? capture { try await CodexAppServerClient().fetch() }
                : nil
            async let claudeResult: Result<ProviderSnapshot, Error>? = shouldRefreshClaude
                ? capture { try await ClaudeClient().fetch() }
                : nil
            async let claudeLedgerResult = ClaudeMixSampler().update()
            async let codexUsageLedgerResult = CodexMixSampler().update()

            let (codex, claude, claudeLedger, codexUsageLedger) = await (
                codexResult,
                claudeResult,
                claudeLedgerResult,
                codexUsageLedgerResult
            )
            guard !Task.isCancelled, refreshGeneration == generation else { return }

            var officialCodexActivity: TokenActivity?
            var codexSucceeded = false
            if let codex {
                switch codex {
                case let .success(result):
                    switch result.quota {
                    case var .success(quota):
                        recordSuccess(&quota, at: attemptedAt)
                        snapshot.codex = quota
                        codexSucceeded = true
                    case let .failure(error):
                        recordFailure(error, in: &snapshot.codex, at: attemptedAt)
                    }
                    switch result.activity {
                    case let .success(resultActivity):
                        let activity = TokenActivity(
                            lifetimeTokens: resultActivity.lifetimeTokens,
                            daily: recentBuckets(resultActivity.daily)
                        )
                        snapshot.codex.connected = true
                        officialCodexActivity = activity
                        snapshot.tokenActivity = activity
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

            var claudeSucceeded = false
            if let claude {
                switch claude {
                case var .success(result):
                    recordSuccess(&result, at: attemptedAt)
                    snapshot.claude = result
                    claudeSucceeded = true
                case let .failure(error):
                    recordFailure(error, in: &snapshot.claude, at: attemptedAt)
                }
            }

            var codexWindowResult: Result<CodexWindowLedger, Error>?
            if codexSucceeded,
               let weeklyWindow = weeklyWindow(in: snapshot.codex),
               let durationMinutes = weeklyWindow.windowMinutes,
               let resetsAt = weeklyWindow.resetsAt {
                let windowStartedAt = resetsAt.addingTimeInterval(-Double(durationMinutes) * 60)
                codexWindowResult = await capture {
                    try await CodexWindowSampler().update(
                        windowStartedAt: windowStartedAt,
                        resetsAt: resetsAt
                    )
                }
            }

            var claudeWindowResult: Result<ClaudeWindowLedger, Error>?
            if claudeSucceeded,
               let weeklyWindow = weeklyWindow(in: snapshot.claude),
               let durationMinutes = weeklyWindow.windowMinutes,
               let resetsAt = weeklyWindow.resetsAt {
                snapshot.claudeWeeklyValueError = "Updating the exact local weekly window..."
                let windowStartedAt = resetsAt.addingTimeInterval(-Double(durationMinutes) * 60)
                claudeWindowResult = await capture {
                    try await ClaudeWindowSampler().update(
                        windowStartedAt: windowStartedAt,
                        resetsAt: resetsAt
                    )
                }
            }

            let claudeMixLedger = mixLedger(from: claudeLedger)
            let codexCalendarLedger = codexUsageLedger.mixLedger
            let codexWindowLedger: CodexWindowLedger? = {
                guard case let .success(ledger)? = codexWindowResult else { return nil }
                return ledger
            }()
            let claudeWindowLedger: ClaudeWindowLedger? = {
                guard case let .success(ledger)? = claudeWindowResult else { return nil }
                return ledger
            }()
            let codexLedger: MixLedger = {
                if let codexWindowLedger, codexWindowLedger.observedTokens > 0 {
                    return codexWindowLedger.mixLedger
                }
                return CodexWindowSampler().lastKnownMixLedger() ?? .empty
            }()
            let claudeWindowLedgerForPricing = claudeWindowLedger?.mixLedger ?? .empty
            let catalog = PriceCatalog()
            _ = await catalog.costMix(
                for: mergedLedger(mergedLedger(codexCalendarLedger, codexLedger), claudeMixLedger)
            )
            let codexMix = await catalog.costMix(for: codexLedger)
            let codexCostLedger = await catalog.costLedger(for: codexCalendarLedger)
            let claudeCostLedger = await catalog.costLedger(for: claudeMixLedger)
            let claudeWindowMix = await catalog.costMix(for: claudeWindowLedgerForPricing)
            guard !Task.isCancelled, refreshGeneration == generation else { return }

            if !codexLedger.byModel.isEmpty {
                snapshot.costMix = codexMix
            }
            snapshot.claudeTokenActivity = tokenActivity(from: claudeLedger)
            snapshot.claudeCostMix = claudeCostLedger.overall
            if !claudeCostLedger.byDay.isEmpty {
                snapshot.claudeCostLedger = claudeCostLedger
            }
            if !codexCostLedger.byDay.isEmpty {
                snapshot.codexCostLedger = codexCostLedger
            }
            if let officialCodexActivity {
                let merged = mergedCodexActivity(
                    official: officialCodexActivity,
                    ledger: codexWindowLedger
                )
                snapshot.tokenActivity = merged.activity
                snapshot.codexTodayIsLocalEstimate = merged.usesLocalToday
            }
            if codexSucceeded {
                updateCodexAccountEstimates(
                    activity: officialCodexActivity,
                    costMix: codexMix,
                    localResult: codexWindowResult,
                    localLedger: codexWindowLedger,
                    observedAt: attemptedAt
                )
            }
            updateClaudeWeeklyValue(
                result: claudeWindowResult,
                ledger: claudeWindowLedger,
                costMix: claudeWindowMix
            )

            snapshot.updatedAt = [snapshot.claude.lastSuccessAt, snapshot.codex.lastSuccessAt]
                .compactMap { $0 }
                .max()
            saveSnapshot()
        }
    }

    func cancelRefresh() {
        guard isRefreshing else { return }
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func lastSuccessDate(for provider: ProviderScope) -> Date? {
        switch provider {
        case .claude:
            snapshot.claude.lastSuccessAt
        case .codex:
            snapshot.codex.lastSuccessAt
        case .overview:
            [snapshot.claude.lastSuccessAt, snapshot.codex.lastSuccessAt]
                .compactMap { $0 }
                .min()
        }
    }

    func isStale(_ provider: ProviderScope) -> Bool {
        switch provider {
        case .claude:
            snapshot.claude.isStale
        case .codex:
            snapshot.codex.isStale
        case .overview:
            snapshot.claude.isStale || snapshot.codex.isStale
        }
    }

    func tokens(for provider: ProviderScope, period: ActivityPeriod) -> Int64 {
        tokenActivity(for: provider).tokens(in: period.interval())
    }

    func estimatedCost(for provider: ProviderScope, period: ActivityPeriod) -> Double? {
        let activity = tokenActivity(for: provider)
        let interval = period.interval()
        let tokens = activity.tokens(in: interval)
        if tokens == 0 { return 0 }
        let ledger = provider == .claude
            ? snapshot.claudeCostLedger
            : snapshot.codexCostLedger
        let mix = ledger?.mix(for: activity.dayKeys(in: interval)) ?? .empty
        return mix.estimate(tokens: tokens)
    }

    func codexWeeklyValueStatus() -> WeeklyValueStatus {
        if let estimate = snapshot.codexWeeklyValue {
            return .available(estimate)
        }
        return .unavailable(snapshot.codexWeeklyValueError ?? "Waiting for an account-wide weekly baseline.")
    }

    func weeklyValue(for provider: ProviderScope) -> WeeklyValueEstimate? {
        switch provider {
        case .overview:
            nil
        case .claude:
            snapshot.claudeWeeklyValue
        case .codex:
            snapshot.codexWeeklyValue
        }
    }

    private func updateClaudeWeeklyValue(
        result: Result<ClaudeWindowLedger, Error>?,
        ledger: ClaudeWindowLedger?,
        costMix: CostMix
    ) {
        guard let result else {
            if weeklyWindow(in: snapshot.claude) == nil {
                snapshot.claudeWeeklyValue = nil
                snapshot.claudeWeeklyValueError = "Weekly usage is unavailable."
            }
            return
        }
        if case let .failure(error) = result {
            snapshot.claudeWeeklyValueError = "Exact local scan failed: \(error.localizedDescription)"
            return
        }
        guard let ledger, ledger.isComplete else {
            snapshot.claudeWeeklyValueError = "The exact local weekly window is still updating."
            return
        }
        guard ledger.parseErrors == 0 else {
            snapshot.claudeWeeklyValueError = "The local window contains \(ledger.parseErrors) unreadable log entries."
            return
        }
        guard let window = weeklyWindow(in: snapshot.claude) else {
            snapshot.claudeWeeklyCapacity = nil
            snapshot.claudeWeeklyValue = nil
            snapshot.claudeWeeklyValueError = "Weekly usage is unavailable."
            return
        }

        var history = snapshot.claudeWeeklyCapacityHistory ?? .empty
        let capacity = WeeklyCapacityEstimator.update(
            history: &history,
            window: window,
            observedTokens: ledger.observedTokens,
            observedAt: ledger.observedAt,
            source: "local"
        )
        snapshot.claudeWeeklyCapacityHistory = history
        if let capacity {
            snapshot.claudeWeeklyCapacity = capacity
        }
        let status = weeklyValueEstimate(
            capacity: capacity,
            observedTokens: ledger.observedTokens,
            costMix: costMix,
            requiresExactTokenMatch: true
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
        guard let window = weeklyWindow(in: snapshot.codex),
              let durationMinutes = window.windowMinutes,
              let resetsAt = window.resetsAt
        else {
            snapshot.codexWeeklyCapacity = nil
            snapshot.codexWeeklyValue = nil
            snapshot.codexWeeklyEstimateSource = nil
            snapshot.codexWeeklyValueError = "Weekly usage is unavailable."
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
        var history = snapshot.codexWeeklyCapacityHistory ?? .empty
        let capacity = WeeklyCapacityEstimator.update(
            history: &history,
            window: window,
            observedTokens: observedTokens,
            observedAt: observedAt,
            source: CodexWeeklyEstimateSource.accountLifetime.rawValue
        )
        snapshot.codexWeeklyCapacityHistory = history
        if let capacity {
            snapshot.codexWeeklyCapacity = capacity
            snapshot.codexWeeklyEstimateSource = .accountLifetime
        }
        let status = weeklyValueEstimate(
            capacity: capacity,
            observedTokens: observedTokens,
            costMix: costMix,
            requiresExactTokenMatch: false
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
            return
        }
        guard let window = weeklyWindow(in: snapshot.codex) else {
            snapshot.codexWeeklyValueError = "Weekly usage is unavailable."
            return
        }

        var history = snapshot.codexWeeklyCapacityHistory ?? .empty
        let capacity = WeeklyCapacityEstimator.update(
            history: &history,
            window: window,
            observedTokens: ledger.observedTokens,
            observedAt: ledger.observedAt,
            source: CodexWeeklyEstimateSource.localWindowFallback.rawValue
        )
        snapshot.codexWeeklyCapacityHistory = history
        if let capacity {
            snapshot.codexWeeklyCapacity = capacity
            snapshot.codexWeeklyEstimateSource = .localWindowFallback
        }
        let status = weeklyValueEstimate(
            capacity: capacity,
            observedTokens: ledger.observedTokens,
            costMix: costMix,
            requiresExactTokenMatch: true
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
                    || window.usedPercent <= 0.5
            )
        }
    }

    private func weeklyValueEstimate(
        capacity: WeeklyTokenCapacityEstimate?,
        observedTokens: Int64,
        costMix: CostMix,
        requiresExactTokenMatch: Bool
    ) -> WeeklyValueStatus {
        guard let capacity else {
            return .unavailable("Waiting for enough current or prior weekly observations.")
        }
        guard costMix.missingModels.isEmpty,
              (!requiresExactTokenMatch || costMix.sampledTokens == observedTokens),
              let rate = costMix.usdPerToken,
              let observedCost = costMix.estimate(tokens: observedTokens)
        else {
            return .unavailable("Waiting for exact prices for the models used in this window.")
        }

        let equivalentValue = capacity.equivalentTokens * rate
        guard equivalentValue.isFinite else {
            return .unavailable("The local estimate is temporarily unavailable.")
        }

        return .available(WeeklyValueEstimate(
            usedPercent: capacity.usedPercent,
            observedTokens: observedTokens,
            observedCostUSD: observedCost,
            equivalentTokens: capacity.equivalentTokens,
            equivalentValueUSD: equivalentValue
        ))
    }

    private func weeklyWindow(in provider: ProviderSnapshot) -> LimitWindow? {
        allWindows(in: provider)
            .first { $0.windowMinutes == 7 * 24 * 60 }
    }

    private func allWindows(in provider: ProviderSnapshot) -> [LimitWindow] {
        [provider.longWindow, provider.shortWindow].compactMap { $0 } + provider.extraWindows
    }

    private func shouldAttempt(
        _ provider: ProviderSnapshot,
        force: Bool,
        at date: Date,
        externalStateChanged: Bool = false
    ) -> Bool {
        if externalStateChanged {
            return true
        }
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
    }

    private func migrateProviderFreshness() {
        guard let legacyUpdatedAt = snapshot.updatedAt else { return }
        if snapshot.claude.lastSuccessAt == nil, snapshot.claude.headlinePercent != nil {
            snapshot.claude.lastSuccessAt = legacyUpdatedAt
        }
        if snapshot.codex.lastSuccessAt == nil, snapshot.codex.headlinePercent != nil {
            snapshot.codex.lastSuccessAt = legacyUpdatedAt
        }
        if snapshot.claude.error != nil, snapshot.claude.headlinePercent != nil {
            snapshot.claude.stale = true
        }
        if snapshot.codex.error != nil, snapshot.codex.headlinePercent != nil {
            snapshot.codex.stale = true
        }
    }

    private func migrateCodexWeeklyEstimate() {
        guard snapshot.codexWeeklyEstimateVersion != 3 else { return }
        snapshot.codexWeeklyEstimateVersion = 3
        snapshot.claudeWeeklyCapacityHistory = snapshot.claudeWeeklyCapacityHistory ?? .empty
        snapshot.codexWeeklyCapacityHistory = snapshot.codexWeeklyCapacityHistory ?? .empty
        saveSnapshot()
    }

    private func saveSnapshot() {
        guard previewScenario == nil else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: StorageKeys.snapshot)
    }

    private func recentBuckets(_ buckets: [DailyUsageBucket]) -> [DailyUsageBucket] {
        let calendar = Calendar.current
        let cutoff = calendar.dateInterval(of: .year, for: Date())?.start
            ?? calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return buckets.filter { bucket in
            guard let date = formatter.date(from: bucket.startDate) else { return false }
            return date >= cutoff
        }
    }

    private func mergedCodexActivity(
        official: TokenActivity,
        ledger: CodexWindowLedger?
    ) -> (activity: TokenActivity, usesLocalToday: Bool) {
        let today = Self.localDayFormatter.string(from: Date())
        guard !official.daily.contains(where: { $0.startDate == today }),
              let ledger,
              ledger.isComplete,
              ledger.parseErrors == 0,
              let localTokens = ledger.tokensByDay[today],
              localTokens > 0
        else {
            return (official, false)
        }

        var daily = official.daily
        daily.append(DailyUsageBucket(startDate: today, tokens: localTokens))
        daily.sort { $0.startDate < $1.startDate }
        return (
            TokenActivity(lifetimeTokens: official.lifetimeTokens, daily: daily),
            true
        )
    }

    private func mixLedger(from ledger: ClaudeUsageLedger) -> MixLedger {
        MixLedger(byDayAndModel: ledger.byDayAndModel)
    }

    private func mergedLedger(_ first: MixLedger, _ second: MixLedger) -> MixLedger {
        var byDayAndModel = first.byDayAndModel
        for (day, models) in second.byDayAndModel {
            var combinedModels = byDayAndModel[day] ?? [:]
            for (model, tokens) in models {
                var aggregate = combinedModels[model] ?? TokenBreakdown()
                aggregate.add(tokens)
                combinedModels[model] = aggregate
            }
            byDayAndModel[day] = combinedModels
        }
        return MixLedger(byDayAndModel: byDayAndModel)
    }

    private func tokenActivity(from ledger: ClaudeUsageLedger) -> TokenActivity {
        let daily = ledger.byDayAndModel.map { day, models in
            DailyUsageBucket(
                startDate: day,
                tokens: models.values.reduce(0) { $0 + $1.total }
            )
        }.sorted { $0.startDate < $1.startDate }
        return TokenActivity(lifetimeTokens: nil, daily: daily)
    }

    private static let localDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private func capture<T>(_ work: () async throws -> T) async -> Result<T, Error> {
    do {
        return .success(try await work())
    } catch {
        return .failure(error)
    }
}
