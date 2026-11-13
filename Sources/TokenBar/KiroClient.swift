import Foundation
import SQLite3

/// A Kiro sign-in Token Bar reads credits for: the Kiro IDE's or the Kiro CLI's.
/// The file holding the sign-in is the account's key, as a folder is for Claude and Codex.
struct KiroSource: Hashable {
    let name: String
    let path: String
    let isCLI: Bool

    static let ide = KiroSource(name: "kiro", path: home + "/.aws/sso/cache/kiro-auth-token.json", isCLI: false)
    static let cli = KiroSource(name: "kiro-cli", path: home + "/Library/Application Support/kiro-cli/data.sqlite3", isCLI: true)
    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static var detected: [KiroSource] { [ide, cli].filter { FileManager.default.fileExists(atPath: $0.path) } }

    /// The Kiro user, read without a request: the Kiro CLI keeps it as `telemetryUserId`, the same ID usage readings name.
    /// The IDE keeps none, so its user comes from its last live reading.
    var localAccountID: String? {
        guard isCLI, let value = readCLIValue(at: path, "SELECT value FROM state WHERE key = 'telemetryUserId'") else { return nil }
        let id = (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)) as? String
        return id.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct KiroAccountSnapshot: Codable, Hashable, Identifiable {
    /// The sign-in file's path.
    var id: String
    var name: String
    var quota: ProviderSnapshot
    /// The Kiro user the last live reading named, which tells when the IDE and the CLI share an account.
    var accountID: String? = nil
}

/// Reads Kiro's monthly credits with the bearer token Kiro or the Kiro CLI saved.
/// Token Bar never renews that token: Kiro renews it when it next needs it, so a lapsed one means Kiro is not in use.
/// The Kiro IDE then still has the credits it last read in its own state, which a lapsed token falls back to.
struct KiroClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// A reading from the IDE's saved state carries the time Kiro took it in `lastSuccessAt`, and no user.
    func fetch(_ source: KiroSource) async throws -> (quota: ProviderSnapshot, accountID: String?) {
        let token = try await Task.detached(priority: .utility) { try readToken(source) }.value
        func lapsed() async throws -> (quota: ProviderSnapshot, accountID: String?) {
            if !source.isCLI, let cached = await Task.detached(priority: .utility, operation: readIDEUsageCache).value {
                return (cached, nil)
            }
            throw ClaudeClientError.authenticationExpired
        }
        guard token.expiresAt.map({ $0 > Date().addingTimeInterval(60) }) ?? true else { return try await lapsed() }
        // The CodeWhisperer endpoint both Kiro and the Kiro CLI call for usage limits; a Builder ID has no profile,
        // and a profile's ARN names its region in its fourth field, which Kiro prefers over the sign-in's.
        let arnRegion = token.profileArn.flatMap { arn in
            arn.split(separator: ":", omittingEmptySubsequences: false).dropFirst(3).first.map(String.init)
        }.flatMap { $0.range(of: #"^[a-z]{2}(-[a-z]+)+-\d$"#, options: .regularExpression) != nil ? $0 : nil }
        var components = URLComponents(string: "https://q.\(arnRegion ?? token.region).amazonaws.com/getUsageLimits")!
        components.queryItems = [
            URLQueryItem(name: "origin", value: source.isCLI ? "KIRO_CLI" : "AI_EDITOR"),
            URLQueryItem(name: "resourceType", value: "AGENTIC_REQUEST"),
        ] + (token.profileArn.map { [URLQueryItem(name: "profileArn", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("TokenBar", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeClientError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            let user = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["userInfo"] as? [String: Any]
            return (try parseKiroUsage(data), (user?["userId"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        // The server can end a token before its saved expiry, which lapses it all the same.
        case 401: return try await lapsed()
        case 403: throw ClaudeClientError.accessDenied
        case 429: throw ClaudeClientError.rateLimited(retryAfter: retryAfterInterval(from: http))
        default: throw ClaudeClientError.requestFailed("Kiro usage request returned HTTP \(http.statusCode).")
        }
    }
}

private struct KiroToken {
    let accessToken: String
    let expiresAt: Date?
    let region: String
    let profileArn: String?
}

private func readToken(_ source: KiroSource) throws -> KiroToken {
    let object: [String: Any]
    if source.isCLI {
        let query = "SELECT value FROM auth_kv WHERE key IN ('kirocli:odic:token', 'kirocli:social:token', 'kirocli:external-idp:token')"
        guard let value = readCLIValue(at: source.path, query),
              let parsed = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
        else { throw ClaudeClientError.requestFailed("Signed out of the Kiro CLI.") }
        object = parsed
    } else {
        guard let data = FileManager.default.contents(atPath: source.path),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ClaudeClientError.requestFailed("Signed out of Kiro.") }
        object = parsed
    }
    // The Kiro IDE writes camelCase keys and the Kiro CLI snake_case ones.
    func string(_ keys: String...) -> String? { keys.lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty } }
    guard let accessToken = string("accessToken", "access_token") else { throw ClaudeClientError.invalidResponse }
    let region = string("region") ?? "us-east-1"
    guard region.range(of: #"^[a-z]{2}(-[a-z]+)+-\d$"#, options: .regularExpression) != nil else {
        throw ClaudeClientError.invalidResponse
    }
    return KiroToken(
        accessToken: accessToken,
        expiresAt: string("expiresAt", "expires_at").flatMap(parseISO8601),
        region: region,
        profileArn: string("profileArn", "profile_arn")
    )
}

/// The first value a query reads from the Kiro CLI's database, which keeps its sign-in in `auth_kv`
/// under the key of whichever way it signed in.
private func readCLIValue(at path: String, _ query: String) -> String? {
    var connection: OpaquePointer?
    defer { sqlite3_close(connection) }
    guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    sqlite3_busy_timeout(connection, 1000)
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW
    else { return nil }
    return sqlite3_column_text(statement, 0).map { String(cString: $0) }
}

/// The usage the Kiro IDE last read, which it keeps in its VS Code state under `kiro.kiroAgent`, with ISO dates.
private func readIDEUsageCache() -> ProviderSnapshot? {
    let path = FileManager.default.homeDirectoryForCurrentUser.path
        + "/Library/Application Support/Kiro/User/globalStorage/state.vscdb"
    var connection: OpaquePointer?
    defer { sqlite3_close(connection) }
    guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    sqlite3_busy_timeout(connection, 1000)
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(connection, "SELECT value FROM ItemTable WHERE key = 'kiro.kiroAgent'", -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW,
          let value = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
          let root = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
          let state = root["kiro.resourceNotifications.usageState"] as? [String: Any],
          let breakdowns = state["usageBreakdowns"] as? [[String: Any]],
          let timestamp = (state["timestamp"] as? NSNumber)?.doubleValue
    else { return nil }
    let iso = { (value: Any?) in (value as? String).flatMap(parseISO8601) }
    var snapshot = try? kiroSnapshot(breakdowns.filter { ($0["type"] as? String ?? "CREDIT") == "CREDIT" }.map { item in
        KiroCredits(
            used: (item["currentUsage"] as? NSNumber)?.doubleValue, limit: (item["usageLimit"] as? NSNumber)?.doubleValue,
            resetsAt: iso(item["resetDate"]), trial: nil,
            bonuses: (item["bonuses"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "ACTIVE" }.map {
                (($0["currentUsage"] as? NSNumber)?.doubleValue ?? 0, ($0["usageLimit"] as? NSNumber)?.doubleValue ?? 0,
                 iso($0["expiryDate"]))
            }
        )
    })
    snapshot?.lastSuccessAt = Date(timeIntervalSince1970: timestamp / 1000)
    return snapshot
}

/// One credit breakdown, from either the usage endpoint or the IDE's saved state.
private struct KiroCredits {
    var used: Double?
    var limit: Double?
    var resetsAt: Date?
    var trial: (used: Double, limit: Double, ends: Date?)?
    var bonuses: [(used: Double, limit: Double, ends: Date?)]
}

/// The plan's monthly credits, any welcome trial and active bonus credits.
func parseKiroUsage(_ data: Data) throws -> ProviderSnapshot {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let breakdowns = root["usageBreakdownList"] as? [[String: Any]]
    else { throw ClaudeClientError.invalidResponse }
    func number(_ object: [String: Any]?, _ keys: String...) -> Double? {
        keys.lazy.compactMap { (object?[$0] as? NSNumber)?.doubleValue }.first
    }
    func date(_ object: [String: Any]?, _ key: String) -> Date? {
        number(object, key).map { Date(timeIntervalSince1970: $0) }
    }
    return try kiroSnapshot(breakdowns.filter { ($0["resourceType"] as? String ?? "CREDIT") == "CREDIT" }.map { item in
        let trial = (item["freeTrialInfo"] as? [String: Any]).flatMap { trial in
            trial["freeTrialStatus"] as? String == "ACTIVE" ? trial : nil
        }
        return KiroCredits(
            used: number(item, "currentUsageWithPrecision", "currentUsage"),
            limit: number(item, "usageLimitWithPrecision", "usageLimit"),
            resetsAt: date(item, "nextDateReset") ?? date(root, "nextDateReset"),
            trial: trial.map {
                (number($0, "currentUsageWithPrecision", "currentUsage") ?? 0,
                 number($0, "usageLimitWithPrecision", "usageLimit") ?? 0, date($0, "freeTrialExpiry"))
            },
            bonuses: (item["bonuses"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "ACTIVE" }.map {
                (number($0, "currentUsage") ?? 0, number($0, "usageLimit") ?? 0, date($0, "expiresAt"))
            }
        )
    })
}

/// Every credit pool in one `Credits` window, plan, trial and bonus, since Kiro spends them as one balance;
/// it resets with the plan, and its hover lists each pool.
private func kiroSnapshot(_ items: [KiroCredits]) throws -> ProviderSnapshot {
    func amount(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
    var used = 0.0, limit = 0.0, resetsAt: Date?, ends: Date?
    var lines: [String] = []
    func add(_ name: String, _ poolUsed: Double, _ poolLimit: Double, _ verb: String, _ date: Date?) {
        guard poolLimit > 0 else { return }
        used += poolUsed
        limit += poolLimit
        lines.append("\(name): \(amount(poolUsed)) of \(amount(poolLimit))"
            + (date.map { " · \(verb) " + $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""))
    }
    for item in items {
        if let planUsed = item.used, let planLimit = item.limit {
            add("Plan", planUsed, planLimit, "resets", item.resetsAt)
            resetsAt = resetsAt ?? item.resetsAt
        }
        if let trial = item.trial {
            add("Trial", trial.used, trial.limit, "expires", trial.ends)
            ends = [ends, trial.ends].compactMap { $0 }.min()
        }
        for bonus in item.bonuses {
            add("Bonus", bonus.used, bonus.limit, "expires", bonus.ends)
            ends = [ends, bonus.ends].compactMap { $0 }.min()
        }
    }
    guard limit > 0 else { throw ClaudeClientError.invalidResponse }
    let window = LimitWindow(
        label: "Credits", usedPercent: min(100, max(0, used / limit * 100)), windowMinutes: nil,
        resetsAt: resetsAt ?? ends, limitID: "kiro:credit", limitName: "Credits", amounts: lines.joined(separator: "\n")
    )
    return ProviderSnapshot(connected: true, shortWindow: nil, longWindow: nil, extraWindows: [window], error: nil)
}
