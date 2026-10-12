import Foundation

enum ProviderScope: String, CaseIterable, Identifiable, Hashable {
    case overview
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "All"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

enum ProviderPresentation: String, CaseIterable {
    case none
    case claudeOnly
    case codexOnly
    case both

    var showsOverview: Bool { self == .both }
    var showsClaude: Bool { self == .claudeOnly || self == .both }
    var showsCodex: Bool { self == .codexOnly || self == .both }
}

enum ActivityPeriod {
    case today
    case week
    case month
    case year

    func interval(at date: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? .distantFuture
            return DateInterval(start: start, end: end)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)
                ?? DateInterval(start: calendar.startOfDay(for: date), duration: 7 * 24 * 60 * 60)
        case .month:
            return calendar.dateInterval(of: .month, for: date)
                ?? DateInterval(start: calendar.startOfDay(for: date), duration: 31 * 24 * 60 * 60)
        case .year:
            return calendar.dateInterval(of: .year, for: date)
                ?? DateInterval(start: calendar.startOfDay(for: date), duration: 366 * 24 * 60 * 60)
        }
    }
}

struct LimitWindow: Codable, Hashable, Identifiable {
    var label: String
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?
    var limitID: String? = nil
    var limitName: String? = nil

    var quotaDisplayName: String {
        guard let limitID, limitID != "codex" else { return "Codex" }
        if let limitName, !limitName.isEmpty { return limitName }
        return "Additional quota"
    }

    var id: String {
        "\(limitID ?? "default"):\(windowMinutes ?? -1):\(label)"
    }
}

struct ProviderSnapshot: Codable, Hashable {
    var connected: Bool
    var plan: String?
    var shortWindow: LimitWindow?
    var longWindow: LimitWindow?
    var extraWindows: [LimitWindow]
    var error: String?
    var lastAttemptAt: Date? = nil
    var lastSuccessAt: Date? = nil
    var nextAllowedRefreshAt: Date? = nil
    var consecutiveRateLimits: Int? = nil
    var stale: Bool? = nil

    static let empty = ProviderSnapshot(
        connected: false,
        plan: nil,
        shortWindow: nil,
        longWindow: nil,
        extraWindows: [],
        error: nil
    )

    var headlinePercent: Double? {
        ([shortWindow, longWindow].compactMap { $0 } + extraWindows)
            .map(\.usedPercent)
            .max()
    }

    var displayWindows: [LimitWindow] {
        var seen = Set<String>()
        return ([shortWindow, longWindow].compactMap { $0 } + extraWindows)
            .filter { seen.insert($0.id).inserted }
            .sorted {
                let left = $0.windowMinutes ?? Int.max
                let right = $1.windowMinutes ?? Int.max
                return left == right ? $0.id < $1.id : left < right
            }
    }

    var weeklyPercent: Double? {
        let windows = [longWindow, shortWindow].compactMap { $0 } + extraWindows
        guard let percent = windows.first(where: {
            $0.windowMinutes == 7 * 24 * 60 && $0.limitID?.hasPrefix("claude:") != true
        })?.usedPercent, percent.isFinite else {
            return nil
        }
        return min(100, max(0, percent))
    }

    var isStale: Bool { stale == true }

    var hasDisplayableData: Bool {
        connected || headlinePercent != nil || lastSuccessAt != nil
    }
}

struct ClaudeAccountSnapshot: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var sourceDirectory: String
    var quota: ProviderSnapshot
    var weeklyValue: WeeklyValueEstimate? = nil
}

struct CodexAccountSnapshot: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var sourceDirectory: String
    var accountID: String? = nil
    var quota: ProviderSnapshot
    var weeklyValue: WeeklyValueEstimate? = nil
    var invalidatedReset: Date? = nil
}

struct DailyUsageBucket: Codable, Hashable, Identifiable {
    var startDate: String
    var tokens: Int64

    var id: String { startDate }
}

struct TokenActivity: Codable, Hashable {
    var lifetimeTokens: Int64?
    var daily: [DailyUsageBucket]
    // Codex account buckets are UTC days; each belongs to the local day containing its midpoint.
    var utcDays: Bool? = nil

