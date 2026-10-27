import Foundation

struct CodexMixSampler {
    private let readChunkBytes = 1024 * 1024
    private let parser: CodexTranscriptParser
    private let codexHomes: [URL]
    private let ledgerKey: String

    init(codexHome: URL? = nil, additionalHomes: [URL] = [], accountID: String? = nil) {
        parser = CodexTranscriptParser(accountID: accountID)
        codexHomes = Array(Set([codexHome ?? AccountSource.primaryDirectory(for: .codex)] + additionalHomes))
            .sorted { $0.path < $1.path }
        ledgerKey = StorageKeys.codexLedger(StorageKeys.codexUsageLedger, directories: codexHomes.map(\.path))
    }

    /// The result also counts threads whose rollout files are gone; the saved ledger keeps only rollout records.
    func update() async -> CodexUsageLedger {
        let scan = Task.detached(priority: .utility) { updateSynchronously() }
        return await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
    }

    private func updateSynchronously() -> CodexUsageLedger {
        let calendar = Calendar.current
        // UTC day keys: start a day early so the UTC day spanning the local cutoff is complete.
        let cutoff = min(
            ActivityPeriod.year.interval(calendar: calendar).start,
            ActivityPeriod.week.interval(calendar: calendar).start
        ).addingTimeInterval(-24 * 60 * 60)
        let cutoffDay = TokenActivity.utcDayFormatter.string(from: cutoff)
        let files = sessionFiles(since: cutoff)
        let activePaths = Set(files.map { $0.url.path })
        let original = loadLedger()
        var ledger = original
        ledger.accountID = parser.accountID

        ledger.cursors = ledger.cursors.filter { activePaths.contains($0.key) }
        for file in files where file.size < (ledger.cursors[file.url.path]?.offset ?? 0) {
            ledger.cursors.removeValue(forKey: file.url.path)
        }

        var seenHashes = Set(ledger.messageHashesByDay.values.joined())
        for file in files {
            if Task.isCancelled { return ledger }
            let path = file.url.path
            var cursor = ledger.cursors[path] ?? CodexWindowCursor(
                offset: 0,
                model: nil,
                previousTotal: nil,
                logicalSessionKey: path,
                sawSessionMeta: false,
                suppressingForkCopies: false,
                forkCopyAnchor: nil
            )
            if cursor.sawSessionMeta == nil {
                cursor.sawSessionMeta = cursor.offset > 0
            }
            guard file.size > cursor.offset,
                  let handle = try? FileHandle(forReadingFrom: file.url)
            else {
                continue
            }

            do {
                try handle.seek(toOffset: cursor.offset)
                var readOffset = cursor.offset
                var processedOffset = cursor.offset
                var pending = Data()
                var discardingLine = false

                while readOffset < file.size {
                    if Task.isCancelled { try? handle.close(); return ledger }
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
                        cutoffDay: cutoffDay,
                        cursor: &cursor,
                        ledger: &ledger,
                        seenHashes: &seenHashes,
                        pending: &pending,
                        discardingLine: &discardingLine,
                        processedOffset: &processedOffset
                    )
                    cursor.offset = processedOffset
                    ledger.cursors[path] = cursor
                }
                try handle.close()
            } catch {
                try? handle.close()
            }
        }

