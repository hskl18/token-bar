import Foundation

struct ClaudeWindowSampler {
    private let readChunkBytes = 1024 * 1024
    private let defaults: UserDefaults
    private let lineParser: ClaudeMixSampler

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lineParser = ClaudeMixSampler(defaults: defaults)
    }

    func update(windowStartedAt: Date, resetsAt: Date) async throws -> ClaudeWindowLedger {
        try await Task.detached(priority: .utility) {
            try updateSynchronously(windowStartedAt: windowStartedAt, resetsAt: resetsAt)
        }.value
    }

    private func updateSynchronously(
        windowStartedAt: Date,
        resetsAt: Date
    ) throws -> ClaudeWindowLedger {
        let files = sessionFiles(since: windowStartedAt)
        let observedAt = Date()
        let activePaths = Set(files.map { $0.url.path })
        var ledger = loadLedger(
            windowStartedAt: windowStartedAt,
            resetsAt: resetsAt,
            observedAt: observedAt
        )

        let hasRemovedFile = ledger.cursors.keys.contains { !activePaths.contains($0) }
        let hasTruncatedFile = files.contains { file in
            guard let offset = ledger.cursors[file.url.path] else { return false }
            return file.size < offset
        }
        if hasRemovedFile || hasTruncatedFile {
            ledger = .empty(
                windowStartedAt: windowStartedAt,
                resetsAt: resetsAt,
                observedAt: observedAt
            )
        } else {
            ledger.observedAt = observedAt
            ledger.isComplete = false
        }

        for file in files {
            try Task.checkCancellation()
            let path = file.url.path
            let start = ledger.cursors[path] ?? 0
            guard file.size > start else { continue }

            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: start)
            var readOffset = start
            var processedOffset = start
            var pending = Data()
            var discardingLine = false

            while readOffset < file.size {
                try Task.checkCancellation()
                let count = Int(min(UInt64(readChunkBytes), file.size - readOffset))
                let data = try autoreleasepool {
                    try handle.read(upToCount: count) ?? Data()
                }
                guard !data.isEmpty else { break }
                let chunkOffset = readOffset
                readOffset += UInt64(data.count)
                consumeChunk(
                    data,
                    chunkOffset: chunkOffset,
                    path: path,
                    ledger: &ledger,
                    pending: &pending,
                    discardingLine: &discardingLine,
                    processedOffset: &processedOffset
                )
                ledger.cursors[path] = processedOffset
            }

            save(ledger)
        }

        ledger.cursors = ledger.cursors.filter { activePaths.contains($0.key) }
        ledger.isComplete = true
        save(ledger)
        return ledger
    }

    private func sessionFiles(since windowStartedAt: Date) -> [ClaudeSessionFile] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> ClaudeSessionFile? in
            guard let url = item as? URL,
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  (values.contentModificationDate ?? .distantPast) >= windowStartedAt
            else {
                return nil
            }
            return ClaudeSessionFile(url: url, size: UInt64(fileSize))
        }
        .sorted { $0.url.path < $1.url.path }
    }

    private func consumeChunk(
        _ data: Data,
        chunkOffset: UInt64,
        path: String,
        ledger: inout ClaudeWindowLedger,
        pending: inout Data,
        discardingLine: inout Bool,
        processedOffset: inout UInt64
    ) {
        var segmentStart = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            if !discardingLine, segmentStart < index {
                pending.append(contentsOf: data[segmentStart..<index])
            }
            if !discardingLine, !pending.isEmpty {
                parseLine(pending, path: path, ledger: &ledger)
            }
            pending.removeAll(keepingCapacity: true)
            discardingLine = false
            let byteOffset = data.distance(from: data.startIndex, to: index)
            processedOffset = chunkOffset + UInt64(byteOffset + 1)
            segmentStart = data.index(after: index)
        }

        if segmentStart < data.endIndex, !discardingLine {
            pending.append(contentsOf: data[segmentStart..<data.endIndex])
            if pending.count >= 1024, !isRelevantPrefix(pending.prefix(1024)) {
                pending.removeAll(keepingCapacity: true)
                discardingLine = true
            }
        }
    }

    private func parseLine(
        _ line: Data,
        path: String,
        ledger: inout ClaudeWindowLedger
    ) {
        guard isRelevantPrefix(line.prefix(1024)) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let root = object as? [String: Any]
        else {
            ledger.parseErrors += 1
            return
        }
        guard root["type"] as? String == "assistant" else { return }
        guard let record = lineParser.usageRecord(from: line[...]) else {
            if hasPositiveUsage(in: root) {
                ledger.parseErrors += 1
            }
            return
        }
        guard record.date >= ledger.windowStartedAt, record.date <= ledger.observedAt else {
            return
        }

        let identity = record.dedupeID ?? [
            path,
            record.date.timeIntervalSince1970.description,
            record.model,
            String(record.breakdown.input),
            String(record.breakdown.cacheCreationInput),
            String(record.breakdown.cachedInput),
            String(record.breakdown.output),
        ].joined(separator: ":")
        let hash = lineParser.stableHash(identity)
        guard ledger.messageHashes.insert(hash).inserted else { return }

        var aggregate = ledger.byModel[record.model] ?? TokenBreakdown()
        aggregate.add(record.breakdown)
        ledger.byModel[record.model] = aggregate
    }

    private func isRelevantPrefix(_ prefix: Data.SubSequence) -> Bool {
        prefix.range(of: Self.messageMarker) != nil
    }

    private func hasPositiveUsage(in root: [String: Any]) -> Bool {
        guard let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else {
            return false
        }
        let total = [
            usage["input_tokens"],
            usage["cache_creation_input_tokens"],
            usage["cache_read_input_tokens"],
            usage["output_tokens"],
        ].compactMap(numericValue).reduce(0, +)
        return total > 0
    }

    private func numericValue(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private func loadLedger(
        windowStartedAt: Date,
        resetsAt: Date,
        observedAt: Date
    ) -> ClaudeWindowLedger {
        guard let data = defaults.data(forKey: StorageKeys.claudeWindowLedger),
              let ledger = try? JSONDecoder().decode(ClaudeWindowLedger.self, from: data),
              abs(ledger.windowStartedAt.timeIntervalSince(windowStartedAt)) < 1,
              abs(ledger.resetsAt.timeIntervalSince(resetsAt)) < 1
        else {
            return .empty(
                windowStartedAt: windowStartedAt,
                resetsAt: resetsAt,
                observedAt: observedAt
            )
        }
        return ledger
    }

    private func save(_ ledger: ClaudeWindowLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: StorageKeys.claudeWindowLedger)
    }

    private static let messageMarker = Data(#""message":{"#.utf8)
}

private struct ClaudeSessionFile {
    var url: URL
    var size: UInt64
}
