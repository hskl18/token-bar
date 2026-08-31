import Foundation

struct CodexMixSampler {
    private let readChunkBytes = 1024 * 1024
    private let defaults: UserDefaults
    private let parser = CodexTranscriptParser()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func update() async -> CodexUsageLedger {
        await Task.detached(priority: .utility) {
            updateSynchronously()
        }.value
    }

    private func updateSynchronously() -> CodexUsageLedger {
        let calendar = Calendar.current
        let cutoff = calendar.dateInterval(of: .year, for: Date())?.start
            ?? calendar.startOfDay(for: Date())
        let cutoffDay = Self.dayFormatter.string(from: cutoff)
        let files = sessionFiles(since: cutoff)
        let activePaths = Set(files.map { $0.url.path })
        var ledger = loadLedger()

        let removed = ledger.cursors.keys.contains { !activePaths.contains($0) }
        let truncated = files.contains { file in
            ledger.cursors[file.url.path].map { file.size < $0.offset } ?? false
        }
        if removed || truncated {
            ledger = .empty
        }

        var seenHashes = Set(ledger.messageHashesByDay.values.joined())
        for file in files {
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
                save(ledger)
            } catch {
                try? handle.close()
            }
        }

        ledger.cursors = ledger.cursors.filter { activePaths.contains($0.key) }
        ledger.byDayAndModel = ledger.byDayAndModel.filter { $0.key >= cutoffDay }
        ledger.messageHashesByDay = ledger.messageHashesByDay.filter { $0.key >= cutoffDay }
        save(ledger)
        return ledger
    }

    private func sessionFiles(since cutoff: Date) -> [CodexMixFile] {
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

        let cutoffDay = Self.utcDayFormatter.string(from: cutoff)
        return enumerator.compactMap { item -> CodexMixFile? in
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
            let modifiedIsRecent = (values.contentModificationDate ?? .distantPast) >= cutoff
            guard pathIsRecent || modifiedIsRecent else { return nil }
            return CodexMixFile(url: url, size: UInt64(fileSize))
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
        guard let data = defaults.data(forKey: StorageKeys.codexUsageLedger),
              let ledger = try? JSONDecoder().decode(CodexUsageLedger.self, from: data)
        else {
            return .empty
        }
        return ledger
    }

    private func save(_ ledger: CodexUsageLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: StorageKeys.codexUsageLedger)
    }

    private static let utcDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
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
}

private struct CodexMixFile {
    var url: URL
    var size: UInt64
}
