import Foundation
import SQLite3

struct CodexMixSampler {
    private let readChunkBytes = 1024 * 1024
    private let parser = CodexTranscriptParser()
    private let codexHome: URL
    private let ledgerKey: String

    init(codexHome: URL? = nil) {
        self.codexHome = codexHome ?? AccountSource.primaryDirectory(for: .codex)
        ledgerKey = codexHome.map { StorageKeys.profileLedger(StorageKeys.codexUsageLedger, directory: $0.path) }
            ?? StorageKeys.codexUsageLedger
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
        let today = TokenActivity.utcDayFormatter.string(from: Date())
        var scanned = ledger.scannedRollouts.filter { $0.value >= cutoffDay }
        for path in activePaths { scanned[path] = today }
        ledger.scannedRollouts = scanned
        if ledger != original { save(ledger) }
        return supplemented(ledger, since: cutoff, cutoffDay: cutoffDay)
    }

    // Each lost thread's total takes the token categories of the same model's local records.
    private func supplemented(_ ledger: CodexUsageLedger, since cutoff: Date, cutoffDay: String) -> CodexUsageLedger {
        let missing = missingThreadTokens(since: cutoff, scanned: ledger.scannedRollouts)
        guard !missing.isEmpty else { return ledger }
        let keysByModel = Dictionary(grouping: ledger.mixLedger.byModel) { UsagePriceKey.model($0.key) }
        var result = ledger
        for (day, models) in missing where day >= cutoffDay {
            for (model, tokens) in models {
                // A model without local records has no categories to price, so its threads stay out.
                guard let keys = keysByModel[model] else { continue }
                let localTokens = keys.reduce(0) { $0 + $1.value.total }
                guard localTokens > 0 else { continue }
                for (key, breakdown) in keys {
                    result.byDayAndModel[day, default: [:]][key, default: TokenBreakdown()]
                        .add(breakdown.scaled(by: Double(tokens) / Double(localTokens)))
                }
            }
        }
        return result
    }

    /// Tokens of threads whose rollout file is gone, by UTC day and model, from Codex's thread table.
    private func missingThreadTokens(since cutoff: Date, scanned: [String: String]) -> [String: [String: Int64]] {
        let database = codexHome.appendingPathComponent("state_5.sqlite")
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard AccountSource.isRegularFile(database),
              sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return [:] }
        sqlite3_busy_timeout(connection, 1000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT rollout_path, model, tokens_used, updated_at FROM threads"
            + " WHERE updated_at >= ? AND tokens_used > 0 AND model IS NOT NULL"
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else { return [:] }
        sqlite3_bind_int64(statement, 1, Int64(cutoff.timeIntervalSince1970))
        var tokens: [String: [String: Int64]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pathText = sqlite3_column_text(statement, 0),
                  let modelText = sqlite3_column_text(statement, 1)
            else { continue }
            let path = String(cString: pathText)
            guard scanned[path] == nil, !AccountSource.isExcluded(URL(fileURLWithPath: path)),
                  !FileManager.default.fileExists(atPath: path)
            else { continue }
            // shortcut: a thread's whole total lands on its last update's UTC day; split by turn if long threads lose files.
            let updatedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3)))
            let day = TokenActivity.utcDayFormatter.string(from: updatedAt)
            tokens[day, default: [:]][String(cString: modelText), default: 0] += sqlite3_column_int64(statement, 2)
        }
        return tokens
    }

    private func sessionFiles(since cutoff: Date) -> [TranscriptFile] {
        TranscriptFile.list(in: ["sessions", "archived_sessions"].map {
            codexHome.appendingPathComponent($0)
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
        TranscriptCache.load(CodexUsageLedger.self, key: ledgerKey) ?? .empty
    }

    private func save(_ ledger: CodexUsageLedger) {
        TranscriptCache.save(ledger, key: ledgerKey)
    }
}
