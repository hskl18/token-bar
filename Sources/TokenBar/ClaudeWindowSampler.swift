import Foundation

struct ClaudeWindowSampler {
    private let readChunkBytes = 1024 * 1024
    private let lineParser = ClaudeMixSampler()
    /// Every folder signed in to this login; one login can be signed in from several folders.
    private let ownerDirectories: Set<String>
    /// The login's `ClaudeAccountProfile.id`, which decides records whose `SessionStart` line names a login.
    private let accountID: String?
    /// The real folder behind each `projects`, which several accounts may link to and share, with who keeps
    /// a record no `SessionStart` line names: the account folder that holds it, or this account when it
    /// links somewhere no account owns, such as another disk.
    private let projectsFolders: [(url: URL, fallbackOwner: String)]
    private let ledgerKey: String

    init(configDirectory: URL? = nil, aliases: [URL] = [], accountID: String? = nil) {
        let primary = AccountSource.primaryDirectory(for: .claude)
        let directories = [configDirectory ?? primary] + aliases
        ownerDirectories = Set(directories.map(\.standardizedFileURL.path))
        self.accountID = accountID
        let accounts = Set(([primary] + AccountSource.detected().filter { $0.provider == .claude }.map(\.url))
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        var seen = Set<String>()
        projectsFolders = directories.compactMap { directory in
            let projects = directory.appendingPathComponent("projects").resolvingSymlinksInPath()
            guard seen.insert(projects.path).inserted else { return nil }
            let holder = projects.deletingLastPathComponent().standardizedFileURL.path
            return (projects, accounts.contains(holder) ? holder : directory.standardizedFileURL.path)
        }
        ledgerKey = configDirectory == nil && aliases.isEmpty
            ? StorageKeys.claudeWindowLedger
            : StorageKeys.profileLedger(
                StorageKeys.claudeWindowLedger, directory: directories.map(\.path).sorted().joined(separator: "\n")
            )
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
        let listed = sessionFiles(since: windowStartedAt)
        let files = listed.map(\.file)
        let owners = ClaudeSessionOwners.load()
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

        for (file, ownsUnnamed) in listed {
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
                    ownsUnnamed: ownsUnnamed,
                    owners: owners,
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

    /// Each transcript, and whether this login keeps its records that no `SessionStart` line names.
    private func sessionFiles(since windowStartedAt: Date) -> [(file: TranscriptFile, ownsUnnamed: Bool)] {
        projectsFolders.flatMap { folder in
            TranscriptFile.list(in: [folder.url], since: windowStartedAt)
                .map { ($0, ownerDirectories.contains(folder.fallbackOwner)) }
        }
    }

    /// A record belongs to the login its session last started under, else to the folder that keeps its file.
    /// A line naming a login decides by login, so a login keeps its records when it moves to another folder
    /// that shares `projects`; a line naming none, written signed out or before the hook recorded logins,
    /// decides by folder.
    private func belongs(_ record: ClaudeUsageRecord, ownsUnnamed: Bool, owners: ClaudeSessionOwners) -> Bool {
        guard let start = owners.owner(of: record.sessionID, at: record.date) else { return ownsUnnamed }
        if let account = start.account, !account.isEmpty { return account == accountID }
        return ownerDirectories.contains(start.directory)
    }

    private func consumeChunk(
        _ data: Data,
        chunkOffset: UInt64,
        path: String,
        ownsUnnamed: Bool,
        owners: ClaudeSessionOwners,
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
                parseLine(pending, path: path, ownsUnnamed: ownsUnnamed, owners: owners, ledger: &ledger)
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
        ownsUnnamed: Bool,
        owners: ClaudeSessionOwners,
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
        guard record.date >= ledger.windowStartedAt, record.date <= ledger.observedAt,
              belongs(record, ownsUnnamed: ownsUnnamed, owners: owners)
        else {
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
