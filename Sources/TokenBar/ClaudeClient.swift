import CryptoKit
import Darwin
import Foundation
import os

struct ClaudeAccountProfile: Hashable, Sendable {
    let id: String
    let name: String
    /// The folder whose credentials read this login's quota.
    let configDirectory: URL
    /// Other folders signed in to the same login; their sessions count toward it too.
    var aliases: [URL] = []

    /// The login's `accountUuid:organizationUuid`; nil when the folder's configuration names none.
    var accountID: String? { id == configDirectory.path ? nil : id }

    static var primaryAccountID: String? {
        accountID(in: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json"))
    }

    static func currentAccountID(for profile: ClaudeAccountProfile?) -> String? {
        guard let profile else { return primaryAccountID }
        return accountID(in: profile.configDirectory.appendingPathComponent(".claude.json"))
    }

    /// One profile per login, with later folders signed in to it as aliases;
    /// `primaryAliases` are the folders signed in to the primary folder's login.
    static func discover(
        in directories: [URL], primaryID: String?
    ) -> (profiles: [ClaudeAccountProfile], primaryAliases: [URL]) {
        let titles = AccountSource.titles(for: [AccountSource.primaryDirectory(for: .claude)] + directories)
        var profiles: [ClaudeAccountProfile] = []
        var primaryAliases: [URL] = []
        for directory in directories where AccountSource.isAllowedDirectory(directory) {
            let id = accountID(in: directory.appendingPathComponent(".claude.json")) ?? directory.path
            if id == primaryID {
                primaryAliases.append(directory)
            } else if let index = profiles.firstIndex(where: { $0.id == id }) {
                profiles[index].aliases.append(directory)
            } else {
                profiles.append(ClaudeAccountProfile(
                    id: id, name: titles[directory.path] ?? AccountSource.title(for: directory),
                    configDirectory: directory
                ))
            }
        }
        return (profiles, primaryAliases)
    }

    var keychainService: String { Self.keychainService(for: configDirectory) }

    static func keychainService(for directory: URL) -> String {
        let digest = SHA256.hash(data: Data(directory.path.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(suffix)"
    }

    static func accountID(in file: URL) -> String? {
        struct Configuration: Decodable {
            struct Identity: Decodable {
                let accountUuid: String
                let organizationUuid: String?
            }
            let oauthAccount: Identity?
        }
        guard AccountSource.isRegularFile(file),
              let data = try? Data(contentsOf: file),
              let account = (try? JSONDecoder().decode(Configuration.self, from: data))?.oauthAccount,
              !account.accountUuid.isEmpty
        else { return nil }
        return account.accountUuid + ":" + (account.organizationUuid ?? "")
    }
}

enum ClaudeClientError: LocalizedError {
    case credentialMissing
    case credentialUnreadable
    case requestFailed(String)
    case rateLimited(retryAfter: TimeInterval?)
    case authenticationExpired
    case accessDenied
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .credentialMissing:
            "Signed out."
        case .credentialUnreadable:
            "Keychain sign-in unreadable."
        case let .requestFailed(message):
            message
        case .rateLimited:
            "Rate limited."
        case .authenticationExpired:
            "Sign-in expired."
        case .accessDenied:
            "Access denied (HTTP 403)."
        case .invalidResponse:
            "Unreadable usage response."
        }
    }
}

struct ClaudeClient {
    // One session for every request, since a session is kept until it is invalidated; logins must not share cookies.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private static let cliVersion = Task.detached(priority: .utility) { () -> String? in
        guard let executable = claudeExecutable() else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer { stopProcess(process) }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard !process.isRunning, process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let version = text.split(whereSeparator: \.isWhitespace).first.map(String.init),
              version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
        else { return nil }
        return version
    }

    /// `primaryAliases` are the folders signed in to the primary folder's login, used when `profile` is nil.
    func fetch(profile: ClaudeAccountProfile? = nil, primaryAliases: [URL] = []) async throws -> ProviderSnapshot {
        let accountID = ClaudeAccountProfile.currentAccountID(for: profile)
        var snapshot = try parseSnapshot(data: try await fetchUsage(profile: profile, primaryAliases: primaryAliases).data)
        if accountID == ClaudeAccountProfile.currentAccountID(for: profile) {
            snapshot.resetAccountID = accountID
        } else {
            snapshot.weeklyResetCredits = nil
        }
        return snapshot
    }

