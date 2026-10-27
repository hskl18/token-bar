import Foundation

struct CodexWindowSampler {
    private let readChunkBytes = 1024 * 1024
    private let defaults: UserDefaults
    private let parser: CodexTranscriptParser
    private let codexHomes: [URL]
    private let ledgerKey: String
    private let mixSampler: CodexMixSampler

    init(
        defaults: UserDefaults = .standard, codexHome: URL? = nil, additionalHomes: [URL] = [], accountID: String? = nil,
        weeklyResets: [String: Date] = [:]
    ) {
        self.defaults = defaults
        codexHomes = Array(Set([codexHome ?? AccountSource.primaryDirectory(for: .codex)] + additionalHomes))
            .sorted { $0.path < $1.path }
        parser = CodexTranscriptParser(accountID: accountID, homes: codexHomes, weeklyResets: weeklyResets)
        mixSampler = CodexMixSampler(
            codexHome: codexHome, additionalHomes: additionalHomes, accountID: accountID, weeklyResets: weeklyResets
        )
        ledgerKey = StorageKeys.codexLedger(
            StorageKeys.codexWindowLedger, directories: CodexMixSampler.ledgerFolders(for: codexHomes)
        )
    }

    /// The result also counts threads whose rollout files are gone; the saved ledger keeps only rollout records.
    func update(windowStartedAt: Date, resetsAt: Date) async throws -> CodexWindowLedger {
        let scan = Task.detached(priority: .utility) {
            try updateSynchronously(windowStartedAt: windowStartedAt, resetsAt: resetsAt)
        }
        return try await withTaskCancellationHandler(operation: { try await scan.value }, onCancel: { scan.cancel() })
    }

