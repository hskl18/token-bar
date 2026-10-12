import Foundation
import Darwin

struct CodexAccountProfile: Sendable {
    let id: String
    let name: String
    let configDirectory: URL

    static func discover(in directories: [URL]) -> [CodexAccountProfile] {
        let titles = AccountSource.titles(for: [AccountSource.primaryDirectory(for: .codex)] + directories)
        return directories.filter(AccountSource.isAllowedDirectory).map { directory in
            CodexAccountProfile(
                id: directory.path,
                name: titles[directory.path] ?? AccountSource.title(for: directory),
                configDirectory: directory
            )
        }
    }
}

struct CodexFetchResult {
    var quota: Result<ProviderSnapshot, Error>
    var activity: Result<TokenActivity, Error>
    var accountID: String? = nil
}

final class CodexQuotaReadings: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: Set<String> = []
    private var responses: [String: [String: Any]] = [:]

    func response(for accountID: String, fetch: () throws -> [String: Any]) throws -> [String: Any] {
        condition.lock()
        while pending.contains(accountID) { condition.wait() }
        if let response = responses[accountID] {
            condition.unlock()
            return response
        }
        pending.insert(accountID)
        condition.unlock()

        let result = Result(catching: fetch)
        condition.lock()
        if case let .success(response) = result,
           (try? parseCodexQuota(response)) != nil {
            responses[accountID] = response
        }
        pending.remove(accountID)
        condition.broadcast()
        condition.unlock()
        return try result.get()
    }
}

enum CodexAppServerError: LocalizedError {
    case executableMissing
    case launchFailed(String)
    case timedOut
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            "No Codex CLI or Codex desktop runtime was found."
        case let .launchFailed(message):
            "Codex app-server could not start: \(message)"
        case .timedOut:
            "Codex app-server did not respond within 10 seconds."
        case .invalidResponse:
            "Codex app-server returned an unreadable response."
        case let .server(message):
            message
        }
    }
}

struct CodexAppServerClient {
    func fetch(
        codexHome: URL? = nil, includeActivity: Bool = true, readings: CodexQuotaReadings? = nil
    ) async throws -> CodexFetchResult {
        let candidates = CodexRuntimeLocator.live().candidates()
        guard !candidates.isEmpty else {
            throw CodexAppServerError.executableMissing
        }

        return try await Task.detached(priority: .utility) {
            var lastError: Error = CodexAppServerError.invalidResponse
            for candidate in candidates {
                do {
                    let responses = try runServer(
                        executableURL: candidate.executableURL,
                        codexHome: codexHome,
                        includeActivity: includeActivity,
                        readings: readings
                    )
                    let result = CodexFetchResult(
                        quota: Result { try parseCodexQuota(responses[2]) },
                        activity: Result { try parseActivity(responses[3]) },
                        accountID: codexAccountID(from: responses[4])
                    )
                    // Auth failures apply to the profile, not the runtime.
                    let quotaError = dictionary(responses[2]?["error"])
                    if result.hasUsableResponse || (quotaError != nil && integer(quotaError?["code"]) != -32601) {
                        UserDefaults.standard.set(
                            candidate.executableURL.path,
                            forKey: StorageKeys.codexRuntimeExecutable
                        )
                        return result
                    }
                    lastError = result.preferredError ?? CodexAppServerError.invalidResponse
                } catch {
                    lastError = error
                }
            }

            UserDefaults.standard.removeObject(forKey: StorageKeys.codexRuntimeExecutable)
            throw lastError
        }.value
    }
}

private extension CodexFetchResult {
    var hasUsableResponse: Bool {
        if case .success = quota { return true }
        if case .success = activity { return true }
        return false
    }

    var preferredError: Error? {
        if case let .failure(error) = quota { return error }
        if case let .failure(error) = activity { return error }
        return nil
    }
}

