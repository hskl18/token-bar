import Foundation

struct ClaudeMixSampler {
    private let readChunkBytes = 1024 * 1024
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func update() async -> ClaudeUsageLedger {
        await Task.detached(priority: .utility) {
            updateSynchronously()
        }.value
    }

    private func updateSynchronously() -> ClaudeUsageLedger {
        var ledger = loadLedger()
        let files = sessionFiles()
        let activePaths = Set(files.map { $0.0.path })
        let removed = ledger.cursors.keys.contains { !activePaths.contains($0) }
        let truncated = files.contains { url, size in
            ledger.cursors[url.path].map { size < $0 } ?? false
        }
        if removed || truncated {
            ledger = .empty
        }
        var seenHashes = Set(ledger.messageHashesByDay.values.joined())
        let calendar = Calendar.current
        let cutoff = calendar.dateInterval(of: .year, for: Date())?.start
            ?? calendar.startOfDay(for: Date())
        let cutoffDay = Self.dayFormatter.string(from: cutoff)

        for (url, size) in files {
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
                                seenHashes: &seenHashes,
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

        ledger.byDayAndModel = ledger.byDayAndModel.filter { $0.key >= cutoffDay }
        ledger.messageHashesByDay = ledger.messageHashesByDay.filter { $0.key >= cutoffDay }
        save(ledger)
        return ledger
    }

    private func sessionFiles() -> [(URL, UInt64)] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> (URL, UInt64)? in
                guard let url = item as? URL,
                      url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let size = values.fileSize,
                      size > 0
                else {
                    return nil
                }
                return (url, UInt64(size))
            }
            .sorted { $0.0.path < $1.0.path }
    }

    private func parseLines(
        _ data: Data,
        ledger: inout ClaudeUsageLedger,
        seenHashes: inout Set<UInt64>,
        cutoffDay: String
    ) {
        for line in data.split(separator: 0x0A) {
            guard line.range(of: Self.assistantMarker) != nil,
                  let record = autoreleasepool(invoking: { usageRecord(from: line) })
            else { continue }
            let day = Self.dayFormatter.string(from: record.date)
            guard day >= cutoffDay else { continue }

            if let dedupeID = record.dedupeID {
                let hash = stableHash(dedupeID)
                guard seenHashes.insert(hash).inserted else { continue }
                ledger.messageHashesByDay[day, default: []].insert(hash)
            }

            var byModel = ledger.byDayAndModel[day] ?? [:]
            var aggregate = byModel[record.model] ?? TokenBreakdown()
            aggregate.add(record.breakdown)
            byModel[record.model] = aggregate
            ledger.byDayAndModel[day] = byModel
        }
    }

    func usageRecord(from line: Data.SubSequence) -> ClaudeUsageRecord? {
        guard let model = stringValue(after: Self.modelKey, in: line),
              let timestamp = stringValue(after: Self.timestampKey, in: line),
              let date = Self.parseDate(timestamp)
        else {
            return decodedUsageRecord(from: line)
        }

        let breakdown = TokenBreakdown(
            input: integerValue(after: Self.inputTokensKey, in: line, backwards: true) ?? 0,
            cacheCreationInput: integerValue(
                after: Self.cacheCreationTokensKey,
                in: line,
                backwards: true
            ) ?? 0,
            cacheCreationInput5m: integerValue(
                after: Self.cacheCreation5mTokensKey,
                in: line,
                backwards: true
            ),
            cacheCreationInput1h: integerValue(
                after: Self.cacheCreation1hTokensKey,
                in: line,
                backwards: true
            ),
            cachedInput: integerValue(after: Self.cacheReadTokensKey, in: line, backwards: true) ?? 0,
            output: integerValue(after: Self.outputTokensKey, in: line, backwards: true) ?? 0,
            reasoning: 0
        )
        guard breakdown.total > 0 else { return decodedUsageRecord(from: line) }
        return ClaudeUsageRecord(
            date: date,
            model: model,
            dedupeID: dedupeID(
                messageID: stringValue(after: Self.messageIDKey, in: line)
                    ?? stringValue(after: Self.uuidKey, in: line),
                requestID: stringValue(after: Self.requestIDKey, in: line)
                    ?? stringValue(after: Self.requestIDSnakeKey, in: line)
            ),
            breakdown: breakdown
        )
    }

    private func decodedUsageRecord(from line: Data.SubSequence) -> ClaudeUsageRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
              let root = object as? [String: Any],
              let timestamp = root["timestamp"] as? String,
              let date = Self.parseDate(timestamp),
              let message = root["message"] as? [String: Any],
              let model = message["model"] as? String,
              let usage = message["usage"] as? [String: Any]
        else {
            return nil
        }

        let cacheCreation = usage["cache_creation"] as? [String: Any]
        let breakdown = TokenBreakdown(
            input: numericValue(usage["input_tokens"]) ?? 0,
            cacheCreationInput: numericValue(usage["cache_creation_input_tokens"]) ?? 0,
            cacheCreationInput5m: numericValue(cacheCreation?["ephemeral_5m_input_tokens"]),
            cacheCreationInput1h: numericValue(cacheCreation?["ephemeral_1h_input_tokens"]),
            cachedInput: numericValue(usage["cache_read_input_tokens"]) ?? 0,
            output: numericValue(usage["output_tokens"]) ?? 0,
            reasoning: 0
        )
        guard breakdown.total > 0 else { return nil }
        return ClaudeUsageRecord(
            date: date,
            model: model,
            dedupeID: dedupeID(
                messageID: message["id"] as? String ?? root["uuid"] as? String,
                requestID: root["requestId"] as? String ?? root["request_id"] as? String
            ),
            breakdown: breakdown
        )
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

    private func stringValue(after key: Data, in line: Data.SubSequence) -> String? {
        guard let start = valueStart(after: key, in: line, backwards: false),
              line[start] == 0x22
        else {
            return nil
        }

        var index = line.index(after: start)
        let valueStart = index
        while index < line.endIndex {
            if line[index] == 0x22 {
                return String(decoding: line[valueStart..<index], as: UTF8.self)
            }
            if line[index] == 0x5C {
                return nil
            }
            index = line.index(after: index)
        }
        return nil
    }

    private func integerValue(after key: Data, in line: Data.SubSequence, backwards: Bool) -> Int64? {
        guard var index = valueStart(after: key, in: line, backwards: backwards) else { return nil }
        var value: Int64 = 0
        var foundDigit = false

        while index < line.endIndex {
            let byte = line[index]
            guard byte >= 0x30, byte <= 0x39 else { break }
            foundDigit = true
            let (multiplied, overflow) = value.multipliedReportingOverflow(by: 10)
            let (added, addOverflow) = multiplied.addingReportingOverflow(Int64(byte - 0x30))
            guard !overflow, !addOverflow else { return nil }
            value = added
            index = line.index(after: index)
        }
        return foundDigit ? value : nil
    }

    private func valueStart(after key: Data, in line: Data.SubSequence, backwards: Bool) -> Data.Index? {
        let options: Data.SearchOptions = backwards ? .backwards : []
        guard let range = line.range(of: key, options: options) else { return nil }
        var index = range.upperBound
        while index < line.endIndex,
              line[index] == 0x3A || line[index] == 0x20 || line[index] == 0x09 {
            index = line.index(after: index)
        }
        return index < line.endIndex ? index : nil
    }

    func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private func loadLedger() -> ClaudeUsageLedger {
        guard let data = defaults.data(forKey: StorageKeys.claudeLedger),
              let ledger = try? JSONDecoder().decode(ClaudeUsageLedger.self, from: data)
        else {
            return .empty
        }
        return ledger
    }

    private func save(_ ledger: ClaudeUsageLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: StorageKeys.claudeLedger)
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
    private static let timestampKey = Data(#""timestamp""#.utf8)
    private static let uuidKey = Data(#""uuid""#.utf8)
    private static let messageIDKey = Data(#""id""#.utf8)
    private static let requestIDKey = Data(#""requestId""#.utf8)
    private static let requestIDSnakeKey = Data(#""request_id""#.utf8)
    private static let modelKey = Data(#""model""#.utf8)
    private static let inputTokensKey = Data(#""input_tokens""#.utf8)
    private static let cacheCreationTokensKey = Data(#""cache_creation_input_tokens""#.utf8)
    private static let cacheCreation5mTokensKey = Data(#""ephemeral_5m_input_tokens""#.utf8)
    private static let cacheCreation1hTokensKey = Data(#""ephemeral_1h_input_tokens""#.utf8)
    private static let cacheReadTokensKey = Data(#""cache_read_input_tokens""#.utf8)
    private static let outputTokensKey = Data(#""output_tokens""#.utf8)
}

struct ClaudeUsageRecord {
    var date: Date
    var model: String
    var dedupeID: String?
    var breakdown: TokenBreakdown
}