    func consumeWeeklyReset(
        profile: ClaudeAccountProfile?, primaryAliases: [URL] = [], expectedAccountID: String
    ) async throws {
        func currentAccountID() -> String? {
            ClaudeAccountProfile.currentAccountID(for: profile)
        }
        guard currentAccountID() == expectedAccountID,
              let organization = expectedAccountID.split(separator: ":").last.map(String.init),
              UUID(uuidString: organization) != nil else {
            throw ClaudeClientError.requestFailed("The account in this folder changed. Refresh before using a reset.")
        }
        let usage = try await fetchUsage(profile: profile, primaryAliases: primaryAliases)
        guard currentAccountID() == expectedAccountID else {
            throw ClaudeClientError.requestFailed("The account changed while checking reset credits. Refresh and try again.")
        }
        let object = try JSONSerialization.jsonObject(with: usage.data) as? [String: Any]
        guard let grantID = parseClaudeWeeklyResetCredits(object?["cedar_ember"])?.grantID else {
            throw ClaudeClientError.requestFailed("This account has no available weekly reset credits.")
        }
        let response = try await request(
            path: "/api/organizations/\(organization)/reset_rate_limits", token: usage.token,
            body: ["program": "cedar_ember", "grant_id": grantID, "request_id": UUID().uuidString]
        )
        if response.http.statusCode == 429 {
            throw ClaudeClientError.rateLimited(retryAfter: retryAfterInterval(from: response.http))
        }
        guard (200..<300).contains(response.http.statusCode) else {
            throw ClaudeClientError.requestFailed("Claude reset request returned HTTP \(response.http.statusCode).")
        }
        let result = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        guard result?["result"] as? String == "reset" else {
            throw ClaudeClientError.requestFailed("Claude did not reset this account (\(result?["result"] as? String ?? "unknown response")).")
        }
    }

    private func fetchUsage(
        profile: ClaudeAccountProfile?, primaryAliases: [URL]
    ) async throws -> (data: Data, token: String) {
        let initialToken = try await Task.detached(priority: .utility) {
            try readClaudeKeychainCredential(profile: profile, primaryAliases: primaryAliases)
        }.value
        var currentToken = initialToken
        var response = try await requestUsage(token: initialToken)

        if response.http.statusCode == 401 || response.http.statusCode == 403 {
            // Claude Code may have renewed the sign-in since the first read, or ended it.
            try Task.checkCancellation()
            let token = try await Task.detached(priority: .utility) {
                try readClaudeKeychainCredential(profile: profile, primaryAliases: primaryAliases)
            }.value
            try Task.checkCancellation()
            if token != initialToken {
                currentToken = token
                response = try await requestUsage(token: token)
            }
        }

        if response.http.statusCode == 401 {
            throw ClaudeClientError.authenticationExpired
        }
        if response.http.statusCode == 403 {
            throw ClaudeClientError.accessDenied
        }
        if response.http.statusCode == 429 {
            throw ClaudeClientError.rateLimited(
                retryAfter: retryAfterInterval(from: response.http)
            )
        }
        guard (200..<300).contains(response.http.statusCode) else {
            throw ClaudeClientError.requestFailed(
                "Claude usage request returned HTTP \(response.http.statusCode)."
            )
        }

        return (response.data, currentToken)
    }

    private func requestUsage(token: String, includeResetCredits: Bool = true) async throws -> (data: Data, http: HTTPURLResponse) {
        let query = includeResetCredits ? "?cedar_ember=1" : ""
        let response = try await request(path: "/api/oauth/usage" + query, token: token)
        if includeResetCredits, [400, 404, 422].contains(response.http.statusCode) {
            return try await requestUsage(token: token, includeResetCredits: false)
        }
        return response
    }

