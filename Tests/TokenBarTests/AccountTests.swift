import XCTest
@testable import TokenBar

final class AccountTests: XCTestCase {
    func testDetectsSignedInProfilesBesideThePrimaryFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        func folder(_ name: String, containing file: String? = nil) throws {
            let directory = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let file { try Data("{}".utf8).write(to: directory.appendingPathComponent(file)) }
        }
        try folder(".claude", containing: ".claude.json")
        try folder(".claude-work", containing: ".claude.json")
        try folder(".claude-empty")
        try folder(".claudework", containing: ".claude.json")
        try folder(".codex-work", containing: "auth.json")
        try folder(".codex-notes", containing: "notes.txt")
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".claude-link"),
            withDestinationURL: home.appendingPathComponent(".claude-work")
        )

        XCTAssertEqual(AccountSource.detected(in: home), [
            AccountSource(provider: .claude, directory: home.appendingPathComponent(".claude-work").path),
            AccountSource(provider: .codex, directory: home.appendingPathComponent(".codex-work").path),
        ])
    }

    func testDuplicateCodexAccountsShowOnceAndPreferAFreshReading() {
        var snapshot = PreviewScenario.codex.snapshot
        snapshot.codexAccountID = "account-1"
        func account(_ directory: String, id: String, stale: Bool) -> CodexAccountSnapshot {
            var quota = snapshot.codex
            quota.stale = stale
            return CodexAccountSnapshot(
                id: directory, name: directory, sourceDirectory: directory, accountID: id, quota: quota
            )
        }
        snapshot.additionalCodexAccounts = [
            account("/a", id: "account-1", stale: false),
            account("/b", id: "account-2", stale: true),
            account("/c", id: "account-2", stale: false),
        ]

        XCTAssertFalse(snapshot.primaryCodexYields)
        XCTAssertEqual(snapshot.visibleCodexAccounts.map(\.id), ["/c"])

        snapshot.codex.stale = true
        XCTAssertTrue(snapshot.primaryCodexYields)
        XCTAssertEqual(snapshot.visibleCodexAccounts.map(\.id), ["/a", "/c"])
    }
}
