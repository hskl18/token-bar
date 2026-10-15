import CryptoKit
import Darwin
import Foundation
import os

struct ClaudeAccountProfile: Hashable, Sendable {
    let id: String
    let name: String
    let configDirectory: URL

    static var primaryAccountID: String? {
        accountID(in: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json"))
    }

    static func discover(in directories: [URL], primaryID: String?) -> [ClaudeAccountProfile] {
        let titles = AccountSource.titles(for: [AccountSource.primaryDirectory(for: .claude)] + directories)
        var seen = Set<String>()
        return directories.compactMap { directory in
            guard AccountSource.isAllowedDirectory(directory) else { return nil }
            let id = accountID(in: directory.appendingPathComponent(".claude.json")) ?? directory.path
            guard id != primaryID, seen.insert(id).inserted else { return nil }
            return ClaudeAccountProfile(
                id: id, name: titles[directory.path] ?? AccountSource.title(for: directory),
                configDirectory: directory
            )
        }
    }

    var keychainService: String {
        let digest = SHA256.hash(data: Data(configDirectory.path.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(suffix)"
    }

    private static func accountID(in file: URL) -> String? {
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
            "Sign in with Claude Code, then refresh."
        case .credentialUnreadable:
            "Claude credentials unavailable."
        case let .requestFailed(message):
            message
        case .rateLimited:
            "Claude rate limited. Try later."
        case .authenticationExpired:
            "Claude sign-in expired. Open Claude Code, then refresh."
        case .accessDenied:
            "Claude access denied. Sign in again."
        case .invalidResponse:
            "Claude returned usage data in an unsupported format."
        }
    }
}

struct ClaudeClient {
    func fetch(profile: ClaudeAccountProfile? = nil) async throws -> ProviderSnapshot {
        let initialToken = try await Task.detached(priority: .utility) {
            try readClaudeKeychainCredential(profile: profile)
        }.value
        var response = try await requestUsage(token: initialToken)

        if response.http.statusCode == 401 || response.http.statusCode == 403 {
            try Task.checkCancellation()
            var token = await Task.detached(priority: .utility) {
                try? readClaudeKeychainCredential(profile: profile)
            }.value ?? initialToken
            if response.http.statusCode == 401, token == initialToken {
                token = await ClaudeCLIRecovery.shared.refresh(profile: profile, token: initialToken) ?? token
            }
            try Task.checkCancellation()
            if token != initialToken { response = try await requestUsage(token: token) }
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

        return try parseSnapshot(data: response.data)
    }

    private func requestUsage(token: String) async throws -> (data: Data, http: HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/1.0.0", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
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
        if let session = parseClaudeWindow(root["five_hour"], label: "5-hour window", minutes: 5 * 60) {
            windows.append(session)
        }
        if let weekly = parseClaudeWindow(root["seven_day"], label: "All models", minutes: 7 * 24 * 60) {
            windows.append(weekly)
        }
        for (key, raw) in root.sorted(by: { $0.key < $1.key }) where key.hasPrefix("seven_day_") {
            let name = key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ").capitalized
            if var window = parseClaudeWindow(raw, label: name, minutes: 7 * 24 * 60) {
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
            let minutes = kind == "session" ? 300 : 10080
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

        return ProviderSnapshot(
            connected: true,
            plan: "Claude Code",
            shortWindow: windows.first { $0.limitID == "claude" && $0.windowMinutes == 5 * 60 },
            longWindow: windows.first { $0.limitID == "claude" && $0.windowMinutes == 7 * 24 * 60 },
            extraWindows: windows.filter { $0.limitID != "claude" },
            error: nil
        )
    }
}

private actor ClaudeCLIRecovery {
    static let shared = ClaudeCLIRecovery()
    private var lastAttempts: [String: Date] = [:]

    func refresh(profile: ClaudeAccountProfile?, token: String) async -> String? {
        let key = profile?.configDirectory.path ?? AccountSource.primaryDirectory(for: .claude).path
        if let previous = lastAttempts[key], Date().timeIntervalSince(previous) < 5 * 60 { return nil }
        lastAttempts[key] = Date()
        let task = Task.detached(priority: .utility) {
            runClaudeToRefresh(profile: profile, token: token)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

actor ClaudeWindowStarter {
    static let shared = ClaudeWindowStarter()
    private let log = Logger(subsystem: "com.local.tokenbar", category: "claude-window")
    private var attempts: [String: (date: Date, error: String?)] = [:]

    // Returns false when the profile already attempted a start within 15 minutes.
    func start(profile: ClaudeAccountProfile?) async throws -> Bool {
        let key = profile?.configDirectory.path ?? AccountSource.primaryDirectory(for: .claude).path
        if let previous = attempts[key], Date().timeIntervalSince(previous.date) < 15 * 60 {
            if let error = previous.error { throw ClaudeClientError.requestFailed(error) }
            return false
        }
        let date = Date()
        attempts[key] = (date, nil)
        let error = await Task.detached(priority: .utility) { runClaudeToStartWindow(profile: profile) }.value
        attempts[key] = (date, error.map { "Claude 5-hour window start failed: \($0)" })
        if let error = attempts[key]?.error {
            log.error("\(key, privacy: .public): \(error, privacy: .public)")
            throw ClaudeClientError.requestFailed(error)
        }
        log.notice("\(key, privacy: .public): 5-hour window started")
        return true
    }
}

private func runClaudeToStartWindow(profile: ClaudeAccountProfile?) -> String? {
    guard let executable = claudeExecutable() else { return "Claude Code CLI not found." }
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
    process.currentDirectoryURL = profile?.configDirectory ?? AccountSource.primaryDirectory(for: .claude)
    process.environment = claudeEnvironment(profile: profile)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    guard (try? process.run()) != nil else { return "Claude Code CLI could not launch." }
    let deadline = Date().addingTimeInterval(60)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    let timedOut = process.isRunning
    stopClaudeProcess(process)
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

private func claudeEnvironment(profile: ClaudeAccountProfile?) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["CLAUDE_CONFIG_DIR"] = profile?.configDirectory.path
    // Keep inherited API and cloud credentials from replacing this profile's subscription login.
    for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
                "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
        environment.removeValue(forKey: key)
    }
    return environment
}

private func stopClaudeProcess(_ process: Process) {
    if process.isRunning { process.terminate() }
    let grace = Date().addingTimeInterval(1)
    while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

private func runClaudeToRefresh(profile: ClaudeAccountProfile?, token: String) -> String? {
    guard let executable = claudeExecutable(), !Task.isCancelled else { return nil }

    var master: Int32 = -1
    var slave: Int32 = -1
    var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }
    defer { close(master) }
    let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
    defer { try? terminal.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--safe-mode"]
    process.currentDirectoryURL = profile?.configDirectory ?? AccountSource.primaryDirectory(for: .claude)
    process.environment = claudeEnvironment(profile: profile)
    process.standardInput = terminal
    process.standardOutput = terminal
    process.standardError = terminal
    guard (try? process.run()) != nil else { return nil }
    defer { stopClaudeProcess(process) }

    // Claude startup needs a TTY to renew OAuth without a model prompt.
    let deadline = Date().addingTimeInterval(15)
    var nextRead = Date()
    var bytes = [UInt8](repeating: 0, count: 8_192)
    while process.isRunning, Date() < deadline, !Task.isCancelled {
        if Date() >= nextRead {
            if let refreshed = try? readClaudeKeychainCredential(profile: profile), refreshed != token {
                return refreshed
            }
            nextRead = Date().addingTimeInterval(1)
        }
        var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 250) > 0 {
            let count = bytes.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            if count <= 0 { break }
        }
    }
    if !Task.isCancelled,
       let refreshed = try? readClaudeKeychainCredential(profile: profile), refreshed != token {
        return refreshed
    }
    return nil
}

private func readClaudeKeychainCredential(profile: ClaudeAccountProfile?) throws -> String {
    let username = NSUserName()
    let credentialNames = profile.map { [$0.keychainService] } ?? [
        "Claude Code-credentials",
        "claude-credentials",
        "Claude-credentials",
        "claudecode-credentials",
    ]
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

        guard let token = oauthToken(in: secret.output) else {
            foundUnreadableCredential = true
            continue
        }
        return token
    }

    let directory = profile?.configDirectory
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    let fallback = directory.appendingPathComponent(".credentials.json")
    if let values = try? fallback.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
       values.isRegularFile == true, values.isSymbolicLink != true {
        guard let data = try? Data(contentsOf: fallback),
              let token = oauthToken(in: data) else {
            throw ClaudeClientError.credentialUnreadable
        }
        return token
    }

    if foundUnreadableCredential {
        throw ClaudeClientError.credentialUnreadable
    }
    throw ClaudeClientError.credentialMissing
}

private func oauthToken(in data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let root = object as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String, !token.isEmpty
    else { return nil }
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
