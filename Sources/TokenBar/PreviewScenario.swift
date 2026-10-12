import Foundation

enum PreviewScenario: String {
    case claude
    case codex
    case both
    case codexPlus = "codex-plus"
    case bothPlus = "both-plus"
    case multiAccount = "multi-account"

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        environment["TOKENBAR_PREVIEW_STATE"].flatMap(Self.init(rawValue:))
    }

    var snapshot: AppSnapshot {
        let now = Date()
        var snapshot = AppSnapshot.empty

        if self == .claude || self == .both || self == .bothPlus || self == .multiAccount {
            let activity = makeActivity(
                now: now,
                dailyTokens: [0: 24_600_000, 2: 96_000_000, 10: 286_000_000, 90: 880_000_000]
            )
            snapshot.claude = ProviderSnapshot(
                connected: true,
                plan: "Claude Code",
                shortWindow: LimitWindow(
                    label: "5-hour window",
                    usedPercent: 46,
                    windowMinutes: 5 * 60,
                    resetsAt: now.addingTimeInterval(2.2 * 60 * 60)
                ),
                longWindow: LimitWindow(
                    label: "All models",
                    usedPercent: 73,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: now.addingTimeInterval(31 * 60 * 60)
                ),
                extraWindows: [],
                error: nil,
                lastSuccessAt: now.addingTimeInterval(-12),
                stale: false
            )
            snapshot.claudeTokenActivity = activity
            snapshot.claudeCostLedger = makeCostLedger(activity: activity, usdPerToken: 0.00000062)
            snapshot.claudeWeeklyCapacity = WeeklyTokenCapacityEstimate(
                usedPercent: 73,
                observedTokens: 730_000_000,
                equivalentTokens: 1_000_000_000
            )
            snapshot.claudeWeeklyValue = WeeklyValueEstimate(
                usedPercent: 73,
                observedTokens: 730_000_000,
                observedCostUSD: 492.75,
                equivalentTokens: 1_000_000_000,
                equivalentValueUSD: 675
            )
        }

        if self != .claude {
            let activity = makeActivity(
                now: now,
                dailyTokens: [0: 39_700_000, 1: 128_000_000, 9: 374_000_000, 120: 1_160_000_000]
            )
            snapshot.codex = ProviderSnapshot(
                connected: true,
                plan: "pro",
                shortWindow: nil,
                longWindow: LimitWindow(
                    label: "7-day window",
                    usedPercent: 41,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: now.addingTimeInterval(5.8 * 24 * 60 * 60),
                    limitID: "codex"
                ),
                extraWindows: [],
                error: nil,
                lastSuccessAt: now.addingTimeInterval(-12),
                stale: false
            )
            snapshot.tokenActivity = activity
            snapshot.codexCostLedger = makeCostLedger(activity: activity, usdPerToken: 0.00000073)
            snapshot.codexWeeklyCapacity = WeeklyTokenCapacityEstimate(
                usedPercent: 41,
                observedTokens: 195_283_000,
                equivalentTokens: 476_300_000
            )
            snapshot.codexWeeklyValue = WeeklyValueEstimate(
                usedPercent: 41,
                observedTokens: 195_283_000,
                observedCostUSD: 143.09,
                equivalentTokens: 476_300_000,
                equivalentValueUSD: 349
            )
        }

        if self == .codexPlus || self == .bothPlus {
            snapshot.codex.plan = "plus"
            snapshot.codex.shortWindow = LimitWindow(
                label: "5-hour window", usedPercent: 62, windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2.5 * 60 * 60), limitID: "codex"
            )
        }

        if self == .multiAccount {
            snapshot.additionalClaudeAccounts = [ClaudeAccountSnapshot(
                id: "preview-claude-work",
                name: "Claude-work",
                sourceDirectory: "~/.claude-work",
                quota: ProviderSnapshot(
                    connected: true,
                    plan: "Claude Code",
                    shortWindow: LimitWindow(
                        label: "5-hour window", usedPercent: 18, windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(3.6 * 60 * 60)
                    ),
                    longWindow: LimitWindow(
                        label: "All models", usedPercent: 34, windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(4.5 * 24 * 60 * 60)
                    ),
                    extraWindows: [],
                    error: nil,
                    lastSuccessAt: now.addingTimeInterval(-12),
                    stale: false
                ),
                weeklyValue: WeeklyValueEstimate(
                    usedPercent: 34,
                    observedTokens: 306_000_000,
                    observedCostUSD: 207.40,
                    equivalentTokens: 900_000_000,
                    equivalentValueUSD: 610
                )
            )]
            snapshot.additionalCodexAccounts = [CodexAccountSnapshot(
                id: "~/.codex-work",
                name: "Codex-work",
                sourceDirectory: "~/.codex-work",
                accountID: "preview-codex-work",
                quota: ProviderSnapshot(
                    connected: true,
                    plan: "plus",
                    shortWindow: LimitWindow(
                        label: "5-hour window", usedPercent: 27, windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(1.4 * 60 * 60), limitID: "codex"
                    ),
                    longWindow: LimitWindow(
                        label: "7-day window", usedPercent: 22, windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(3.2 * 24 * 60 * 60), limitID: "codex"
                    ),
                    extraWindows: [],
                    error: nil,
                    lastSuccessAt: now.addingTimeInterval(-12),
                    stale: false
                ),
                weeklyValue: WeeklyValueEstimate(
                    usedPercent: 22,
                    observedTokens: 25_000_000,
                    observedCostUSD: 12.10,
                    equivalentTokens: 113_600_000,
                    equivalentValueUSD: 55
                )
            )]
        }

        snapshot.updatedAt = now.addingTimeInterval(-12)
        return snapshot
    }
}

private func makeActivity(now: Date, dailyTokens: [Int: Int64]) -> TokenActivity {
    let calendar = Calendar.current
    let buckets = dailyTokens.compactMap { daysAgo, tokens -> DailyUsageBucket? in
        guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { return nil }
        return DailyUsageBucket(startDate: previewDayFormatter.string(from: date), tokens: tokens)
    }.sorted { $0.startDate < $1.startDate }
    return TokenActivity(
        lifetimeTokens: buckets.reduce(0) { $0 + $1.tokens },
        daily: buckets
    )
}

private func makeCostLedger(activity: TokenActivity, usdPerToken: Double) -> CostLedger {
    CostLedger(byDay: Dictionary(uniqueKeysWithValues: activity.daily.map { bucket in
        (
            bucket.startDate,
            CostMix(
                sampledTokens: bucket.tokens,
                usdPerToken: usdPerToken,
                missingModels: [],
                unpricedTokens: 0
            )
        )
    }))
}

private let previewDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()