    static let empty = TokenActivity(lifetimeTokens: nil, daily: [])

    func buckets(in interval: DateInterval, calendar: Calendar = .current) -> [DailyUsageBucket] {
        daily.filter { bucket in
            let date = utcDays == true
                ? Self.utcDayFormatter.date(from: bucket.startDate)?.addingTimeInterval(12 * 60 * 60)
                : Self.dayFormatter.date(from: bucket.startDate).map { calendar.startOfDay(for: $0) }
            return date.map { $0 >= interval.start && $0 < interval.end } ?? false
        }
    }

    func tokens(in interval: DateInterval, calendar: Calendar = .current) -> Int64 {
        buckets(in: interval, calendar: calendar).reduce(0) { $0 + $1.tokens }
    }

    func dayKeys(in interval: DateInterval, calendar: Calendar = .current) -> Set<String> {
        Set(buckets(in: interval, calendar: calendar).map(\.startDate))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let utcDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}


struct CodexAccountWindowBaseline: Codable, Hashable {
    var windowID: String
    var windowMinutes: Int
    var windowStartedAt: Date
    var resetsAt: Date
    var lifetimeTokens: Int64
    var observedAt: Date
    var startsAtWindowBoundary: Bool
    var usedPercent: Double? = nil
}

struct TokenBreakdown: Codable, Hashable {
    var input: Int64 = 0
    var cacheCreationInput: Int64 = 0
    var cacheCreationInput5m: Int64?
    var cacheCreationInput1h: Int64?
    var cachedInput: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0

    var total: Int64 { input + cacheCreationInput + cachedInput + output + reasoning }

    mutating func add(_ other: TokenBreakdown) {
        input += other.input
        cacheCreationInput += other.cacheCreationInput
        cacheCreationInput5m = addingOptional(cacheCreationInput5m, other.cacheCreationInput5m)
        cacheCreationInput1h = addingOptional(cacheCreationInput1h, other.cacheCreationInput1h)
        cachedInput += other.cachedInput
        output += other.output
        reasoning += other.reasoning
    }

    func positiveDelta(from previous: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: max(0, input - previous.input),
            cacheCreationInput: max(0, cacheCreationInput - previous.cacheCreationInput),
            cacheCreationInput5m: cacheCreationInput5m.map { max(0, $0 - (previous.cacheCreationInput5m ?? 0)) },
            cacheCreationInput1h: cacheCreationInput1h.map { max(0, $0 - (previous.cacheCreationInput1h ?? 0)) },
            cachedInput: max(0, cachedInput - previous.cachedInput),
            output: max(0, output - previous.output),
            reasoning: max(0, reasoning - previous.reasoning)
        )
    }

    private func addingOptional(_ left: Int64?, _ right: Int64?) -> Int64? {
        guard left != nil || right != nil else { return nil }
        return (left ?? 0) + (right ?? 0)
    }
}

struct TokenTotals: Codable, Hashable {
    var input: Int64
    var cachedInput: Int64
    var output: Int64
    var reasoning: Int64
    var total: Int64
    var cacheWriteInput: Int64? = nil

}

enum UsagePriceKey {
    static func make(model: String, speed: String? = nil, longContext: Bool = false) -> String {
        var key = model
        if speed == "fast" || speed == "priority" { key += "|fast" }
        if speed == "ultrafast" { key += "|ultrafast" }
        if longContext { key += "|long" }
        return key
    }

    static func model(_ key: String) -> String { String(key.prefix { $0 != "|" }) }

    static func speed(_ key: String) -> String {
        key.contains("|ultrafast") ? "|ultrafast" : key.contains("|fast") ? "|fast" : ""
    }
}

struct MixLedger: Codable, Hashable {
    var byDayAndModel: [String: [String: TokenBreakdown]]

    static let empty = MixLedger(byDayAndModel: [:])