    private func request(path: String, token: String, body: [String: String]? = nil) async throws -> (data: Data, http: HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
        request.httpMethod = body == nil ? "GET" : "POST"
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Reset grants depend on the CLI surface and version, unlike ordinary quota windows.
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("claude_code_cli", forHTTPHeaderField: "anthropic-client-platform")
        if let version = await Self.cliVersion.value {
            request.setValue("claude-cli/\(version) (external, cli)", forHTTPHeaderField: "User-Agent")
            request.setValue(version, forHTTPHeaderField: "anthropic-client-version")
        } else {
            request.setValue("TokenBar", forHTTPHeaderField: "User-Agent")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw ClaudeClientError.requestFailed("Claude usage request failed: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeClientError.invalidResponse
        }
        return (data, http)
    }

    func parseSnapshot(data: Data) throws -> ProviderSnapshot {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            throw ClaudeClientError.invalidResponse
        }

        var windows: [LimitWindow] = []
        if let session = parseClaudeWindow(root["five_hour"], label: "5-hour window", minutes: LimitWindow.sessionMinutes) {
            windows.append(session)
        }
        if let weekly = parseClaudeWindow(root["seven_day"], label: "All models", minutes: LimitWindow.weeklyMinutes) {
            windows.append(weekly)
        }
        for (key, raw) in root.sorted(by: { $0.key < $1.key }) where key.hasPrefix("seven_day_") {
            let name = key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ").capitalized
            if var window = parseClaudeWindow(raw, label: name, minutes: LimitWindow.weeklyMinutes) {
                window.limitID = "claude:\(key)"
                window.limitName = name
                windows.append(window)
            }
        }
        let utilization = root["utilization"] as? [String: Any]
        let limits = (root["limits"] ?? utilization?["limits"]) as? [[String: Any]] ?? []
        for row in limits {
            guard let kind = row["kind"] as? String,
                  ["session", "weekly_all", "weekly_scoped"].contains(kind) else { continue }
            let scope = row["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = model?["display_name"] as? String ?? kind
            let minutes = kind == "session" ? LimitWindow.sessionMinutes : LimitWindow.weeklyMinutes
            let label = kind == "session" ? "5-hour window" : kind == "weekly_all" ? "All models" : name
            guard var window = parseClaudeWindow(row, label: label, minutes: minutes) else { continue }
            if kind == "weekly_scoped" {
                window.limitID = "claude:\(row["group"] as? String ?? "models"):\(name)"
                window.limitName = name
                windows.removeAll { $0.limitName?.caseInsensitiveCompare(name) == .orderedSame }
            } else {
                windows.removeAll { $0.limitID == "claude" && $0.windowMinutes == minutes }
            }
            windows.append(window)
        }
        if let extra = root["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let used = extra["used_credits"] as? Double,
           let limit = extra["monthly_limit"] as? Double, limit > 0 {
            // The usage API gives a monthly cap no reset unless a spend row names one; claude.ai shows the next UTC month.
            let spendReset = limits.first {
                $0["kind"] as? String == "spend" && $0["group"] as? String == "monthly" && $0["is_active"] as? Bool != false
            }?["resets_at"] as? String
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = .gmt
            let monthReset = utc.dateInterval(of: .month, for: Date())?.end
            windows.append(LimitWindow(
                label: "Usage credits", usedPercent: min(100, max(0, used / limit * 100)),
                windowMinutes: nil, resetsAt: spendReset.flatMap(parseISO8601) ?? monthReset,
                limitID: "claude:extra_usage", limitName: "Usage credits"
            ))
        }

        guard !windows.isEmpty else {
            throw ClaudeClientError.invalidResponse
        }

        let credits = parseClaudeWeeklyResetCredits(root["cedar_ember"])
        return ProviderSnapshot(
            connected: true,
            shortWindow: windows.first { $0.limitID == "claude" && $0.windowMinutes == LimitWindow.sessionMinutes },
            longWindow: windows.first { $0.limitID == "claude" && $0.windowMinutes == LimitWindow.weeklyMinutes },
            extraWindows: windows.filter { $0.limitID != "claude" },
            error: nil,
            weeklyResetCredits: credits?.count,
            resetCreditExpiries: credits?.expiries,
            resetCreditsFetched: true
        )
    }
}

private func parseClaudeWeeklyResetCredits(
    _ raw: Any?, at now: Date = Date()
) -> (count: Int, grantID: String?, expiries: [Date?])? {
    guard let block = raw as? [String: Any], let eligible = block["eligible"] as? Bool else { return nil }
    guard eligible else { return block["ineligible_reason"] as? String == "no_grant" ? (0, nil, []) : nil }
    guard let grants = block["grants"] as? [[String: Any]] else { return nil }
    var count = 0
    var grantID: String?
    var expiries: [Date?] = []
    for grant in grants {
        guard let left = grant["resets_left"] as? Int, left >= 0,
              let clears = grant["clears"] as? [String] else { return nil }
        guard clears.contains("seven_day"), left > 0, grant["paused"] as? Bool != true,
              grant["gives_back_weekly"] as? Bool != true else { continue }
        if let rawStart = grant["starts_at"] as? String {
            guard let start = parseISO8601(rawStart) else { return nil }
            if start > now { continue }
        }
        var end: Date?
        if let rawEnd = grant["ends_at"] as? String {
            end = parseISO8601(rawEnd)
            guard let end else { return nil }
            if end <= now { continue }
        }
        guard let id = grant["id"] as? String, !id.isEmpty else { return nil }
        let sum = count.addingReportingOverflow(left)
        guard !sum.overflow else { return nil }
        count = sum.partialValue
        grantID = grantID ?? id
        expiries += Array(repeating: end, count: min(left, 100))
    }
    return (count, grantID, expiries)
}

actor ClaudeWindowStarter {
    static let shared = ClaudeWindowStarter()
    private let log = Logger(subsystem: "com.local.tokenbar", category: "claude-window")
    private var attempts: [String: (date: Date, error: String?)] = [:]

    // Returns false when the profile already attempted a start within 15 minutes.
    func start(profile: ClaudeAccountProfile?, primaryAliases: [URL] = []) async throws -> Bool {
        let key = profile?.configDirectory.path ?? AccountSource.primaryDirectory(for: .claude).path
        if let previous = attempts[key], Date().timeIntervalSince(previous.date) < 15 * 60 {
            if let error = previous.error { throw ClaudeClientError.requestFailed(error) }
            return false
        }
        let date = Date()
        attempts[key] = (date, nil)
        let error = await Task.detached(priority: .utility) {
            runClaudeToStartWindow(profile: profile, primaryAliases: primaryAliases)
        }.value
        attempts[key] = (date, error.map { "Claude 5-hour window start failed: \($0)" })
        if let error = attempts[key]?.error {
            log.error("\(key, privacy: .public): \(error, privacy: .public)")
            throw ClaudeClientError.requestFailed(error)
        }
        log.notice("\(key, privacy: .public): 5-hour window started")
        return true
    }
}

private func runClaudeToStartWindow(profile: ClaudeAccountProfile?, primaryAliases: [URL]) -> String? {
    guard let executable = claudeExecutable() else { return "Claude Code CLI not found." }
    // Run in a folder that holds the sign-in; an expired one is fine, since the CLI renews it.
    let primary = AccountSource.primaryDirectory(for: .claude)
    let directory = (try? readClaudeLoginCredential(
        profile: profile, primaryAliases: primaryAliases, allowExpired: true
    ))?.directory ?? profile?.configDirectory ?? primary
    let log = FileManager.default.temporaryDirectory
        .appendingPathComponent("tokenbar-claude-window-\(UUID().uuidString).log")
    guard FileManager.default.createFile(atPath: log.path, contents: nil),
          let output = try? FileHandle(forWritingTo: log) else { return "CLI output unavailable." }
    defer {
        try? output.close()
        try? FileManager.default.removeItem(at: log)
    }
    let process = Process()
    process.executableURL = executable
    // Customizations can add tens of thousands of prompt tokens; a transcript would enter local history.
    process.arguments = [
        "-p", "hi", "--model", "haiku", "--effort", "low",
        "--settings", #"{"alwaysThinkingEnabled":false}"#,
        "--safe-mode", "--strict-mcp-config", "--system-prompt", "Reply with one word.",
        "--no-session-persistence", "--max-turns", "1", "--tools", "",
    ]
    process.currentDirectoryURL = directory
    process.environment = claudeEnvironment(configDirectory: directory == primary ? nil : directory)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    guard (try? process.run()) != nil else { return "Claude Code CLI could not launch." }
    let deadline = Date().addingTimeInterval(60)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    let timedOut = process.isRunning
    stopProcess(process)
    if !timedOut, process.terminationReason == .exit, process.terminationStatus == 0 { return nil }
    let reason = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
        .split(whereSeparator: \.isNewline).last.map { String($0.prefix(160)) }
        ?? (timedOut ? "timed out" : "exit \(process.terminationStatus)")
    return reason
}

private func claudeExecutable() -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        .map { String($0) + "/claude" }
        + [home.appendingPathComponent(".local/bin/claude").path,
           "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    return paths.map { URL(fileURLWithPath: $0) }.first {
        !AccountSource.isExcluded($0) && FileManager.default.isExecutableFile(atPath: $0.path)
    }
}

private func claudeEnvironment(configDirectory: URL?) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["CLAUDE_CONFIG_DIR"] = configDirectory?.path
    // Keep inherited API and cloud credentials from replacing this profile's subscription login.
    for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
                "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
        environment.removeValue(forKey: key)
    }
    return environment
}

