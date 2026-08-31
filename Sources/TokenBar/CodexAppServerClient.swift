import Foundation

struct CodexFetchResult {
    var quota: Result<ProviderSnapshot, Error>
    var activity: Result<TokenActivity, Error>
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
    func fetch() async throws -> CodexFetchResult {
        let candidates = CodexRuntimeLocator.live().candidates()
        guard !candidates.isEmpty else {
            throw CodexAppServerError.executableMissing
        }

        return try await Task.detached(priority: .utility) {
            var lastError: Error = CodexAppServerError.invalidResponse
            for candidate in candidates {
                do {
                    let responses = try runServer(executableURL: candidate.executableURL)
                    let result = CodexFetchResult(
                        quota: Result { try parseQuota(responses[2]) },
                        activity: Result { try parseActivity(responses[3]) }
                    )
                    if result.hasUsableResponse {
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

private func runServer(executableURL: URL) throws -> [Int: [String: Any]] {
    let process = Process()
    let input = Pipe()
    let output = Pipe()

    process.executableURL = executableURL
    process.arguments = ["app-server", "--stdio"]
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
                "version": "0.1.0",
            ],
        ],
    ], to: input.fileHandleForWriting)
    try readResponses(
        wantedIDs: [1],
        from: output.fileHandleForReading,
        buffer: &readBuffer,
        responses: &responses
    )

    try send(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
    try send(["method": "account/rateLimits/read", "id": 2], to: input.fileHandleForWriting)
    try send(["method": "account/usage/read", "id": 3], to: input.fileHandleForWriting)
    do {
        try readResponses(
            wantedIDs: [2, 3],
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
    responses: inout [Int: [String: Any]]
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
        // `read(upToCount:)` can wait for the full requested size on a live pipe.
        // `availableData` wakes as soon as app-server emits a single JSONL response.
        let chunk = handle.availableData
        guard !chunk.isEmpty else {
            throw CodexAppServerError.timedOut
        }
        buffer.append(chunk)
    }
}

private func parseQuota(_ response: [String: Any]?) throws -> ProviderSnapshot {
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
        return parseLimitWindow(rawWindow, limitID: limitID)
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