private func runServer(
    executableURL: URL, codexHome: URL?, includeActivity: Bool, readings: CodexQuotaReadings?
) throws -> [Int: [String: Any]] {
    let process = Process()
    let input = Pipe()
    let output = Pipe()

    process.executableURL = executableURL
    process.arguments = [
        "-c", "analytics.enabled=false",
        "-c", "otel.exporter=\"none\"",
        "-c", "otel.trace_exporter=\"none\"",
        "-c", "otel.metrics_exporter=\"none\"",
        "app-server", "--stdio",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = (codexHome ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)).path
    // Keep inherited credentials from overriding this profile.
    for key in ["CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_SQLITE_HOME",
                "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE"] {
        environment.removeValue(forKey: key)
    }
    process.environment = environment
    process.currentDirectoryURL = URL(fileURLWithPath: environment["CODEX_HOME"]!, isDirectory: true)
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        throw CodexAppServerError.launchFailed(error.localizedDescription)
    }

    let timeout = DispatchWorkItem {
        if process.isRunning {
            process.terminate()
        }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
    var responses: [Int: [String: Any]] = [:]
    var readBuffer = Data()

    defer {
        timeout.cancel()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    try send([
        "method": "initialize",
        "id": 1,
        "params": [
            "clientInfo": [
                "name": "token_bar",
                "title": "Token Bar",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            ],
            "capabilities": ["experimentalApi": true],
        ],
    ], to: input.fileHandleForWriting)
    try readResponses(
        wantedIDs: [1],
        from: output.fileHandleForReading,
        buffer: &readBuffer,
        responses: &responses
    )

    try send(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
    try send(["method": "account/read", "id": 4, "params": ["refreshToken": false]], to: input.fileHandleForWriting)
    if readings != nil {
        // Identity is optional; a slow or older runtime must not delay quota until timeout.
        try? readResponses(
            wantedIDs: [4], from: output.fileHandleForReading,
            buffer: &readBuffer, responses: &responses,
            deadline: Date().addingTimeInterval(0.25)
        )
    }
    if includeActivity {
        try send(["method": "account/usage/read", "id": 3], to: input.fileHandleForWriting)
    }
    // Codex reports undecodable params as -32600; retry without the background-poll flag.
    func readRateLimits() throws -> [String: Any] {
        for params in [["excludeResetCreditDetails": true], nil] as [[String: Any]?] {
            var request: [String: Any] = ["method": "account/rateLimits/read", "id": 2]
            request["params"] = params
            responses[2] = nil
            try send(request, to: input.fileHandleForWriting)
            try readResponses(
                wantedIDs: [2], from: output.fileHandleForReading,
                buffer: &readBuffer, responses: &responses
            )
            guard integer(dictionary(responses[2]?["error"])?["code"]) == -32600 else { break }
        }
        guard let response = responses[2] else { throw CodexAppServerError.invalidResponse }
        return response
    }
    do {
        if let readings, let accountID = codexAccountID(from: responses[4]) {
            responses[2] = try readings.response(for: accountID, fetch: readRateLimits)
        } else {
            _ = try readRateLimits()
        }
        var wantedIDs: Set<Int> = includeActivity ? [2, 3] : [2]
        if readings == nil { wantedIDs.insert(4) }
        try readResponses(
            wantedIDs: wantedIDs,
            from: output.fileHandleForReading,
            buffer: &readBuffer,
            responses: &responses
        )
    } catch {
        guard responses[2] != nil || responses[3] != nil else { throw error }
    }

    return responses
}

private func send(_ message: [String: Any], to handle: FileHandle) throws {
    let data = try JSONSerialization.data(withJSONObject: message)
    try handle.write(contentsOf: data)
    try handle.write(contentsOf: Data([0x0A]))
}

private func readResponses(
    wantedIDs: Set<Int>,
    from handle: FileHandle,
    buffer: inout Data,
    responses: inout [Int: [String: Any]],
    deadline: Date? = nil
) throws {
    while !wantedIDs.allSatisfy({ responses[$0] != nil }) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let dictionary = object as? [String: Any],
                let id = integer(dictionary["id"])
            else {
                continue
            }
            responses[id] = dictionary
        }
        if wantedIDs.allSatisfy({ responses[$0] != nil }) {
            return
        }
        if let deadline {
            let remaining = deadline.timeIntervalSinceNow
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard remaining > 0,
                  poll(&descriptor, 1, Int32(min(remaining * 1_000, Double(Int32.max)))) > 0
            else { throw CodexAppServerError.timedOut }
        }
        // availableData returns short pipe reads without waiting for a fixed buffer size.
        let chunk = handle.availableData
        guard !chunk.isEmpty else {
            throw CodexAppServerError.timedOut
        }
        buffer.append(chunk)
    }
}

private func codexAccountID(from response: [String: Any]?) -> String? {
    let accountID = (try? resultDictionary(response))
        .flatMap { dictionary($0["workspaceRouting"]) }
        .flatMap { string($0["chatgptAccountId"]) }
    return accountID?.isEmpty == false ? accountID : nil
}