/// Ends a child that ignores SIGTERM with SIGKILL after one second, then reaps it.
func stopProcess(_ process: Process) {
    if process.isRunning { process.terminate() }
    let grace = Date().addingTimeInterval(1)
    while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

private func readClaudeKeychainCredential(profile: ClaudeAccountProfile?, primaryAliases: [URL]) throws -> String {
    try readClaudeLoginCredential(profile: profile, primaryAliases: primaryAliases).token
}

/// One folder's sign-in: its `.credentials.json` and the Keychain items Claude Code keeps for it.
struct ClaudeSignInLocation: Equatable {
    /// The items Claude Code has used for the primary folder, newest name first.
    static let primaryKeychainServices = [
        "Claude Code-credentials", "claude-credentials", "Claude-credentials", "claudecode-credentials",
    ]

    let directory: URL
    let keychainServices: [String]

    /// Every folder signed in to a login, the folder it is named after first;
    /// for the primary login (`profile` nil) that is `~/.claude`, then `primaryAliases`.
    static func all(for profile: ClaudeAccountProfile?, primaryAliases: [URL]) -> [ClaudeSignInLocation] {
        let primary = profile == nil ? [ClaudeSignInLocation(
            directory: AccountSource.primaryDirectory(for: .claude), keychainServices: primaryKeychainServices
        )] : []
        let folders = profile.map { [$0.configDirectory] + $0.aliases } ?? primaryAliases
        return primary + folders.map {
            ClaudeSignInLocation(directory: $0, keychainServices: [ClaudeAccountProfile.keychainService(for: $0)])
        }
    }

    /// The first location `read` gets a token from: the folder a login is named after can be signed out, for
    /// example after a rename, while another folder of the same login is signed in.
    /// Without a sign-in anywhere, the error is an expired sign-in's, which starting a window renews, else the first
    /// location's.
    static func firstSignIn(
        in locations: [ClaudeSignInLocation], read: (ClaudeSignInLocation) throws -> String
    ) throws -> (token: String, location: ClaudeSignInLocation) {
        var errors: [Error] = []
        for location in locations {
            do { return (try read(location), location) } catch { errors.append(error) }
        }
        let expired = errors.first {
            if case ClaudeClientError.authenticationExpired = $0 { return true }
            return false
        }
        throw expired ?? errors.first ?? ClaudeClientError.credentialMissing
    }
}

private func readClaudeLoginCredential(
    profile: ClaudeAccountProfile?, primaryAliases: [URL], allowExpired: Bool = false
) throws -> (token: String, directory: URL) {
    let locations = ClaudeSignInLocation.all(for: profile, primaryAliases: primaryAliases)
    let expected = profile?.id ?? ClaudeAccountProfile.primaryAccountID
    let found = try ClaudeSignInLocation.firstSignIn(in: locations) { location in
        // An alias may have signed in to another login since discovery; its sign-in must not stand in for this one.
        if location.directory != locations.first?.directory,
           ClaudeAccountProfile.accountID(in: location.directory.appendingPathComponent(".claude.json")) != expected {
            throw ClaudeClientError.credentialMissing
        }
        return try readClaudeCredential(names: location.keychainServices, directory: location.directory, allowExpired: allowExpired)
    }
    return (found.token, found.location.directory)
}

private func readClaudeCredential(names credentialNames: [String], directory: URL, allowExpired: Bool) throws -> String {
    let username = NSUserName()
    var foundUnreadableCredential = false

    for name in credentialNames {
        let secret = runSecurity([
            "find-generic-password", "-a", username, "-s", name, "-w",
        ])
        guard secret.status == 0, !secret.output.isEmpty else {
            // The security CLI returns 44 for errSecItemNotFound (-25300).
            if secret.status != 44 { foundUnreadableCredential = true }
            continue
        }

        guard let token = try oauthToken(in: secret.output, allowExpired: allowExpired) else {
            // Claude Code empties the tokens but keeps the item when a sign-in ends; that is signed out.
            if (try? JSONSerialization.jsonObject(with: secret.output)) == nil { foundUnreadableCredential = true }
            continue
        }
        return token
    }

    let fallback = directory.appendingPathComponent(".credentials.json")
    if let values = try? fallback.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
       values.isRegularFile == true, values.isSymbolicLink != true {
        guard let data = try? Data(contentsOf: fallback),
              let token = try oauthToken(in: data, allowExpired: allowExpired) else {
            throw ClaudeClientError.credentialUnreadable
        }
        return token
    }

    if foundUnreadableCredential {
        throw ClaudeClientError.credentialUnreadable
    }
    throw ClaudeClientError.credentialMissing
}

private func oauthToken(in data: Data, allowExpired: Bool = false) throws -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let root = object as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String, !token.isEmpty
    else { return nil }
    // An expired token only earns a 401, and repeated 401s draw 429s; Claude Code renews it when it runs.
    if !allowExpired, let expiresAt = oauth["expiresAt"] as? Double, expiresAt / 1000 <= Date().timeIntervalSince1970 {
        throw ClaudeClientError.authenticationExpired
    }
    return token
}

