import CoreGraphics
import XCTest
@testable import TokenBar

final class ProviderPresentationTests: XCTestCase {
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