    var byModel: [String: TokenBreakdown] {
        byDayAndModel.values.reduce(into: [:]) { aggregate, models in
            for (model, tokens) in models {
                var total = aggregate[model] ?? TokenBreakdown()
                total.add(tokens)
                aggregate[model] = total
            }
        }
    }
}

struct ModelPrice: Codable, Hashable {
    var inputPerToken: Double
    var cacheCreationInputPerToken: Double
    var cacheCreationInput1hPerToken: Double?
    var cachedInputPerToken: Double
    var outputPerToken: Double
    var reasoningPerToken: Double
    var longContextInputPerToken: Double? = nil
    var longContextCachedInputPerToken: Double? = nil
    var longContextCacheCreationInputPerToken: Double? = nil
    var longContextOutputPerToken: Double? = nil
}

struct PriceSourceCache: Codable, Hashable {
    var fetchedAt: Date
    var etag: String?
    var models: [String: ModelPrice]
    var sourceURL: String?
    var checkedModels: [String]?
    var lastAttemptAt: Date?

    static let empty = PriceSourceCache(
        fetchedAt: .distantPast,
        etag: nil,
        models: [:],
        sourceURL: nil,
        checkedModels: nil,
        lastAttemptAt: nil
    )
}

struct PriceCache: Codable, Hashable {
    var openAI: PriceSourceCache
    var claude: PriceSourceCache
    var fallback: PriceSourceCache

    static let empty = PriceCache(
        openAI: .empty,
        claude: .empty,
        fallback: .empty
    )
}

struct CostMix: Codable, Hashable {
    private static let minimumPricedCoverage = 0.999

    var sampledTokens: Int64
    var usdPerToken: Double?
    var missingModels: [String]
    var unpricedTokens: Int64?

    static let empty = CostMix(
        sampledTokens: 0,
        usdPerToken: nil,
        missingModels: [],
        unpricedTokens: nil
    )

    var hasPricedCoverage: Bool {
        let observed = sampledTokens + max(0, unpricedTokens ?? 0)
        return usdPerToken != nil && sampledTokens > 0
            && Double(sampledTokens) / Double(observed) >= Self.minimumPricedCoverage
    }

    func estimate(tokens: Int64) -> Double? {
        if tokens == 0 { return 0 }
        guard hasPricedCoverage, let usdPerToken else { return nil }
        return Double(tokens) * usdPerToken
    }


    static func merged(_ mixes: some Sequence<CostMix>) -> CostMix {
        var sampledTokens: Int64 = 0
        var sampledCost = 0.0
        var missingModels = Set<String>()
        var unpricedTokens: Int64 = 0

        for mix in mixes {
            sampledTokens += mix.sampledTokens
            if let rate = mix.usdPerToken {
                sampledCost += Double(mix.sampledTokens) * rate
            }
            missingModels.formUnion(mix.missingModels)
            unpricedTokens += mix.unpricedTokens ?? 0
        }

        return CostMix(
            sampledTokens: sampledTokens,
            usdPerToken: sampledTokens > 0 ? sampledCost / Double(sampledTokens) : nil,
            missingModels: missingModels.sorted(),
            unpricedTokens: unpricedTokens
        )
    }
}

struct CostLedger: Codable, Hashable {
    var byDay: [String: CostMix]

    static let empty = CostLedger(byDay: [:])

    var overall: CostMix { CostMix.merged(byDay.values) }

    func mix(for dayKeys: Set<String>) -> CostMix {
        CostMix.merged(dayKeys.compactMap { byDay[$0] })
    }
}

struct WeeklyValueEstimate: Codable, Hashable {
    var usedPercent: Double
    var observedTokens: Int64
    var observedCostUSD: Double
    var equivalentTokens: Double
    var equivalentValueUSD: Double
}

struct WeeklyTokenCapacityEstimate: Codable, Hashable {
    var usedPercent: Double
    var observedTokens: Int64
    var equivalentTokens: Double
    var equivalentValueUSD: Double? = nil
}

struct WeeklyCapacitySample: Codable, Hashable {
    var windowKey: String
    var windowStartedAt: Date
    var resetsAt: Date
    var observedAt: Date
    var usedPercent: Double
    var observedTokens: Int64
    var equivalentTokens: Double
    var source: String?
    var equivalentValueUSD: Double? = nil
}