private func runSecurity(_ arguments: [String]) -> (status: Int32, output: Data) {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = errors

    guard (try? process.run()) != nil else { return (-1, Data()) }
    // An unanswered Keychain prompt would otherwise hold the refresh forever; a minute leaves time to answer it.
    let timeout = DispatchWorkItem { stopProcess(process) }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: timeout)
    defer { timeout.cancel() }
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, outputData + errorData)
}

private func parseClaudeWindow(_ raw: Any?, label: String, minutes: Int) -> LimitWindow? {
    guard let value = raw as? [String: Any] else { return nil }
    let percent: Double?
    if let number = (value["utilization"] ?? value["percent"]) as? NSNumber {
        percent = number.doubleValue
    } else {
        percent = value["utilization"] as? Double
    }
    guard let percent, percent.isFinite else { return nil }

    let resetDate = (value["resets_at"] as? String).flatMap(parseISO8601)
    return LimitWindow(
        label: label,
        usedPercent: min(100, max(0, percent)),
        windowMinutes: minutes,
        resetsAt: resetDate,
        limitID: "claude"
    )
}

private func retryAfterInterval(from response: HTTPURLResponse) -> TimeInterval? {
    guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty
    else {
        return nil
    }

    if let seconds = TimeInterval(raw), seconds > 0 {
        return seconds
    }

    let formats = [
        "EEE',' dd MMM yyyy HH':'mm':'ss z",
        "EEEE',' dd-MMM-yy HH':'mm':'ss z",
        "EEE MMM d HH':'mm':'ss yyyy",
    ]
    for format in formats {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        if let date = formatter.date(from: raw) {
            let interval = date.timeIntervalSinceNow
            return interval > 0 ? interval : nil
        }
    }
    return nil
}

private func parseISO8601(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
        return date
    }
    return ISO8601DateFormatter().date(from: value)
}
