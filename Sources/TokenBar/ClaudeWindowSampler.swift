import Foundation

struct ClaudeWindowSampler {
    private let readChunkBytes = 1024 * 1024
    private let lineParser = ClaudeMixSampler()
    private let configDirectory: URL
    private let ledgerKey: String

    init(configDirectory: URL? = nil) {
        self.configDirectory = configDirectory ?? AccountSource.primaryDirectory(for: .claude)
        ledgerKey = configDirectory.map {
            StorageKeys.profileWindowLedger(StorageKeys.claudeWindowLedger, directory: $0.path)
        } ?? StorageKeys.claudeWindowLedger
    }

    func update(windowStartedAt: Date, resetsAt: Date) async throws -> ClaudeWindowLedger {
        let scan = Task.detached(priority: .utility) {
            try updateSynchronously(windowStartedAt: windowStartedAt, resetsAt: resetsAt)
        }
        return try await withTaskCancellationHandler(operation: { try await scan.value }, onCancel: { scan.cancel() })
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

        let removed = ledger.cursors.keys.contains { !activePaths.contains($0) }
        let truncated = files.contains { file in file.size < (ledger.cursors[file.url.path] ?? 0) }
        // Errors may belong to a removed or rewritten file, so rescan the window instead of keeping them.
        if ledger.parseErrors > 0, removed || truncated {
            ledger = .empty(windowStartedAt: windowStartedAt, resetsAt: resetsAt, observedAt: observedAt)
        }
        ledger.cursors = ledger.cursors.filter { activePaths.contains($0.key) }
        for file in files where file.size < (ledger.cursors[file.url.path] ?? 0) {
            ledger.cursors.removeValue(forKey: file.url.path)
        }
        ledger.observedAt = observedAt
        ledger.isComplete = false

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
        }

        ledger.cursors = ledger.cursors.filter { activePaths.contains($0.key) }
        ledger.isComplete = true
        save(ledger)
        return ledger
    }

    private func sessionFiles(since windowStartedAt: Date) -> [TranscriptFile] {
        TranscriptFile.list(in: [configDirectory.appendingPathComponent("projects")], since: windowStartedAt)
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
        guard let record = lineParser.usageRecord(from: line[...]) else {
            if let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                let message = root["message"] as? [String: Any]
                let usage = message?["usage"] as? [String: Any] ?? [:]
                if ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                    .contains(where: { (usage[$0] as? NSNumber)?.int64Value ?? 0 > 0 }) {
                    ledger.parseErrors += 1
                }
            } else { ledger.parseErrors += 1 }
            return
        }
        guard record.date >= ledger.windowStartedAt, record.date <= ledger.observedAt else {
            return
        }

        let identity = record.dedupeID ?? "\(path):\(record.date.timeIntervalSince1970):\(record.model)"
        let hash = lineParser.stableHash(identity)
        let day = Self.dayFormatter.string(from: record.date)
        var message = ledger.messageUsage[hash] ?? ClaudeMessageUsage(day: day, byModel: [:])
        var models = ledger.byDayAndModel[message.day] ?? [:]
        record.accumulate(into: &models, previous: &message.byModel)
        ledger.byDayAndModel[message.day] = models
        ledger.messageUsage[hash] = message
    }

    private func isRelevantPrefix(_ prefix: Data.SubSequence) -> Bool {
        lineParser.isRelevantPrefix(prefix)
    }

    private func loadLedger(
        windowStartedAt: Date,
        resetsAt: Date,
        observedAt: Date
    ) -> ClaudeWindowLedger {
        guard let ledger = TranscriptCache.load(
                ClaudeWindowLedger.self, key: ledgerKey
              ),
              abs(ledger.windowStartedAt.timeIntervalSince(windowStartedAt)) < 2,
              abs(ledger.resetsAt.timeIntervalSince(resetsAt)) < 2
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
        TranscriptCache.save(ledger, key: ledgerKey)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

}