struct WeeklyCapacityHistory: Codable, Hashable {
    var samples: [WeeklyCapacitySample]

    static let empty = WeeklyCapacityHistory(samples: [])
}

enum WeeklyValueStatus {
    case available(WeeklyValueEstimate)
    case unavailable(String)
}

enum CodexWeeklyEstimateSource: String, Codable, Hashable {
    case accountLifetime
    case localWindowFallback
}

struct AppSnapshot: Codable, Hashable {
    var claude: ProviderSnapshot
    var additionalClaudeAccounts: [ClaudeAccountSnapshot]? = nil
    var claudeAccountID: String? = nil
    var codex: ProviderSnapshot
    var additionalCodexAccounts: [CodexAccountSnapshot]? = nil
    var codexAccountID: String? = nil
    var tokenActivity: TokenActivity
    var costMix: CostMix
    var claudeTokenActivity: TokenActivity?
    var claudeCostMix: CostMix?
    var claudeCostLedger: CostLedger?
    var codexCostLedger: CostLedger?
    var claudeWeeklyCapacity: WeeklyTokenCapacityEstimate?
    var codexWeeklyCapacity: WeeklyTokenCapacityEstimate?
    var claudeWeeklyCapacityHistory: WeeklyCapacityHistory?
    var claudeWeeklyValue: WeeklyValueEstimate?
    var claudeWeeklyValueError: String?
    var codexWeeklyValue: WeeklyValueEstimate?
    var codexWeeklyValueError: String?
    var codexWeeklyEstimateSource: CodexWeeklyEstimateSource?
    var codexAccountWindowBaselines: [CodexAccountWindowBaseline]?
    var codexWeeklyEstimateVersion: Int?
    var codexWeeklyInvalidatedReset: Date? = nil
    var codexActivityError: String?
    var codexActivityLastSuccessAt: Date?
    var imageGenerationUsage: ImageGenerationUsage? = nil
    var updatedAt: Date?

    static let empty = AppSnapshot(
        claude: .empty,
        codex: .empty,
        tokenActivity: .empty,
        costMix: .empty,
        claudeTokenActivity: nil,
        claudeCostMix: nil,
        claudeCostLedger: nil,
        codexCostLedger: nil,
        claudeWeeklyCapacity: nil,
        codexWeeklyCapacity: nil,
        claudeWeeklyCapacityHistory: nil,
        claudeWeeklyValue: nil,
        claudeWeeklyValueError: nil,
        codexWeeklyValue: nil,
        codexWeeklyValueError: nil,
        codexWeeklyEstimateSource: nil,
        codexAccountWindowBaselines: [],
        codexWeeklyEstimateVersion: 5,
        codexActivityError: nil,
        codexActivityLastSuccessAt: nil,
        updatedAt: nil
    )

    /// The accounts shown as quota rows, primary first, keyed like their weekly estimates.
    func accountRows(for provider: ProviderScope) -> [(account: String?, quota: ProviderSnapshot)] {
        switch provider {
        case .claude:
            [(claudeAccountID, claude)] + (additionalClaudeAccounts ?? []).map { ($0.id, $0.quota) }
        case .codex:
            (primaryCodexYields ? [] : [(codexAccountID, codex)])
                + visibleCodexAccounts.map { ($0.accountID ?? $0.id, $0.quota) }
        case .overview:
            []
        }
    }

    var presentation: ProviderPresentation {
        let hasClaude = claude.hasDisplayableData
        let hasCodex = codex.hasDisplayableData
        switch (hasClaude, hasCodex) {
        case (false, false): return .none
        case (true, false): return .claudeOnly
        case (false, true): return .codexOnly
        case (true, true): return .both
        }
    }

    // A stale primary yields its quota rows to a fresh reading of the same account.
    var primaryCodexYields: Bool {
        codex.isStale && codexAccountID != nil && (additionalCodexAccounts ?? []).contains {
            $0.accountID == codexAccountID && !$0.quota.isStale
        }
    }

