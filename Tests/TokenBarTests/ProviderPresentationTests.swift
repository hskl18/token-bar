import CoreGraphics
import XCTest
@testable import TokenBar

final class ProviderPresentationTests: XCTestCase {
    func testQuotaRowsAreOnePerAccountWithEachProviderTogether() {
        // As the panel appends them: each account's windows in order; a Claude folder can follow the Codex ones.
        let windows: [(provider: String, account: String, window: String)] = [
            ("Claude", "h", "5h"), ("Claude", "h", "Week"), ("Claude", "h", "Fable"),
            ("Codex", "codex", "5h"), ("Codex", "codex", "Week"),
            ("Claude", "j", "5h"), ("Claude", "j", "Week"),
            ("Codex", "cli", "5h"), ("Claude", "x", "Credit"),
        ]

        let rows = quotaAccountRows(windows, provider: { $0.provider }, account: { $0.account })
        XCTAssertEqual(rows.map { $0.map { "\($0.account) \($0.window)" } }, [
            ["h 5h", "h Week", "h Fable"], ["j 5h", "j Week"], ["x Credit"],
            ["codex 5h", "codex Week"], ["cli 5h"],
        ])
        let rank = { (column: String) in column == "5h" ? 0 : column == "Week" ? 1 : 2 }
        XCTAssertEqual(quotaColumns(Array(rows.prefix(3)), column: { $0.window }, rank: rank), ["5h", "Week", "Fable", "Credit"])
        // 5h and Week lead even when the first account only has a Weekly window.
        XCTAssertEqual(quotaColumns([["Week"], ["5h", "Week"]], column: { $0 }, rank: rank), ["5h", "Week"])
        XCTAssertEqual([0, 0.4, 0.5, 2, 53, 140].map(quotaRingFill), [0, 0, 0.02, 0.02, 0.53, 1])
        // A model with a 5-hour and a Weekly window needs two columns.
        let model = [LimitWindow.sessionMinutes, LimitWindow.weeklyMinutes].map {
            ringLabel(LimitWindow(label: "", usedPercent: 0, windowMinutes: $0), detail: "Spark")
        }
        XCTAssertEqual(model, ["Spark 5h", "Spark"])
        // Main windows share a column across providers; two unnamed buckets do not share one.
        func column(_ limitID: String?, _ detail: String?, _ scope: String) -> QuotaColumn {
            QuotaColumn(window: LimitWindow(label: "", usedPercent: 0, windowMinutes: LimitWindow.sessionMinutes, limitID: limitID),
                        detail: detail, scope: scope)
        }
        XCTAssertEqual(column("claude", nil, "Claude"), column(nil, nil, "Codex"))
        XCTAssertNotEqual(column("bucket-a", "Additional quota", "Codex"), column("bucket-b", "Additional quota", "Codex"))
        // One bucket read once with its name and once without is still one column.
        let renamed = [[QuotaColumn(key: "k", title: "Spark")], [QuotaColumn(key: "k", title: "Additional quota")]]
        XCTAssertEqual(quotaColumns(renamed, column: { $0 }, rank: \.rank).map(\.title), ["Spark"])
    }

    func testEmptySnapshotHasNoProviders() {
        XCTAssertEqual(AppSnapshot.empty.presentation, .none)
    }

    func testConnectedClaudeHidesOverviewAndCodex() {
        var snapshot = AppSnapshot.empty
        snapshot.claude.connected = true

        XCTAssertEqual(snapshot.presentation, .claudeOnly)
        XCTAssertFalse(snapshot.presentation.showsOverview)
        XCTAssertTrue(snapshot.presentation.showsClaude)
        XCTAssertFalse(snapshot.presentation.showsCodex)
    }

    func testLocalHistoryAloneDoesNotInventAConnectedProvider() {
        var snapshot = AppSnapshot.empty
        snapshot.tokenActivity = TokenActivity(
            lifetimeTokens: 12,
            daily: [DailyUsageBucket(startDate: "2026-08-31", tokens: 12)]
        )

        XCTAssertEqual(snapshot.presentation, .none)
    }

    func testLastSuccessfulProviderRemainsVisibleWhenStale() {
        var snapshot = AppSnapshot.empty
        snapshot.claude.lastSuccessAt = Date()
        snapshot.claude.stale = true

        XCTAssertEqual(snapshot.presentation, .claudeOnly)
    }

    func testBothProvidersShowOverview() {
        let snapshot = PreviewScenario.both.snapshot

        XCTAssertEqual(snapshot.presentation, .both)
        XCTAssertTrue(snapshot.presentation.showsOverview)
    }

    func testSingleProviderPanelsAreCompact() {
        let dual = TokenBarLayout.panelHeight(for: .both)
        XCTAssertLessThan(TokenBarLayout.panelHeight(for: .claudeOnly), dual)
        XCTAssertLessThan(TokenBarLayout.panelHeight(for: .codexOnly), dual)
        XCTAssertEqual(TokenBarLayout.panelSize(for: .both).width, 390)
    }
}
