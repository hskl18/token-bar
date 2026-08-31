import Foundation

struct CodexWindowSampler {
    private let readChunkBytes = 1024 * 1024
    private let defaults: UserDefaults
    private let parser = CodexTranscriptParser()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func update(windowStartedAt: Date, resetsAt: Date) async throws -> CodexWindowLedger {
        try await Task.detached(priority: .utility) {
            try updateSynchronously(windowStartedAt: windowStartedAt, resetsAt: resetsAt)
        }.value
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

        let hasRemovedFile = ledger.cursors.keys.contains { !activePaths.contains($0) }
        let hasTruncatedFile = files.contains { file in
            guard let cursor = ledger.cursors[file.url.path] else { return false }
            return file.size < cursor.offset
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

            save(ledger)
        }

        ledger.cursors = ledger.cursors.filter { activePaths.contains($0.key) }
        ledger.isComplete = true
        if ledger.parseErrors == 0, ledger.observedTokens > 0 {
            saveLastKnownMix(ledger.mixLedger)
        }
        save(ledger)
        return ledger
    }

    func lastKnownMixLedger() -> MixLedger? {
        if let data = defaults.data(forKey: StorageKeys.codexLastKnownMix),
           let ledger = try? JSONDecoder().decode(MixLedger.self, from: data),
           !ledger.byModel.isEmpty {
            return ledger
        }
        return nil
    }

    private func sessionFiles(since windowStartedAt: Date) -> [SessionFile] {
        let environment = ProcessInfo.processInfo.environment
        let codexHome = environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let root = codexHome.appendingPathComponent("sessions", isDirectory: true)
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

        let cutoffDay = Self.utcDayFormatter.string(from: windowStartedAt)
        return enumerator.compactMap { item -> SessionFile? in
            guard let url = item as? URL,
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize > 0
            else {
                return nil
            }
            let pathIsRecent = sessionPathDay(url.path).map { $0 >= cutoffDay } ?? false
            let modifiedIsRecent = (values.contentModificationDate ?? .distantPast) >= windowStartedAt
            guard pathIsRecent || modifiedIsRecent else { return nil }
            return SessionFile(url: url, size: UInt64(fileSize))
        }
        .sorted { $0.url.path < $1.url.path }
    }

    private func sessionPathDay(_ path: String) -> String? {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard let sessionsIndex = parts.lastIndex(of: "sessions"),
              parts.count > sessionsIndex + 3
        else {
            return nil
        }
        let dateParts = parts[(sessionsIndex + 1)...(sessionsIndex + 3)]
        guard dateParts.count == 3, dateParts.allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        return dateParts.joined(separator: "-")
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
        guard ledger.messageHashes.insert(hash).inserted else { return }

        var aggregate = ledger.byModel[event.model] ?? TokenBreakdown()
        aggregate.add(event.breakdown)
        ledger.byModel[event.model] = aggregate
        ledger.tokensByDay[event.day, default: 0] += event.breakdown.total
    }

    private func isRelevantPrefix(_ prefix: Data.SubSequence) -> Bool {
        parser.isRelevantPrefix(prefix)
    }

    private func loadLedger(
        windowStartedAt: Date,
        resetsAt: Date,
        observedAt: Date
    ) -> CodexWindowLedger {
        guard let data = defaults.data(forKey: StorageKeys.codexWindowLedger),
              let ledger = try? JSONDecoder().decode(CodexWindowLedger.self, from: data),
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

    private func save(_ ledger: CodexWindowLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: StorageKeys.codexWindowLedger)
    }

    private func saveLastKnownMix(_ ledger: MixLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: StorageKeys.codexLastKnownMix)
    }

    private static let utcDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

}

private struct SessionFile {
    var url: URL
    var size: UInt64
}