    var visibleCodexAccounts: [CodexAccountSnapshot] {
        // One row per account, preferring a fresh reading.
        let accounts = additionalCodexAccounts ?? []
        var seen = Set(primaryCodexYields ? [] : [codexAccountID].compactMap { $0 })
        let shown = Set((accounts.filter { !$0.quota.isStale } + accounts.filter(\.quota.isStale))
            .filter { seen.insert($0.accountID ?? $0.id).inserted }
            .map(\.id))
        return accounts.filter { shown.contains($0.id) }
    }
}

struct CodexWindowCursor: Codable, Hashable {
    var offset: UInt64
    var model: String?
    var previousTotal: TokenTotals?
    var logicalSessionKey: String
    var sawSessionMeta: Bool?
    var suppressingForkCopies: Bool?
    var forkCopyAnchor: Date?
    var serviceTier: String? = nil
}

struct CodexWindowLedger: Codable, Hashable {
    var windowStartedAt: Date
    var resetsAt: Date
    var observedAt: Date
    var cursors: [String: CodexWindowCursor]
    var byDayAndModel: [String: [String: TokenBreakdown]]
    var messageHashes: Set<UInt64>
    var parseErrors: Int
    var isComplete: Bool

    static func empty(windowStartedAt: Date, resetsAt: Date, observedAt: Date) -> Self {
        Self(
            windowStartedAt: windowStartedAt,
            resetsAt: resetsAt,
            observedAt: observedAt,
            cursors: [:],
            byDayAndModel: [:],
            messageHashes: [],
            parseErrors: 0,
            isComplete: false
        )
    }

    var observedTokens: Int64 {
        mixLedger.byModel.values.reduce(0) { $0 + $1.total }
    }

    var mixLedger: MixLedger {
        MixLedger(byDayAndModel: byDayAndModel)
    }
}

struct ClaudeMessageUsage: Codable, Hashable {
    var day: String
    var byModel: [String: TokenBreakdown]
}

struct ClaudeUsageLedger: Codable, Hashable {
    var cursors: [String: UInt64]
    var byDayAndModel: [String: [String: TokenBreakdown]]
    var messageUsage: [UInt64: ClaudeMessageUsage]
    // Older messages can no longer stream, so a hash is enough to skip resumed-session copies.
    var settledHashesByDay: [String: Set<UInt64>]?

    static let empty = ClaudeUsageLedger(cursors: [:], byDayAndModel: [:], messageUsage: [:])
}

struct CodexUsageLedger: Codable, Hashable {
    var cursors: [String: CodexWindowCursor]
    var byDayAndModel: [String: [String: TokenBreakdown]]
    var messageHashesByDay: [String: Set<UInt64>]
    var parseErrors: Int

    static let empty = CodexUsageLedger(
        cursors: [:],
        byDayAndModel: [:],
        messageHashesByDay: [:],
        parseErrors: 0
    )

    var mixLedger: MixLedger {
        MixLedger(byDayAndModel: byDayAndModel)
    }
}

struct ClaudeWindowLedger: Codable, Hashable {
    var windowStartedAt: Date
    var resetsAt: Date
    var observedAt: Date
    var cursors: [String: UInt64]
    var byDayAndModel: [String: [String: TokenBreakdown]]
    var messageUsage: [UInt64: ClaudeMessageUsage]
    var parseErrors: Int
    var isComplete: Bool

    static func empty(windowStartedAt: Date, resetsAt: Date, observedAt: Date) -> Self {
        Self(
            windowStartedAt: windowStartedAt,
            resetsAt: resetsAt,
            observedAt: observedAt,
            cursors: [:],
            byDayAndModel: [:],
            messageUsage: [:],
            parseErrors: 0,
            isComplete: false
        )
    }

    var observedTokens: Int64 {
        mixLedger.byModel.values.reduce(0) { $0 + $1.total }
    }

    var mixLedger: MixLedger {
        MixLedger(byDayAndModel: byDayAndModel)
    }
}
