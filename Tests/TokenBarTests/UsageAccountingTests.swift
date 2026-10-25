import XCTest
@testable import TokenBar

final class UsageAccountingTests: XCTestCase {
    func testUTCAccountDaysBelongToTheLocalDayHoldingTheirMidpoint() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11)))
        let activity = TokenActivity(
            lifetimeTokens: nil,
            daily: ["2026-10-10", "2026-10-11", "2026-10-12"].map { DailyUsageBucket(startDate: $0, tokens: 1) },
            utcDays: true
        )

        let buckets = activity.buckets(in: DateInterval(start: start, duration: 24 * 60 * 60), calendar: calendar)
        XCTAssertEqual(buckets.map(\.startDate), ["2026-10-11"])
    }

    func testDailyPricesStayFrozenWhenTheCatalogChanges() async throws {
        let suite = "TokenBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // A fresh cache for every source keeps the catalog offline.
        func publish(rate: Double) throws {
            let price = ModelPrice(
                inputPerToken: rate, cacheCreationInputPerToken: rate, cacheCreationInput1hPerToken: nil,
                cachedInputPerToken: rate, outputPerToken: rate, reasoningPerToken: rate
            )
            func source(_ url: String, _ models: [String: ModelPrice]) -> PriceSourceCache {
                PriceSourceCache(
                    fetchedAt: Date(), etag: nil, models: models, sourceURL: url, checkedModels: nil, lastAttemptAt: nil
                )
            }
            let cache = PriceCache(
                openAI: source(PriceCatalog.openAIURL, ["gpt-test": price]),
                claude: source(PriceCatalog.claudeURL, [:]),
                fallback: source(PriceCatalog.defaultFallbackURL, [:])
            )
            defaults.set(try JSONEncoder().encode(cache), forKey: StorageKeys.priceCache)
        }
        let usage = ["gpt-test": TokenBreakdown(input: 100)]

        try publish(rate: 1e-6)
        let first = await PriceCatalog(defaults: defaults).costLedger(for: MixLedger(byDayAndModel: [
            "2026-10-01": usage,
        ]))
        try publish(rate: 2e-6)
        let second = await PriceCatalog(defaults: defaults).costLedger(for: MixLedger(byDayAndModel: [
            "2026-10-01": usage, "2026-10-02": usage,
        ]))

        XCTAssertEqual(try XCTUnwrap(first.byDay["2026-10-01"]?.usdPerToken), 1e-6, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(second.byDay["2026-10-01"]?.usdPerToken), 1e-6, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(second.byDay["2026-10-02"]?.usdPerToken), 2e-6, accuracy: 1e-12)
    }

    func testCodexSessionsCountOnlyForTheLoginThatCreatedThem() {
        let tokens = #"{"timestamp":"2026-10-24T01:00:00Z","type":"event_msg","payload":{"type":"token_count","#
            + #""info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}"#
        func events(creator: String?, folderLogin: String?) -> Int {
            let meta = #"{"type":"session_meta","payload":{"id":"s1""#
                + (creator.map { #","creator_account_id":"\#($0)""# } ?? "") + "}}"
            var cursor = CodexWindowCursor(
                offset: 0, model: nil, previousTotal: nil, logicalSessionKey: "rollout.jsonl",
                sawSessionMeta: false, suppressingForkCopies: false, forkCopyAnchor: nil
            )
            let parser = CodexTranscriptParser(accountID: folderLogin)
            return [meta, tokens].compactMap { parser.parse(Data($0.utf8), path: "rollout.jsonl", cursor: &cursor).event }.count
        }

        XCTAssertEqual(events(creator: "cli", folderLogin: "plus"), 0, "a session copied in from another login's folder")
        XCTAssertEqual(events(creator: "cli", folderLogin: "cli"), 1)
        XCTAssertEqual(events(creator: nil, folderLogin: "plus"), 1, "older sessions do not record a creator")
        XCTAssertEqual(events(creator: "cli", folderLogin: nil), 1, "an unknown folder login keeps every session")
    }

    func testClaudeLimitsRowsReplaceLegacyFieldsWithoutTouchingAllModels() throws {
        let reset = "2026-10-15T20:00:00Z"
        let body: [String: Any] = [
            "five_hour": ["utilization": 20, "resets_at": reset],
            "seven_day": ["utilization": 40, "resets_at": reset],
            "seven_day_opus": ["utilization": 10, "resets_at": reset],
            "limits": [
                ["kind": "weekly_all", "utilization": 45, "resets_at": reset],
                ["kind": "weekly_scoped", "group": "models", "utilization": 12, "resets_at": reset,
                 "scope": ["model": ["display_name": "Opus"]]],
            ],
            "extra_usage": ["is_enabled": true, "used_credits": 5.0, "monthly_limit": 20.0],
        ]

        let snapshot = try ClaudeClient().parseSnapshot(data: JSONSerialization.data(withJSONObject: body))

        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 20)
        XCTAssertEqual(snapshot.longWindow?.usedPercent, 45)
        XCTAssertEqual(snapshot.weeklyPercent, 45)
        XCTAssertEqual(snapshot.extraWindows.map(\.limitName), ["Opus", "Usage credits"])
        XCTAssertEqual(snapshot.extraWindows.map(\.usedPercent), [12, 25])
    }
}
