import Foundation

struct CodexTranscriptEvent {
    var date: Date
    var day: String
    var model: String
    var breakdown: TokenBreakdown
    var identity: String
}

struct CodexTranscriptParseResult {
    var event: CodexTranscriptEvent?
    var malformed: Bool

    static let ignored = CodexTranscriptParseResult(event: nil, malformed: false)
    static let malformed = CodexTranscriptParseResult(event: nil, malformed: true)
}

struct CodexTranscriptParser {
    func parse(
        _ line: Data,
        path: String,
        cursor: inout CodexWindowCursor
    ) -> CodexTranscriptParseResult {
        guard isRelevantPrefix(line.prefix(1024)) else { return .ignored }
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let root = object as? [String: Any]
        else {
            return .malformed
        }
        guard let type = root["type"] as? String else { return .ignored }
        let payload = root["payload"] as? [String: Any]

        if type == "session_meta" {
            if cursor.sawSessionMeta != true {
                cursor.sawSessionMeta = true
                if let id = nonEmpty(payload?["id"] as? String) {
                    cursor.logicalSessionKey = "codex-session:\(id)"
                }
                if isFork(payload: payload) {
                    cursor.suppressingForkCopies = true
                    cursor.forkCopyAnchor = (root["timestamp"] as? String).flatMap(Self.parseDate)
                }
            }
            return .ignored
        }
        if type == "turn_context" {
            cursor.model = modelName(payload: payload) ?? cursor.model
            return .ignored
        }
        guard type == "event_msg", payload?["type"] as? String == "token_count" else {
            return .ignored
        }

        let info = payload?["info"] as? [String: Any]
        guard let totalRaw = info?["total_token_usage"] as? [String: Any],
              let total = tokenTotals(totalRaw)
        else {
            return .ignored
        }
        if cursor.previousTotal == total { return .ignored }

        let delta: TokenTotals
        if let lastRaw = info?["last_token_usage"] as? [String: Any],
           let last = tokenTotals(lastRaw) {
            delta = last
        } else if let previous = cursor.previousTotal {
            delta = subtract(total, previous)
        } else {
            delta = total
        }
        cursor.previousTotal = total
        guard !isEmpty(delta) else { return .ignored }

        guard let timestamp = root["timestamp"] as? String,
              let date = Self.parseDate(timestamp)
        else {
            return .malformed
        }

        if cursor.suppressingForkCopies == true {
            if let anchor = cursor.forkCopyAnchor,
               date.timeIntervalSince(anchor) > 1 {
                cursor.suppressingForkCopies = false
                cursor.forkCopyAnchor = nil
            } else {
                cursor.forkCopyAnchor = date
                return .ignored
            }
        }

        let model = modelName(payload: payload) ?? cursor.model ?? "unknown-model"
        cursor.model = model
        let identity = usageIdentity(
            path: path,
            logicalSessionKey: cursor.logicalSessionKey,
            model: model,
            total: total,
            delta: delta
        )
        return CodexTranscriptParseResult(
            event: CodexTranscriptEvent(
                date: date,
                day: Self.localDayFormatter.string(from: date),
                model: model,
                breakdown: normalizedBreakdown(delta),
                identity: identity
            ),
            malformed: false
        )
    }

    func isRelevantPrefix(_ prefix: Data.SubSequence) -> Bool {
        prefix.range(of: Self.sessionMetaMarker) != nil
            || prefix.range(of: Self.turnContextMarker) != nil
            || prefix.range(of: Self.tokenCountMarker) != nil
    }

    func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private func isFork(payload: [String: Any]?) -> Bool {
        if nonEmpty(payload?["forked_from_id"] as? String) != nil
            || nonEmpty(payload?["parent_thread_id"] as? String) != nil {
            return true
        }
        guard let source = payload?["source"] as? [String: Any],
              let subagent = source["subagent"] as? [String: Any],
              let spawn = subagent["thread_spawn"] as? [String: Any]
        else {
            return false
        }
        return nonEmpty(spawn["parent_thread_id"] as? String) != nil
    }

    private func modelName(payload: [String: Any]?) -> String? {
        let info = payload?["info"] as? [String: Any]
        let metadata = info?["metadata"] as? [String: Any]
        return [
            info?["model"] as? String,
            info?["model_name"] as? String,
            metadata?["model"] as? String,
            payload?["model"] as? String,
        ].compactMap(nonEmpty).first
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func tokenTotals(_ value: [String: Any]) -> TokenTotals? {
        let input = int64(value["input_tokens"])
        let output = int64(value["output_tokens"])
        let total = int64(value["total_tokens"])
        guard input != nil || output != nil || total != nil else { return nil }
        return TokenTotals(
            input: input ?? 0,
            cachedInput: int64(value["cached_input_tokens"])
                ?? int64(value["cache_read_input_tokens"])
                ?? 0,
            output: output ?? 0,
            reasoning: int64(value["reasoning_output_tokens"]) ?? 0,
            total: total ?? 0
        )
    }

    private func subtract(_ value: TokenTotals, _ previous: TokenTotals) -> TokenTotals {
        TokenTotals(
            input: max(0, value.input - previous.input),
            cachedInput: max(0, value.cachedInput - previous.cachedInput),
            output: max(0, value.output - previous.output),
            reasoning: max(0, value.reasoning - previous.reasoning),
            total: max(0, value.total - previous.total)
        )
    }

    private func isEmpty(_ totals: TokenTotals) -> Bool {
        totals.input == 0
            && totals.cachedInput == 0
            && totals.output == 0
            && totals.reasoning == 0
    }

    private func normalizedBreakdown(_ totals: TokenTotals) -> TokenBreakdown {
        TokenBreakdown(
            input: max(0, totals.input - totals.cachedInput),
            cacheCreationInput: 0,
            cachedInput: max(0, totals.cachedInput),
            output: max(0, totals.output - totals.reasoning),
            reasoning: max(0, totals.reasoning)
        )
    }

    private func usageIdentity(
        path: String,
        logicalSessionKey: String,
        model: String,
        total: TokenTotals,
        delta: TokenTotals
    ) -> String {
        let prefix = total == delta ? "codex-token-count" : "source-wide:codex-token-count"
        let message = "\(prefix):\(logicalSessionKey):\(model):"
            + "total=\(vector(total)):delta=\(vector(delta))"
        return total == delta ? "\(path)|\(message)" : message
    }

    private func vector(_ value: TokenTotals) -> String {
        [value.input, value.cachedInput, value.output, value.reasoning, value.total]
            .map(String.init)
            .joined(separator: ",")
    }

    private func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        fractionalDateFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let localDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let sessionMetaMarker = Data(#""type":"session_meta""#.utf8)
    private static let turnContextMarker = Data(#""type":"turn_context""#.utf8)
    private static let tokenCountMarker = Data(#""type":"token_count""#.utf8)
}
