import Foundation
import XCTest
@testable import TokenBar

final class CodexRuntimeLocatorTests: XCTestCase {
    func testOverrideThenRememberedThenPathThenDesktopOrder() {
        let executablePaths: Set<String> = [
            "/custom/codex",
            "/remembered/codex",
            "/tools/codex",
            "/Volumes/Developer Apps/ChatGPT.app/Contents/Resources/codex",
        ]
        let locator = CodexRuntimeLocator(
            environment: ["CODEX_BIN": "/custom/codex", "PATH": "/tools"],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            desktopApplicationURL: URL(fileURLWithPath: "/Volumes/Developer Apps/ChatGPT.app"),
            rememberedExecutable: "/remembered/codex",
            isExecutable: { executablePaths.contains($0) }
        )

        let candidates = locator.candidates()

        XCTAssertEqual(candidates.map(\.executableURL.path), [
            "/custom/codex",
            "/remembered/codex",
            "/tools/codex",
            "/Volumes/Developer Apps/ChatGPT.app/Contents/Resources/codex",
        ])
        XCTAssertEqual(candidates.map(\.source), [
            .override,
            .remembered,
            .path,
            .desktopApp,
        ])
    }

    func testDesktopAppDiscoveryDoesNotDependOnApplicationsFolder() {
        let runtime = "/External/Apps/ChatGPT.app/Contents/Resources/codex"
        let locator = CodexRuntimeLocator(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            desktopApplicationURL: URL(fileURLWithPath: "/External/Apps/ChatGPT.app"),
            rememberedExecutable: nil,
            isExecutable: { $0 == runtime }
        )

        XCTAssertEqual(locator.candidates(), [
            CodexRuntimeCandidate(
                executableURL: URL(fileURLWithPath: runtime),
                source: .desktopApp
            ),
        ])
    }

    func testDuplicateRuntimePathsAreProbedOnce() {
        let locator = CodexRuntimeLocator(
            environment: ["CODEX_BIN": "/tools/codex", "PATH": "/tools"],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            desktopApplicationURL: nil,
            rememberedExecutable: "/tools/codex",
            isExecutable: { $0 == "/tools/codex" }
        )

        XCTAssertEqual(locator.candidates().count, 1)
        XCTAssertEqual(locator.candidates().first?.source, .override)
    }

    func testPreviewScenariosCoverRequiredProviderStates() {
        XCTAssertEqual(PreviewScenario.claude.snapshot.presentation, .claudeOnly)
        XCTAssertEqual(PreviewScenario.codex.snapshot.presentation, .codexOnly)
        XCTAssertEqual(PreviewScenario.both.snapshot.presentation, .both)
    }
}
