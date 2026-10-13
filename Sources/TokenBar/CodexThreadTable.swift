import Foundation
import SQLite3

/// Codex's `state_5.sqlite` thread table, which outlives rollout files that get deleted.
enum CodexThreadTable {
    /// Adds usage since `start` from threads whose rollout file is gone, on each thread's last update's UTC day.
    /// `seen` holds the last cumulative total scanned per session, so only usage after that scan is added.
    /// Tokens are split like the same model's records in `byDayAndModel`, or in `fallback` when it has none.
    static func addLostThreads(
        in codexHome: URL,
        since start: Date,
        seen: [String: Int64],
        to byDayAndModel: inout [String: [String: TokenBreakdown]],
        fallback: () -> MixLedger = { .empty }
    ) {
        let threads = lostThreads(in: codexHome, updatedSince: start)
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

    private static func lostThreads(in codexHome: URL, updatedSince start: Date) -> [LostThread] {
        let database = codexHome.appendingPathComponent("state_5.sqlite")
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard AccountSource.isRegularFile(database),
              sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return [] }
        sqlite3_busy_timeout(connection, 1000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT id, rollout_path, model, tokens_used, created_at, updated_at, source, thread_source FROM threads"
            + " WHERE updated_at >= ? AND tokens_used > 0 AND model IS NOT NULL"
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970.rounded(.down)))
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
