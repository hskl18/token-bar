import Foundation

struct ClaudeMixSampler {
    private let readChunkBytes = 1024 * 1024
    var configDirectories = [AccountSource.primaryDirectory(for: .claude)]

    func update() async -> ClaudeUsageLedger {
        let scan = Task.detached(priority: .utility) { updateSynchronously() }
        return await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
    }

    private func updateSynchronously() -> ClaudeUsageLedger {
        var ledger = loadLedger()
        let original = ledger
        let files = sessionFiles()
        let activePaths = Set(files.map { $0.0.path })
        ledger.cursors = ledger.cursors.filter { activePaths.contains($0.key) }
        for (url, size) in files where size < (ledger.cursors[url.path] ?? 0) {
            ledger.cursors.removeValue(forKey: url.path)
        }
        let calendar = Calendar.current
        let cutoff = min(
            ActivityPeriod.year.interval(calendar: calendar).start,
            ActivityPeriod.week.interval(calendar: calendar).start
        )
        let cutoffDay = Self.dayFormatter.string(from: cutoff)
        let settled = Set((ledger.settledHashesByDay ?? [:]).values.joined())

        for (url, size) in files {
            if Task.isCancelled { return ledger }
            let path = url.path
            let start = ledger.cursors[path] ?? 0
            if size == start {
                continue
            }

            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            do {
                try handle.seek(toOffset: start)
                var cursor = start
                var pending = Data()

                while cursor < size {
                    if Task.isCancelled { try? handle.close(); return ledger }
                    var reachedEnd = false
                    try autoreleasepool {
                        let remaining = min(UInt64(readChunkBytes), size - cursor)
                        let data = try handle.read(upToCount: Int(remaining)) ?? Data()
                        guard !data.isEmpty else {
                            reachedEnd = true
                            return
                        }
                        pending.append(data)
                        cursor += UInt64(data.count)

                        if let lastNewline = pending.lastIndex(of: 0x0A) {
                            let upper = pending.distance(from: pending.startIndex, to: pending.index(after: lastNewline))
                            parseLines(
                                pending.subdata(in: 0..<upper),
                                ledger: &ledger,
                                settled: settled,
                                cutoffDay: cutoffDay
                            )
                            pending = pending.subdata(in: upper..<pending.count)
                            ledger.cursors[path] = cursor - UInt64(pending.count)
                        }
                    }
                    if reachedEnd { break }
                }
                try handle.close()
            } catch {
                try? handle.close()
            }
        }

        // Streamed copies of a message arrive within minutes, so only today's and yesterday's keep counts.
        let settleDay = Self.dayFormatter.string(from: Date().addingTimeInterval(-24 * 60 * 60))
        var settledByDay = ledger.settledHashesByDay ?? [:]
        for (hash, message) in ledger.messageUsage where message.day < settleDay {
            settledByDay[message.day, default: []].insert(hash)
        }
        ledger.byDayAndModel = ledger.byDayAndModel.filter { $0.key >= cutoffDay }
        ledger.messageUsage = ledger.messageUsage.filter { $0.value.day >= settleDay }
        ledger.settledHashesByDay = settledByDay.filter { $0.key >= cutoffDay }
        if ledger != original { save(ledger) }
        return ledger
    }

    private func sessionFiles() -> [(URL, UInt64)] {
        // A linked `projects` folder is read once, at its real path; the listing skips links themselves.
        TranscriptFile.list(in: Set(configDirectories.map { $0.appendingPathComponent("projects").resolvingSymlinksInPath().path })
            .map { URL(fileURLWithPath: $0, isDirectory: true) }).map { ($0.url, $0.size) }
    }