        ledger.cursors = ledger.cursors.filter { activePaths.contains($0.key) }
        let today = TokenActivity.utcDayFormatter.string(from: Date())
        for cursor in ledger.cursors.values {
            guard let total = cursor.previousTotal?.total else { continue }
            let retained = ledger.rolloutTotals[cursor.logicalSessionKey]?.tokens ?? 0
            ledger.rolloutTotals[cursor.logicalSessionKey] = RolloutTotal(day: today, tokens: max(retained, total))
        }
        ledger.byDayAndModel = ledger.byDayAndModel.filter { $0.key >= cutoffDay }
        ledger.messageHashesByDay = ledger.messageHashesByDay.filter { $0.key >= cutoffDay }
        ledger.unreconciledMessageHashesByDay = ledger.unreconciledMessageHashesByDay?
            .filter { $0.key >= cutoffDay && !$0.value.isEmpty }
        ledger.rolloutTotals = ledger.rolloutTotals.filter { $0.value.day >= cutoffDay }
        if ledger != original { save(ledger) }
        var result = ledger
        result.recordedTokensByDay = ledger.byDayAndModel.mapValues { models in
            models.values.reduce(0) { $0 + $1.total }
        }
        CodexThreadTable.addLostThreads(
            in: codexHomes, accountID: parser.accountID, since: cutoff,
            seen: ledger.rolloutTotals.mapValues(\.tokens), to: &result.byDayAndModel
        )
        return result
    }

    /// The saved calendar mix, without lost threads.
    func savedMixLedger() -> MixLedger {
        loadLedger().mixLedger
    }

    private func sessionFiles(since cutoff: Date) -> [TranscriptFile] {
        TranscriptFile.list(in: codexHomes.flatMap { home in
            ["sessions", "archived_sessions"].map { home.appendingPathComponent($0) }
        }, since: cutoff)
    }

    private func consumeChunk(
        _ data: Data,
        chunkOffset: UInt64,
        path: String,
        cutoffDay: String,
        cursor: inout CodexWindowCursor,
        ledger: inout CodexUsageLedger,
        seenHashes: inout Set<UInt64>,
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
                parseLine(
                    pending,
                    path: path,
                    cutoffDay: cutoffDay,
                    cursor: &cursor,
                    ledger: &ledger,
                    seenHashes: &seenHashes
                )
            }
            pending.removeAll(keepingCapacity: true)
            discardingLine = false
            let byteOffset = data.distance(from: data.startIndex, to: index)
            processedOffset = chunkOffset + UInt64(byteOffset + 1)
            segmentStart = data.index(after: index)
        }

        if segmentStart < data.endIndex, !discardingLine {
            pending.append(contentsOf: data[segmentStart..<data.endIndex])
            if pending.count >= 1024, !parser.isRelevantPrefix(pending.prefix(1024)) {
                pending.removeAll(keepingCapacity: true)
                discardingLine = true
            }
        }
    }

    private func parseLine(
        _ line: Data,
        path: String,
        cutoffDay: String,
        cursor: inout CodexWindowCursor,
        ledger: inout CodexUsageLedger,
        seenHashes: inout Set<UInt64>
    ) {
        let result = parser.parse(line, path: path, cursor: &cursor)
        if result.malformed {
            ledger.parseErrors += 1
            return
        }
        guard let event = result.event, event.day >= cutoffDay else { return }
        let hash = parser.stableHash(event.identity)
        ledger.unreconciledMessageHashesByDay?[event.day]?.remove(hash)
        guard seenHashes.insert(hash).inserted else { return }

        ledger.messageHashesByDay[event.day, default: []].insert(hash)
        var models = ledger.byDayAndModel[event.day] ?? [:]
        var aggregate = models[event.model] ?? TokenBreakdown()
        aggregate.add(event.breakdown)
        models[event.model] = aggregate
        ledger.byDayAndModel[event.day] = models
    }

    private func loadLedger() -> CodexUsageLedger {
        // A ledger counted for another login holds that login's sessions, so it starts over.
        func load(_ key: String) -> CodexUsageLedger? {
            TranscriptCache.load(CodexUsageLedger.self, key: key).flatMap { $0.accountID == parser.accountID ? $0 : nil }
        }
        if let saved = load(ledgerKey) { return saved }
        guard codexHomes.count > 1 else { return .empty }
        return .seed(from: codexHomes.compactMap {
            load(StorageKeys.codexLedger(StorageKeys.codexUsageLedger, directories: [$0.path]))
        })
    }

    private func save(_ ledger: CodexUsageLedger) {
        TranscriptCache.save(ledger, key: ledgerKey)
    }
}
