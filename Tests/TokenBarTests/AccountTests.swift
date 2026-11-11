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

    // 2026-11-11: ~/.claude-z was renamed ~/.claude-h while ~/.claude-j held the same login; the renamed folder had
    // no Keychain item yet, so the whole login read "Signed out." although ~/.claude-j was signed in.
    func testALoginReadsWithTheFirstOfItsFoldersThatHoldsASignIn() throws {
        let named = URL(fileURLWithPath: "/home/.claude-h"), alias = URL(fileURLWithPath: "/home/.claude-j")
        let profile = ClaudeAccountProfile(id: "login", name: "Claude-h", configDirectory: named, aliases: [alias])
        let locations = ClaudeSignInLocation.all(for: profile, primaryAliases: [])
        XCTAssertEqual(locations, [
            ClaudeSignInLocation(directory: named, keychainServices: [ClaudeAccountProfile.keychainService(for: named)]),
            ClaudeSignInLocation(directory: alias, keychainServices: [ClaudeAccountProfile.keychainService(for: alias)]),
        ])
        func signedIn(_ tokens: [URL: String]) -> (ClaudeSignInLocation) throws -> String {
            { try tokens[$0.directory] ?? { throw ClaudeClientError.credentialMissing }() }
        }

        XCTAssertEqual(try ClaudeSignInLocation.firstSignIn(in: locations, read: signedIn([alias: "j"])).location.directory, alias)
        XCTAssertEqual(try ClaudeSignInLocation.firstSignIn(in: locations, read: signedIn([named: "h", alias: "j"])).token, "h")
        XCTAssertThrowsError(try ClaudeSignInLocation.firstSignIn(in: locations) {
            throw $0.directory == named ? ClaudeClientError.credentialUnreadable : ClaudeClientError.credentialMissing
        }) { error in
            guard case ClaudeClientError.credentialUnreadable = error else { return XCTFail("\(error)") }
        }
        // An expired sign-in elsewhere outranks a missing one, so starting a window can renew it.
        XCTAssertThrowsError(try ClaudeSignInLocation.firstSignIn(in: locations) {
            throw $0.directory == named ? ClaudeClientError.credentialMissing : ClaudeClientError.authenticationExpired
        }) { error in
            guard case ClaudeClientError.authenticationExpired = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(ClaudeSignInLocation.all(for: nil, primaryAliases: [alias]), [
            ClaudeSignInLocation(
                directory: AccountSource.primaryDirectory(for: .claude),
                keychainServices: ClaudeSignInLocation.primaryKeychainServices
            ),
            ClaudeSignInLocation(directory: alias, keychainServices: [ClaudeAccountProfile.keychainService(for: alias)]),
        ])
    }
}
