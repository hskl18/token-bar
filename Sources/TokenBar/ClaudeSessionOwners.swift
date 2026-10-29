import Foundation

/// The config folder and login each Claude session started under, from a `SessionStart` hook that appends
/// `{"sessionId", "configDir", "account", "at"}` lines to `~/.claude/account-sessions.jsonl`.
/// Transcripts name no account, so accounts that share one `projects` folder need this to split usage.
struct ClaudeSessionOwners {
    struct Start {
        let at: Date
        let directory: String
        /// `accountUuid:organizationUuid`, the form `ClaudeAccountProfile.id` uses; empty when the folder had
        /// no login as the session started, and nil on lines written before the hook recorded it.
        let account: String?
    }

    private var starts: [String: [Start]] = [:]

    static func load(
        from file: URL = AccountSource.primaryDirectory(for: .claude).appendingPathComponent("account-sessions.jsonl")
    ) -> ClaudeSessionOwners {
        var owners = ClaudeSessionOwners()
        guard AccountSource.isRegularFile(file), let data = try? Data(contentsOf: file) else { return owners }
        let formatter = ISO8601DateFormatter()
        for line in data.split(separator: 0x0A) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let session = row["sessionId"] as? String,
                  let directory = row["configDir"] as? String,
                  let at = (row["at"] as? String).flatMap(formatter.date(from:))
            else { continue }
            owners.starts[session, default: []].append(Start(
                at: at, directory: URL(fileURLWithPath: directory).standardizedFileURL.path,
                account: row["account"] as? String
            ))
        }
        return owners
    }

    /// The start the session last had at or before `date`; a later line wins a tie.
    func owner(of session: String?, at date: Date) -> Start? {
        var latest: Start?
        for start in session.flatMap({ starts[$0] }) ?? []
        where start.at <= date && start.at >= (latest?.at ?? .distantPast) {
            latest = start
        }
        return latest
    }
}