func parseCodexQuota(_ response: [String: Any]?) throws -> ProviderSnapshot {
    let result = try resultDictionary(response)
    let legacyLimits = dictionary(result["rateLimits"])
    let rawBuckets = dictionary(result["rateLimitsByLimitId"])

    var parsedBuckets: [(id: String, raw: [String: Any], windows: [LimitWindow])] = []
    if let rawBuckets, !rawBuckets.isEmpty {
        for id in rawBuckets.keys.sorted() {
            guard let raw = dictionary(rawBuckets[id]) else { continue }
            let limitID = string(raw["limitId"]) ?? id
            parsedBuckets.append((limitID, raw, parseLimitWindows(raw, limitID: limitID)))
        }
    } else if let legacyLimits {
        let limitID = string(legacyLimits["limitId"]) ?? "codex"
        parsedBuckets.append((limitID, legacyLimits, parseLimitWindows(legacyLimits, limitID: limitID)))
    }

    guard !parsedBuckets.isEmpty else {
        throw CodexAppServerError.server("Codex did not return ChatGPT rate-limit data.")
    }

    let legacyID = legacyLimits.flatMap { string($0["limitId"]) }
    guard let preferred = parsedBuckets.first(where: { $0.id == "codex" && !$0.windows.isEmpty })
        ?? parsedBuckets.first(where: { $0.id == legacyID && !$0.windows.isEmpty })
        ?? parsedBuckets.first(where: { !$0.windows.isEmpty })
    else {
        throw CodexAppServerError.server("Codex rate limits were present but contained no usage windows.")
    }

    let windows = preferred.windows.sorted {
        ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0)
    }
    var extraWindows = windows.count > 2 ? Array(windows.dropFirst().dropLast()) : []
    for bucket in parsedBuckets where bucket.id != preferred.id {
        extraWindows.append(contentsOf: bucket.windows)
    }
    extraWindows.sort {
        if $0.usedPercent != $1.usedPercent {
            return $0.usedPercent > $1.usedPercent
        }
        return $0.id < $1.id
    }

    return ProviderSnapshot(
        connected: true,
        plan: string(preferred.raw["planType"]) ?? string(result["planType"]),
        shortWindow: windows.count > 1 ? windows.first : nil,
        longWindow: windows.last,
        extraWindows: extraWindows,
        error: nil
    )
}

private func parseActivity(_ response: [String: Any]?) throws -> TokenActivity {
    let result = try resultDictionary(response)
    let summary = dictionary(result["summary"])
    let lifetime = int64(summary?["lifetimeTokens"])
    let rawBuckets = result["dailyUsageBuckets"] as? [Any] ?? []
    let buckets = rawBuckets.compactMap { value -> DailyUsageBucket? in
        guard let item = dictionary(value),
              let date = string(item["startDate"]),
              let tokens = int64(item["tokens"])
        else {
            return nil
        }
        return DailyUsageBucket(startDate: date, tokens: max(0, tokens))
    }
    guard lifetime != nil || !buckets.isEmpty else {
        throw CodexAppServerError.server(
            "Codex account usage did not contain a recognized lifetime counter or daily bucket."
        )
    }
    return TokenActivity(lifetimeTokens: lifetime, daily: buckets)
}

private func resultDictionary(_ response: [String: Any]?) throws -> [String: Any] {
    guard let response else { throw CodexAppServerError.invalidResponse }
    if let error = dictionary(response["error"]) {
        let message = string(error["message"]) ?? "Codex app-server request failed."
        throw CodexAppServerError.server(message)
    }
    guard let result = dictionary(response["result"]) else {
        throw CodexAppServerError.invalidResponse
    }
    return result
}

private func parseLimitWindows(_ value: [String: Any], limitID: String) -> [LimitWindow] {
    ["primary", "secondary"].compactMap { key in
        guard let rawWindow = dictionary(value[key]) else { return nil }
        var window = parseLimitWindow(rawWindow, limitID: limitID)
        window?.limitName = string(value["limitName"])
        return window
    }
}

private func parseLimitWindow(_ value: [String: Any], limitID: String) -> LimitWindow? {
    guard let percent = double(value["usedPercent"]) else { return nil }
    let minutes = integer(value["windowDurationMins"])
    let resetDate = int64(value["resetsAt"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }

    let label: String
    if let minutes, minutes >= 24 * 60, minutes.isMultiple(of: 24 * 60) {
        label = "\(minutes / (24 * 60))-day window"
    } else if let minutes, minutes >= 60, minutes.isMultiple(of: 60) {
        label = "\(minutes / 60)-hour window"
    } else if let minutes {
        label = "\(minutes)-minute window"
    } else {
        label = "Usage window"
    }

    return LimitWindow(
        label: label,
        usedPercent: min(100, max(0, percent)),
        windowMinutes: minutes,
        resetsAt: resetDate,
        limitID: limitID
    )
}

private func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func string(_ value: Any?) -> String? {
    value as? String
}

private func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
}

private func int64(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    return nil
}

private func double(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    return nil
}