    private func parseLines(
        _ data: Data,
        ledger: inout ClaudeUsageLedger,
        settled: Set<UInt64>,
        cutoffDay: String
    ) {
        for line in data.split(separator: 0x0A) {
            guard isRelevantPrefix(line.prefix(1024)),
                  let record = autoreleasepool(invoking: { usageRecord(from: line) })
            else { continue }
            let day = Self.dayFormatter.string(from: record.date)
            guard day >= cutoffDay else { continue }

            let hash = record.dedupeID.map(stableHash)
            if let hash, settled.contains(hash) { continue }
            var message = hash.flatMap { ledger.messageUsage[$0] }
                ?? ClaudeMessageUsage(day: day, byModel: [:])
            var models = ledger.byDayAndModel[message.day] ?? [:]
            record.accumulate(into: &models, previous: &message.byModel)
            ledger.byDayAndModel[message.day] = models
            if let hash { ledger.messageUsage[hash] = message }
        }
    }

    func usageRecord(from line: Data.SubSequence) -> ClaudeUsageRecord? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              root["type"] as? String == "assistant",
              let timestamp = root["timestamp"] as? String,
              let date = Self.parseDate(timestamp),
              let message = root["message"] as? [String: Any],
              let model = message["model"] as? String,
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let iterations = usage["iterations"] as? [[String: Any]]
        let entries = (iterations ?? []).isEmpty ? [usage] : (iterations ?? [])
        var byModel: [String: TokenBreakdown] = [:]
        for entry in entries {
            let creation = entry["cache_creation"] as? [String: Any]
            let breakdown = TokenBreakdown(
                input: numericValue(entry["input_tokens"]) ?? 0,
                cacheCreationInput: numericValue(entry["cache_creation_input_tokens"]) ?? 0,
                cacheCreationInput5m: numericValue(creation?["ephemeral_5m_input_tokens"]),
                cacheCreationInput1h: numericValue(creation?["ephemeral_1h_input_tokens"]),
                cachedInput: numericValue(entry["cache_read_input_tokens"]) ?? 0,
                output: numericValue(entry["output_tokens"]) ?? 0
            )
            let key = UsagePriceKey.make(
                model: entry["model"] as? String ?? model,
                speed: entry["speed"] as? String ?? usage["speed"] as? String
            )
            var total = byModel[key] ?? TokenBreakdown()
            total.add(breakdown)
            byModel[key] = total
        }
        guard byModel.values.contains(where: { $0.total > 0 }) else { return nil }
        return ClaudeUsageRecord(
            date: date,
            model: model,
            dedupeID: dedupeID(
                messageID: message["id"] as? String ?? root["uuid"] as? String,
                requestID: root["requestId"] as? String ?? root["request_id"] as? String
            ),
            byModel: byModel,
            sessionID: root["sessionId"] as? String
        )
    }

    func isRelevantPrefix(_ prefix: Data.SubSequence) -> Bool {
        prefix.range(of: Self.assistantMarker) != nil || prefix.range(of: Self.assistantRoleMarker) != nil
    }

    private func dedupeID(messageID: String?, requestID: String?) -> String? {
        guard messageID != nil || requestID != nil else { return nil }
        return "claude:\(messageID ?? ""):\(requestID ?? "")"
    }

    private func numericValue(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private func loadLedger() -> ClaudeUsageLedger {
        TranscriptCache.load(ClaudeUsageLedger.self, key: StorageKeys.claudeLedger) ?? .empty
    }

    private func save(_ ledger: ClaudeUsageLedger) {
        TranscriptCache.save(ledger, key: StorageKeys.claudeLedger)
    }

    private static func parseDate(_ value: String) -> Date? {
        fractionalDateFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)
    private static let assistantRoleMarker = Data(#""role":"assistant""#.utf8)

}

struct ClaudeUsageRecord {
    var date: Date
    var model: String
    var dedupeID: String?
    var byModel: [String: TokenBreakdown]
    var sessionID: String?

    func accumulate(into models: inout [String: TokenBreakdown], previous: inout [String: TokenBreakdown]) {
        for (model, tokens) in byModel {
            var retained = previous[model] ?? TokenBreakdown()
            let delta = tokens.positiveDelta(from: retained)
            retained.add(delta)
            previous[model] = retained
            var aggregate = models[model] ?? TokenBreakdown()
            aggregate.add(delta)
            models[model] = aggregate
        }
    }
}
