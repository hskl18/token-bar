import Foundation

struct CodexMixSampler {
    private let readChunkBytes = 1024 * 1024
    private let parser = CodexTranscriptParser()

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
        var ledger = loadLedger()
        let original = ledger

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
        ledger.byDayAndModel = ledger.byDayAndModel.filter { $0.key >= cutoffDay }
        ledger.messageHashesByDay = ledger.messageHashesByDay.filter { $0.key >= cutoffDay }
        if ledger != original { save(ledger) }
        return ledger
    }

    private func sessionFiles(since cutoff: Date) -> [TranscriptFile] {
        let home = AccountSource.primaryDirectory(for: .codex)
        return TranscriptFile.list(in: ["sessions", "archived_sessions"].map {
            home.appendingPathComponent($0)
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
        guard seenHashes.insert(hash).inserted else { return }

        ledger.messageHashesByDay[event.day, default: []].insert(hash)
        var models = ledger.byDayAndModel[event.day] ?? [:]
        var aggregate = models[event.model] ?? TokenBreakdown()
        aggregate.add(event.breakdown)
        models[event.model] = aggregate
        ledger.byDayAndModel[event.day] = models
    }

    private func loadLedger() -> CodexUsageLedger {
        TranscriptCache.load(CodexUsageLedger.self, key: StorageKeys.codexUsageLedger) ?? .empty
    }

    private func save(_ ledger: CodexUsageLedger) {
        TranscriptCache.save(ledger, key: StorageKeys.codexUsageLedger)
    }
}
