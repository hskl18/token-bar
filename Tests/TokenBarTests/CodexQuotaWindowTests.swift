import XCTest
@testable import TokenBar

final class CodexQuotaWindowTests: XCTestCase {
    private func quota(plan: String, short: Any = NSNull(), multi: Bool = true) throws -> ProviderSnapshot {
        let bucket: [String: Any] = [
            "planType": plan, "primary": short,
            "secondary": ["usedPercent": 41, "windowDurationMins": 10080]
        ]
        let result: [String: Any] = multi
            ? ["rateLimitsByLimitId": ["codex": bucket]] : ["rateLimits": bucket]
        return try parseCodexQuota(["result": result])
    }

    func testPlusDisplaysBothWindowsEvenWhenWeeklyUsageIsHigher() throws {
        for multi in [false, true] {
            let provider = try quota(plan: "plus", short: [
                "usedPercent": 0, "windowDurationMins": 300
            ], multi: multi)
            XCTAssertEqual(provider.displayWindows.map(\.windowMinutes), [300, 10080])
            XCTAssertEqual(provider.displayWindows.first?.usedPercent, 0)
            XCTAssertEqual(provider.weeklyPercent, 41)
        }
    }

    func testAbsentWindowIsNotInventedForAnyPlan() throws {
        for plan in ["plus", "pro", "business", "enterprise", "future-plan"] {
            XCTAssertEqual(try quota(plan: plan).displayWindows.map(\.windowMinutes), [10080])
        }
    }

    func testProStillDisplaysFiveHoursIfServerReturnsIt() throws {
        let provider = try quota(plan: "pro", short: [
            "usedPercent": 80, "windowDurationMins": 300
        ])
        XCTAssertEqual(provider.displayWindows.count, 2)
        XCTAssertEqual(provider.weeklyPercent, 41)
    }

    func testAdditionalBucketSurvivesAndDuplicateWindowAppearsOnce() throws {
        var provider = try quota(plan: "plus")
        provider.extraWindows = [try XCTUnwrap(provider.longWindow), LimitWindow(
            label: "5-hour window", usedPercent: 12, windowMinutes: 300,
            resetsAt: nil, limitID: "new-model"
        )]
        XCTAssertEqual(provider.displayWindows.count, 2)
        XCTAssertEqual(provider.displayWindows.first?.limitID, "new-model")
    }

    func testPanelGrowsAndShrinksWithReturnedWindows() {
        var plus = PreviewScenario.codexPlus.snapshot
        let pro = PreviewScenario.codex.snapshot
        XCTAssertEqual(TokenBarLayout.panelHeight(for: plus), TokenBarLayout.panelHeight(for: pro) + 81)
        plus.codex.shortWindow = nil
        XCTAssertEqual(TokenBarLayout.panelSize(for: plus), TokenBarLayout.panelSize(for: pro))
        XCTAssertEqual(TokenBarLayout.panelHeight(for: PreviewScenario.bothPlus.snapshot),
                       TokenBarLayout.panelHeight(for: PreviewScenario.both.snapshot) + 81)
    }
}
