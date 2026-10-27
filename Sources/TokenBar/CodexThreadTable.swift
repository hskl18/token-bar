import Foundation
import SQLite3

/// Codex's `state_5.sqlite` thread table, which outlives rollout files that get deleted.
enum CodexThreadTable {
    /// Adds usage since `start` from threads whose rollout file is gone, on each thread's last update's UTC day.
    /// `seen` holds the last cumulative total scanned per session, so only usage after that scan is added.
    /// Tokens are split like the same model's records in `byDayAndModel`, or in `fallback` when it has none.
    /// With `accountID`, threads another login created are skipped, like their rollouts.
    static func addLostThreads(
        in codexHomes: [URL],
        accountID: String? = nil,
        since start: Date,
        seen: [String: Int64],
        to byDayAndModel: inout [String: [String: TokenBreakdown]],
        fallback: () -> MixLedger = { .empty }
    ) {
        let threads = codexHomes.flatMap { lostThreads(in: $0, accountID: accountID, updatedSince: start) }
            .reduce(into: [String: LostThread]()) { unique, thread in
                if thread.tokens > (unique[thread.id]?.tokens ?? 0) { unique[thread.id] = thread }
            }.values
        guard !threads.isEmpty else { return }
        var keysByModel = keysByModel(in: MixLedger(byDayAndModel: byDayAndModel))
        var fallbackKeys: [String: [String: TokenBreakdown]]?
        for thread in threads where thread.updatedAt >= start {
            let tokens: Int64
            if let total = seen[CodexTranscriptParser.sessionKey(thread.id)] {
                tokens = thread.tokens - total
            } else if thread.isSubagent {
                // A spawned thread's total starts with its parent's, which an unscanned file cannot separate.
                continue
            } else {
                // A thread begun before `start` counts the share of its run time after it.
                let share = thread.createdAt < start
                    ? thread.updatedAt.timeIntervalSince(start) / thread.updatedAt.timeIntervalSince(thread.createdAt)
                    : 1
                tokens = Int64(Double(thread.tokens) * share)
            }
            if keysByModel[thread.model] == nil {
                fallbackKeys = fallbackKeys ?? Self.keysByModel(in: fallback())
                keysByModel[thread.model] = fallbackKeys?[thread.model]
            }
            // A model without local records has no token categories to price, so its threads stay out.
            guard tokens > 0, let keys = keysByModel[thread.model] else { continue }
            let localTokens = keys.values.reduce(0) { $0 + $1.total }
            guard localTokens > 0 else { continue }
            let day = TokenActivity.utcDayFormatter.string(from: thread.updatedAt)
            for (key, breakdown) in keys {
                byDayAndModel[day, default: [:]][key, default: TokenBreakdown()]
                    .add(breakdown.scaled(by: Double(tokens) / Double(localTokens)))
            }
        }
    }

    private struct LostThread {
        var id: String
        var model: String
        var tokens: Int64
        var createdAt: Date
        var updatedAt: Date
        var isSubagent: Bool
    }

    private static func keysByModel(in ledger: MixLedger) -> [String: [String: TokenBreakdown]] {
        ledger.byModel.reduce(into: [:]) { $0[UsagePriceKey.model($1.key), default: [:]][$1.key] = $1.value }
    }

    /// The folder `sqlite_home` in the login's `config.toml` names, as Codex reads it; otherwise the login's own folder.
    static func databaseFolder(for codexHome: URL) -> URL {
        let config = (try? String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        // Top-level keys come before the first table header.
        for line in config.split(separator: "\n").prefix(while: { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            // A basic or literal string, optionally followed by a comment.
            // shortcut: escapes in a basic string are not decoded; such a path falls back to the login's folder.
            guard parts.count == 2, parts[0] == "sqlite_home", let quote = parts[1].first, quote == "\"" || quote == "'",
                  let end = parts[1].dropFirst().firstIndex(of: quote) else { continue }
            let value = parts[1][parts[1].index(after: parts[1].startIndex)..<end]
            let rest = parts[1][parts[1].index(after: end)...].trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty || rest.hasPrefix("#"), quote == "'" || !value.contains("\\") else { continue }
            let path = (String(value) as NSString).expandingTildeInPath
            if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return codexHome
    }

    private static func lostThreads(in codexHome: URL, accountID: String?, updatedSince start: Date) -> [LostThread] {
        let folder = databaseFolder(for: codexHome)
        // Another login's database holds its creator-less threads too, so only this login's own count here.
        let shared = folder.resolvingSymlinksInPath() != codexHome.resolvingSymlinksInPath()
        if shared && accountID == nil { return [] }
        let database = folder.appendingPathComponent("state_5.sqlite")
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        // A read-only open of this WAL database fails while no connection holds its -shm file;
        // the last connection to close normally checkpoints every commit into the main file first.
        let immutable = !FileManager.default.fileExists(atPath: database.path + "-shm")
        guard AccountSource.isRegularFile(database),
              sqlite3_open_v2(
                  database.absoluteString + (immutable ? "?immutable=1" : ""), &connection,
                  SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
              ) == SQLITE_OK
        else { return [] }
        sqlite3_busy_timeout(connection, 1000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT id, rollout_path, model, tokens_used, created_at, updated_at, source, thread_source FROM threads"
            + " WHERE updated_at >= ?1 AND tokens_used > 0 AND model IS NOT NULL"
            + (shared ? " AND creator_account_id = ?2" : " AND (?2 IS NULL OR creator_account_id IS NULL OR creator_account_id = ?2)")
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970.rounded(.down)))
        if let accountID {
            // SQLITE_TRANSIENT: SQLite copies the bridged C string before this call returns.
            sqlite3_bind_text(statement, 2, accountID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        var threads: [LostThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(0), let path = text(1), let model = text(2),
                  !AccountSource.isExcluded(URL(fileURLWithPath: path)),
                  !FileManager.default.fileExists(atPath: path)
            else { continue }
            let source = text(6).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            threads.append(LostThread(
                id: id,
                model: model,
                tokens: sqlite3_column_int64(statement, 3),
                createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4))),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 5))),
                isSubagent: source?["subagent"] != nil || text(7) == "subagent"
            ))
        }
        return threads
    }
}
