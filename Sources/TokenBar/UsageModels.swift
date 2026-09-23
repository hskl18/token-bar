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
        // Older cached snapshots did not persist the server's display name.
        if limitID == "codex_bengalfox" { return "GPT-5.3-Codex-Spark" }
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
            $0.windowMinutes == 7 * 24 * 60
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

struct DailyUsageBucket: Codable, Hashable, Identifiable {
    var startDate: String
    var tokens: Int64

    var id: String { startDate }
}

struct TokenActivity: Codable, Hashable {
    var lifetimeTokens: Int64?
    var daily: [DailyUsageBucket]

    static let empty = TokenActivity(lifetimeTokens: nil, daily: [])

    func tokens(in interval: DateInterval, calendar: Calendar = .current) -> Int64 {
        daily.reduce(into: 0) { total, bucket in
            guard let date = Self.dayFormatter.date(from: bucket.startDate) else { return }
            let localDay = calendar.startOfDay(for: date)
            if interval.contains(localDay) {
                total += bucket.tokens
            }
        }
    }

    func dayKeys(in interval: DateInterval, calendar: Calendar = .current) -> Set<String> {
        Set(daily.compactMap { bucket in
            guard let date = Self.dayFormatter.date(from: bucket.startDate),
                  interval.contains(calendar.startOfDay(for: date))
            else {
                return nil
            }
            return bucket.startDate
        })
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
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

    func estimate(tokens: Int64) -> Double? {
        if tokens == 0 { return 0 }
        guard let usdPerToken, sampledTokens > 0 else {
            return nil
        }
        let unpriced = max(0, unpricedTokens ?? 0)
        let observed = sampledTokens + unpriced
        guard observed > 0,
              Double(sampledTokens) / Double(observed) >= Self.minimumPricedCoverage
        else { return nil }
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
    var codex: ProviderSnapshot
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
    var codexActivityError: String?
    var codexActivityLastSuccessAt: Date?
    var codexTodayIsLocalEstimate: Bool?
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
        codexWeeklyEstimateVersion: 4,
        codexActivityError: nil,
        codexActivityLastSuccessAt: nil,
        codexTodayIsLocalEstimate: nil,
        updatedAt: nil
    )

    var combinedCapacityPercent: Double? {
        let providers: [(ProviderSnapshot, Double?)] = [
            (
                claude,
                claudeWeeklyCapacity?.equivalentTokens
                    ?? claudeWeeklyValue?.equivalentTokens
            ),
            (
                codex,
                codexWeeklyCapacity?.equivalentTokens
                    ?? codexWeeklyValue?.equivalentTokens
            ),
        ]

        var usedTokens = 0.0
        var capacityTokens = 0.0
        for (provider, capacity) in providers {
            guard let capacity,
                  capacity.isFinite,
                  capacity > 0,
                  let percent = provider.weeklyPercent
            else {
                return nil
            }
            usedTokens += capacity * percent / 100
            capacityTokens += capacity
        }

        guard capacityTokens > 0 else { return nil }
        return min(100, max(0, usedTokens / capacityTokens * 100))
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
}

struct CodexWindowCursor: Codable, Hashable {
    var offset: UInt64
    var model: String?
    var previousTotal: TokenTotals?
    var logicalSessionKey: String
    var sawSessionMeta: Bool?
    var suppressingForkCopies: Bool?
    var forkCopyAnchor: Date?
}

struct CodexWindowLedger: Codable, Hashable {
    var windowStartedAt: Date
    var resetsAt: Date
    var observedAt: Date
    var cursors: [String: CodexWindowCursor]
    var byModel: [String: TokenBreakdown]
    var tokensByDay: [String: Int64]
    var messageHashes: Set<UInt64>
    var parseErrors: Int
    var isComplete: Bool

    static func empty(windowStartedAt: Date, resetsAt: Date, observedAt: Date) -> Self {
        Self(
            windowStartedAt: windowStartedAt,
            resetsAt: resetsAt,
            observedAt: observedAt,
            cursors: [:],
            byModel: [:],
            tokensByDay: [:],
            messageHashes: [],
            parseErrors: 0,
            isComplete: false
        )
    }

    var observedTokens: Int64 {
        byModel.values.reduce(0) { $0 + $1.total }
    }

    var mixLedger: MixLedger {
        MixLedger(byDayAndModel: ["window": byModel])
    }
}

struct ClaudeUsageLedger: Codable, Hashable {
    var cursors: [String: UInt64]
    var byDayAndModel: [String: [String: TokenBreakdown]]
    var messageHashesByDay: [String: Set<UInt64>]

    static let empty = ClaudeUsageLedger(cursors: [:], byDayAndModel: [:], messageHashesByDay: [:])
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
    var byModel: [String: TokenBreakdown]
    var messageHashes: Set<UInt64>
    var parseErrors: Int
    var isComplete: Bool

    static func empty(windowStartedAt: Date, resetsAt: Date, observedAt: Date) -> Self {
        Self(
            windowStartedAt: windowStartedAt,
            resetsAt: resetsAt,
            observedAt: observedAt,
            cursors: [:],
            byModel: [:],
            messageHashes: [],
            parseErrors: 0,
            isComplete: false
        )
    }

    var observedTokens: Int64 {
        byModel.values.reduce(0) { $0 + $1.total }
    }

    var mixLedger: MixLedger {
        MixLedger(byDayAndModel: ["window": byModel])
    }
}