    private func updateSynchronously(
        windowStartedAt: Date,
        resetsAt: Date
    ) throws -> CodexWindowLedger {
        let files = sessionFiles(since: windowStartedAt)
        let observedAt = Date()
        let activePaths = Set(files.map { $0.url.path })
        var ledger = loadLedger(
            windowStartedAt: windowStartedAt,
            resetsAt: resetsAt,
            observedAt: observedAt
        )

        let removed = ledger.cursors.keys.contains { !activePaths.contains($0) }
        let truncated = files.contains { file in file.size < (ledger.cursors[file.url.path]?.offset ?? 0) }
        // Errors may belong to a removed or rewritten file, so rescan the window instead of keeping them.
        if ledger.parseErrors > 0, removed || truncated {
            ledger = .empty(windowStartedAt: windowStartedAt, resetsAt: resetsAt, observedAt: observedAt)
        }
        ledger.cursors = ledger.cursors.filter { activePaths.contains($0.key) }
        for file in files where file.size < (ledger.cursors[file.url.path]?.offset ?? 0) {
            ledger.cursors.removeValue(forKey: file.url.path)
        }
        ledger.observedAt = observedAt
        ledger.isComplete = false
        ledger.accountID = parser.accountID

        for file in files {
            try Task.checkCancellation()
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
            guard file.size > cursor.offset else { continue }

            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: cursor.offset)
            var readOffset = cursor.offset
            var processedOffset = cursor.offset
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
                    cursor: &cursor,
                    ledger: &ledger,
                    pending: &pending,
                    discardingLine: &discardingLine,
                    processedOffset: &processedOffset
                )
                cursor.offset = processedOffset
                ledger.cursors[path] = cursor
            }
        }

        ledger.cursors = ledger.cursors.filter { activePaths.contains($0.key) }
        for cursor in ledger.cursors.values {
            guard let total = cursor.previousTotal?.total else { continue }
            ledger.rolloutTotals[cursor.logicalSessionKey] = max(ledger.rolloutTotals[cursor.logicalSessionKey] ?? 0, total)
        }
        ledger.isComplete = true
        save(ledger)
        var result = ledger
        CodexThreadTable.addLostThreads(
            in: codexHomes, accountID: parser.accountID, since: windowStartedAt, seen: ledger.rolloutTotals,
            to: &result.byDayAndModel,
            fallback: mixSampler.savedMixLedger
        )
        if ledgerKey == StorageKeys.codexWindowLedger, result.parseErrors == 0, result.observedTokens > 0 {
            saveLastKnownMix(result.mixLedger)
        }
        return result
    }

    func lastKnownMixLedger() -> MixLedger? {
        if let data = defaults.data(forKey: StorageKeys.codexLastKnownMix),
           let ledger = try? JSONDecoder().decode(MixLedger.self, from: data),
           !ledger.byModel.isEmpty {
            return ledger
        }
        return nil
    }

    private func sessionFiles(since windowStartedAt: Date) -> [TranscriptFile] {
        // A linked `sessions` is read once, at its real path, so the parser can tell whose folder holds each file.
        TranscriptFile.list(in: Set(codexHomes.flatMap { home in
            ["sessions", "archived_sessions"].map { home.appendingPathComponent($0).resolvingSymlinksInPath().path }
        }).map { URL(fileURLWithPath: $0, isDirectory: true) }, since: windowStartedAt)
    }

    private func consumeChunk(
        _ data: Data,
        chunkOffset: UInt64,
        path: String,
        cursor: inout CodexWindowCursor,
        ledger: inout CodexWindowLedger,
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
                parseLine(pending, path: path, cursor: &cursor, ledger: &ledger)
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
        cursor: inout CodexWindowCursor,
        ledger: inout CodexWindowLedger
    ) {
        let result = parser.parse(line, path: path, cursor: &cursor)
        if result.malformed {
            ledger.parseErrors += 1
            return
        }
        guard let event = result.event,
              event.date >= ledger.windowStartedAt,
              event.date <= ledger.observedAt
        else {
            return
        }
        let hash = parser.stableHash(event.identity)
        ledger.unreconciledMessageHashes?.remove(hash)
        guard ledger.messageHashes.insert(hash).inserted else { return }

        var models = ledger.byDayAndModel[event.day] ?? [:]
        var aggregate = models[event.model] ?? TokenBreakdown()
        aggregate.add(event.breakdown)
        models[event.model] = aggregate
        ledger.byDayAndModel[event.day] = models
    }

    private func isRelevantPrefix(_ prefix: Data.SubSequence) -> Bool {
        parser.isRelevantPrefix(prefix)
    }

    private func loadLedger(
        windowStartedAt: Date,
        resetsAt: Date,
        observedAt: Date
    ) -> CodexWindowLedger {
        // A ledger counted for another login or window starts over.
        func load(_ key: String) -> CodexWindowLedger? {
            TranscriptCache.load(CodexWindowLedger.self, key: key).flatMap {
                $0.accountID == parser.accountID
                    && abs($0.windowStartedAt.timeIntervalSince(windowStartedAt)) < 2
                    && abs($0.resetsAt.timeIntervalSince(resetsAt)) < 2 ? $0 : nil
            }
        }
        guard let ledger = load(ledgerKey) else {
            var ledger = CodexWindowLedger.empty(
                windowStartedAt: windowStartedAt,
                resetsAt: resetsAt,
                observedAt: observedAt
            )
            guard codexHomes.count > 1 else { return ledger }
            let sources = codexHomes.compactMap { home -> CodexUsageLedger? in
                guard let saved = load(StorageKeys.codexLedger(StorageKeys.codexWindowLedger, directories: [home.path]))
                else { return nil }
                return CodexUsageLedger(
                    cursors: [:], byDayAndModel: saved.byDayAndModel,
                    messageHashesByDay: ["window": saved.messageHashes], parseErrors: 0,
                    rolloutTotals: saved.rolloutTotals.mapValues { RolloutTotal(day: "", tokens: $0) },
                    unreconciledMessageHashesByDay: ["window": saved.unreconciledMessageHashes ?? []]
                )
            }
            let seed = CodexUsageLedger.seed(from: sources)
            ledger.byDayAndModel = seed.byDayAndModel
            ledger.messageHashes = Set(seed.messageHashesByDay.values.joined())
            ledger.rolloutTotals = seed.rolloutTotals.mapValues(\.tokens)
            ledger.unreconciledMessageHashes = Set((seed.unreconciledMessageHashesByDay ?? [:]).values.joined())
            return ledger
        }
        return ledger
    }

    private func save(_ ledger: CodexWindowLedger) {
        TranscriptCache.save(ledger, key: ledgerKey)
    }

    private func saveLastKnownMix(_ ledger: MixLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: StorageKeys.codexLastKnownMix)
    }


}
