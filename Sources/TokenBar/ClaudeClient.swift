import Foundation

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
            "Claude Code OAuth credentials were not found. Sign in with Claude Code, then refresh."
        case .credentialUnreadable:
            "Claude Code credentials could not be read from Keychain."
        case let .requestFailed(message):
            message
        case .rateLimited:
            "Claude usage is temporarily rate limited."
        case .authenticationExpired:
            "Claude OAuth token expired. Open Claude Code, then refresh Token Bar. If it persists, sign in again."
        case .accessDenied:
            "Claude denied access to usage data. Refresh again; if it persists, reauthenticate Claude Code."
        case .invalidResponse:
            "Claude returned usage data in an unsupported format."
        }
    }
}

struct ClaudeClient {
    func fetch() async throws -> ProviderSnapshot {
        let initialToken = try await Task.detached(priority: .utility) {
            try readClaudeToken(allowEnvironment: true)
        }.value
        var response = try await requestUsage(token: initialToken)

        if response.http.statusCode == 401 || response.http.statusCode == 403 {
            try await Task.sleep(for: .milliseconds(250))
            let keychainToken = await Task.detached(priority: .utility) {
                try? readClaudeToken(allowEnvironment: false)
            }.value ?? initialToken
            response = try await requestUsage(token: keychainToken)
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

    private func parseSnapshot(data: Data) throws -> ProviderSnapshot {
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

        guard !windows.isEmpty else {
            throw ClaudeClientError.invalidResponse
        }

        return ProviderSnapshot(
            connected: true,
            plan: "Claude Code",
            shortWindow: windows.first { $0.windowMinutes == 5 * 60 },
            longWindow: windows.first { $0.windowMinutes == 7 * 24 * 60 },
            extraWindows: [],
            error: nil
        )
    }
}

private func readClaudeToken(allowEnvironment: Bool) throws -> String {
    if allowEnvironment,
       let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !token.isEmpty {
        return token
    }

    return try readClaudeKeychainCredential()
}

private func readClaudeKeychainCredential() throws -> String {
    let username = NSUserName()
    let credentialNames = [
        "Claude Code-credentials",
        "claude-credentials",
        "Claude-credentials",
        "claudecode-credentials",
    ]
    var foundUnreadableCredential = false

    for name in credentialNames {
        let metadata = runSecurity([
            "find-generic-password", "-a", username, "-s", name,
        ])
        guard metadata.status == 0 else { continue }

        let secret = runSecurity([
            "find-generic-password", "-a", username, "-s", name, "-w",
        ])
        guard secret.status == 0, !secret.output.isEmpty else {
            foundUnreadableCredential = true
            continue
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: secret.output),
            let root = object as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            foundUnreadableCredential = true
            continue
        }
        return token
    }

    if foundUnreadableCredential {
        throw ClaudeClientError.credentialUnreadable
    }
    throw ClaudeClientError.credentialMissing
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
    if let number = value["utilization"] as? NSNumber {
        percent = number.doubleValue
    } else {
        percent = value["utilization"] as? Double
    }
    guard let percent else { return nil }

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
