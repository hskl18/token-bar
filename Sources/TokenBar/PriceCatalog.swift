import Foundation

final class PriceCatalog {
    private enum SourceKind: String {
        case openAI = "OpenAI"
        case claude = "Claude"
        case fallback = "Fallback"
    }

    private let maxAge: TimeInterval = 24 * 60 * 60
    private let retryCooldown: TimeInterval = 60
    static let openAIURL = "https://developers.openai.com/api/docs/pricing.md"
    static let claudeURL = "https://platform.claude.com/docs/en/about-claude/pricing.md"
    static let defaultFallbackURL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    private let defaults: UserDefaults
    private var cachedPrices: PriceCache?
    private var cachedHistory: [String: [String: ModelPrice]]?
    private var refreshErrors: [SourceKind: String] = [:]

    var refreshWarning: String? {
        let messages = refreshErrors.map { "\($0.key.rawValue) prices: \($0.value)" }.sorted()
        return messages.isEmpty ? nil : messages.joined(separator: "; ")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func costMix(for ledger: MixLedger) async -> CostMix {
        await costLedger(for: ledger).overall
    }

    func costLedger(for ledger: MixLedger) async -> CostLedger {
        let observedModels = Set(ledger.byModel.keys.map { UsagePriceKey.model($0) + UsagePriceKey.speed($0) })
        guard !observedModels.isEmpty else { return .empty }

        var cache = loadCache()
        cache = await refreshed(cache, requiredModels: observedModels)
        let prices = mergedPrices(from: cache)
        let oldHistory = cachedHistory ?? defaults.data(forKey: StorageKeys.priceHistory).flatMap {
            try? JSONDecoder().decode([String: [String: ModelPrice]].self, from: $0)
        } ?? [:]
        var history = oldHistory
        var byDay: [String: CostMix] = [:]
        for (day, models) in ledger.byDayAndModel {
            var dayPrices = history[day] ?? [:]
            // Tier rows resolve through the model's Standard row, so freeze both.
            for usageKey in models.keys {
                let rows = [UsagePriceKey.model(usageKey), usageKey].compactMap { resolvedPrice(for: $0, in: prices) }
                for (key, resolved) in rows where dayPrices[key] == nil { dayPrices[key] = resolved }
            }
            history[day] = dayPrices
            byDay[day] = pricedMix(for: models, prices: dayPrices, currentPrices: prices)
        }
        let retainedDays = Set(history.keys.sorted().suffix(400))
        history = history.filter { retainedDays.contains($0.key) }
        cachedHistory = history
        if history != oldHistory, let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: StorageKeys.priceHistory)
        }
        return CostLedger(byDay: byDay)
    }

    private func pricedMix(
        for models: [String: TokenBreakdown],
        prices: [String: ModelPrice],
        currentPrices: [String: ModelPrice]
    ) -> CostMix {

        var sampledTokens: Int64 = 0
        var sampledCost = 0.0
        var missingModels: [String] = []
        var unpricedTokens: Int64 = 0

        for (model, tokens) in models {
            guard var price = resolvedPrice(for: model, in: prices)?.price else {
                missingModels.append(model)
                unpricedTokens += tokens.total
                continue
            }
            if model.contains("|long"), let input = price.longContextInputPerToken,
               let cached = price.longContextCachedInputPerToken,
               let writes = price.longContextCacheCreationInputPerToken,
               let output = price.longContextOutputPerToken {
                price.inputPerToken = input
                price.cachedInputPerToken = cached
                price.cacheCreationInputPerToken = writes
                price.cacheCreationInput12hPerToken = price.longContextCacheCreationInput12hPerToken
                price.outputPerToken = output
                price.reasoningPerToken = output
            }
            // Codex logs a write total without its lifetime; do not invent a 30m/12h split.
            let published = resolvedPrice(for: model, in: currentPrices)?.price
            let publishedExtendedWrite = model.contains("|long")
                ? published?.longContextCacheCreationInput12hPerToken : published?.cacheCreationInput12hPerToken
            if !isClaudeModel(normalize(UsagePriceKey.model(model))), tokens.cacheCreationInput > 0,
               let extendedWrite = price.cacheCreationInput12hPerToken ?? publishedExtendedWrite,
               extendedWrite != price.cacheCreationInputPerToken {
                missingModels.append(model + " (cache-write lifetime unknown)")
                unpricedTokens += tokens.total
                continue
            }
            let cacheCreation5m = tokens.cacheCreationInput5m ?? 0
            let cacheCreation1h = tokens.cacheCreationInput1h ?? 0
            let unsplitCacheCreation = max(
                0,
                tokens.cacheCreationInput - cacheCreation5m - cacheCreation1h
            )
            sampledTokens += tokens.total
            var cost = Double(tokens.input) * price.inputPerToken
            cost += Double(cacheCreation5m + unsplitCacheCreation)
                * price.cacheCreationInputPerToken
            cost += Double(cacheCreation1h)
                * (price.cacheCreationInput1hPerToken ?? price.cacheCreationInputPerToken)
            cost += Double(tokens.cachedInput) * price.cachedInputPerToken
            cost += Double(tokens.output) * price.outputPerToken
            cost += Double(tokens.reasoning) * price.reasoningPerToken
            sampledCost += cost
        }

        return CostMix(
            sampledTokens: sampledTokens,
            usdPerToken: sampledTokens > 0 ? sampledCost / Double(sampledTokens) : nil,
            missingModels: missingModels.sorted(),
            unpricedTokens: unpricedTokens
        )
    }

    private func refreshed(
        _ existing: PriceCache,
        requiredModels: Set<String>
    ) async -> PriceCache {
        let canonicalModels = Set(requiredModels.map(normalize))
        let openAIModels = canonicalModels.filter { !isClaudeModel($0) }
        let claudeModels = canonicalModels.filter(isClaudeModel)

        async let openAI = refreshedSource(
            existing.openAI,
            requiredModels: openAIModels,
            sourceURL: Self.openAIURL,
            kind: .openAI
        )
        async let claude = refreshedSource(
            existing.claude,
            requiredModels: claudeModels,
            sourceURL: Self.claudeURL,
            kind: .claude
        )
        let (openAIPrices, claudePrices) = await (openAI, claude)
        let missingModels = canonicalModels.filter {
            resolvedPrice(for: $0, in: openAIPrices.models) == nil
                && resolvedPrice(for: $0, in: claudePrices.models) == nil
        }
        let fallback = await refreshedSource(
            existing.fallback,
            requiredModels: missingModels,
            sourceURL: configuredFallbackURL(),
            kind: .fallback
        )

        let updated = PriceCache(
            openAI: openAIPrices,
            claude: claudePrices,
            fallback: fallback
        )
        for (kind, source, required) in [
            (SourceKind.openAI, openAIPrices, openAIModels),
            (.claude, claudePrices, claudeModels),
            (.fallback, fallback, missingModels)
        ] where !required.isEmpty {
            refreshErrors[kind] = source.refreshError
        }
        save(updated)
        return updated
    }

    private func refreshedSource(
        _ existing: PriceSourceCache,
        requiredModels: Set<String>,
        sourceURL: String,
        kind: SourceKind
    ) async -> PriceSourceCache {
        guard !requiredModels.isEmpty else { return existing }

        let sourceChanged = existing.sourceURL != sourceURL
        let missing = requiredModels.filter { resolvedPrice(for: $0, in: existing.models) == nil }
        let checkedModels = Set(existing.checkedModels ?? [])
        let uncheckedMissing = Set(missing).subtracting(checkedModels)
        let stale = Date().timeIntervalSince(existing.fetchedAt) >= (kind == .fallback ? 7 * maxAge : maxAge)
        let needsRefresh = stale || sourceChanged || !uncheckedMissing.isEmpty
        let recentlyAttempted = existing.lastAttemptAt.map {
            Date().timeIntervalSince($0) < (existing.refreshError == nil ? retryCooldown : 15 * 60)
        } ?? false
        guard needsRefresh, !recentlyAttempted else { return existing }

        guard let url = URL(string: sourceURL) else { return existing }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(kind == .fallback ? "application/json" : "text/markdown", forHTTPHeaderField: "Accept")
        if uncheckedMissing.isEmpty,
           !sourceChanged,
           let etag = existing.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return recordAttempt(existing, error: "Unrecognized response; using saved rates.")
            }
            if http.statusCode == 304 {
                var updated = existing
                updated.fetchedAt = Date()
                updated.sourceURL = sourceURL
                updated.checkedModels = checkedModels.union(requiredModels).sorted()
                updated.lastAttemptAt = Date()
                updated.refreshError = nil
                return updated
            }
            guard (200..<300).contains(http.statusCode) else {
                return recordAttempt(existing, error: "HTTP \(http.statusCode); using saved rates.")
            }
            guard let models = parsedModels(data, kind: kind, requiredModels: requiredModels),
                  !models.isEmpty else {
                return recordAttempt(existing, error: "Price table could not be read; using saved rates.")
            }

            return PriceSourceCache(
                fetchedAt: Date(),
                etag: http.value(forHTTPHeaderField: "ETag"),
                models: kind == .fallback && !sourceChanged
                    ? existing.models.merging(models) { _, updated in updated } : models,
                sourceURL: sourceURL,
                checkedModels: sourceChanged
                    ? requiredModels.sorted()
                    : checkedModels.union(requiredModels).sorted(),
                lastAttemptAt: Date()
            )
        } catch {
            return recordAttempt(existing, error: "Refresh failed; using saved rates.")
        }
    }

    private func configuredFallbackURL() -> String {
        let environment = ProcessInfo.processInfo.environment
        return environment["TOKENBAR_PRICE_URL"]
            ?? Self.defaultFallbackURL
    }

    private func parsedModels(
        _ data: Data,
        kind: SourceKind,
        requiredModels: Set<String>
    ) -> [String: ModelPrice]? {
        switch kind {
        case .openAI:
            guard let markdown = String(data: data, encoding: .utf8) else { return nil }
            return parseOpenAIPrices(markdown)
        case .claude:
            guard let markdown = String(data: data, encoding: .utf8) else { return nil }
            return parseClaudePrices(markdown)
        case .fallback:
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            var selected: [String: ModelPrice] = [:]
            for model in requiredModels {
                if let match = findFallbackPrice(for: model, in: root) {
                    selected[model] = match
                }
            }
            return selected
        }
    }

    private func findFallbackPrice(for model: String, in catalog: [String: Any]) -> ModelPrice? {
        let normalized = normalize(model)
        let preferredKeys = [model, normalized, "openai/\(normalized)"]

        for key in preferredKeys {
            if let row = catalog[key] as? [String: Any], let price = parsePrice(row) {
                return price
            }
        }

        let matchingKeys = catalog.keys
            .filter { key in
                normalize(key) == normalized
            }
            .sorted { $0.count < $1.count }
        for key in matchingKeys {
            if let row = catalog[key] as? [String: Any], let price = parsePrice(row) {
                return price
            }
        }
        return nil
    }

    func parseOpenAIPrices(_ markdown: String) -> [String: ModelPrice] {
        var prices = openAITable(in: markdown, after: "### Standard pricing data")
        guard prices.count >= 3 else { return [:] }
        for (heading, speed) in [("### Fast pricing data", "|fast"), ("### Ultrafast pricing data", "|ultrafast")] {
            for (model, price) in openAITable(in: markdown, after: heading) {
                prices[model + speed] = price
            }
        }
        return prices
    }

    private func openAITable(in markdown: String, after heading: String) -> [String: ModelPrice] {
        var prices: [String: ModelPrice] = [:]
        var columns: [String] = []
        for cells in markdownTableRows(in: markdown, after: heading, allTables: true) {
            if normalizedHeader(cells[0]) == "model" {
                columns = cells.map(normalizedHeader)
                continue
            }
            guard cells.count == columns.count, !isTableSeparator(cells) else { continue }
            func rate(_ names: String...) -> Double? {
                for name in names {
                    if let index = columns.firstIndex(of: name), let value = pricePerToken(cells[index]) {
                        return value
                    }
                }
                return nil
            }
            guard let modelIndex = columns.firstIndex(of: "model") else { continue }
            let model = normalize(plainModelName(cells[modelIndex]))
            guard !model.isEmpty,
                  let input = rate("short context input", "input"),
                  let output = rate("short context output", "output") else {
                continue
            }
            let longInput = rate("long context input")
            prices[model] = ModelPrice(
                inputPerToken: input,
                cacheCreationInputPerToken: rate("short context 30m write", "short context cache writes") ?? input,
                cacheCreationInput1hPerToken: nil,
                cachedInputPerToken: rate("short context cached input", "cached input") ?? input,
                outputPerToken: output,
                reasoningPerToken: output,
                longContextInputPerToken: longInput,
                longContextCachedInputPerToken: rate("long context cached input") ?? longInput,
                longContextCacheCreationInputPerToken: rate("long context 30m write", "long context cache writes") ?? longInput,
                longContextOutputPerToken: rate("long context output"),
                cacheCreationInput12hPerToken: rate("short context 12h write"),
                longContextCacheCreationInput12hPerToken: rate("long context 12h write")
            )
        }
        return prices
    }

    private func parseClaudePrices(_ markdown: String) -> [String: ModelPrice] {
        let rows = markdownTableRows(in: markdown, after: "## Model pricing")
        let expectedHeader = [
            "model",
            "base input tokens",
            "5m cache writes",
            "1h cache writes",
            "cache hits and refreshes",
            "output tokens"
        ]
        guard rows.count > 1,
              header(rows[0], startsWith: expectedHeader) else {
            return [:]
        }

        var prices: [String: ModelPrice] = [:]
        for cells in rows.dropFirst() where cells.count >= 6 && !isTableSeparator(cells) {
            let model = slugify(plainModelName(cells[0]))
            guard model.hasPrefix("claude-"),
                  let input = pricePerToken(cells[1]),
                  let output = pricePerToken(cells[5]) else {
                continue
            }
            prices[model] = ModelPrice(
                inputPerToken: input,
                cacheCreationInputPerToken: pricePerToken(cells[2]) ?? input,
                cacheCreationInput1hPerToken: pricePerToken(cells[3]),
                cachedInputPerToken: pricePerToken(cells[4]) ?? input,
                outputPerToken: output,
                reasoningPerToken: output
            )
        }
        guard prices.count >= 3 else { return [:] }

        // Claude applies prompt-caching multipliers on top of fast rates, so cache rates scale with input.
        let fastRows = markdownTableRows(in: markdown, after: "### Fast mode pricing")
        guard fastRows.count > 1, header(fastRows[0], startsWith: ["model", "input", "output"]) else {
            return prices
        }
        for cells in fastRows.dropFirst() where cells.count >= 3 && !isTableSeparator(cells) {
            guard let input = pricePerToken(cells[1]), let output = pricePerToken(cells[2]) else { continue }
            for name in cells[0].split(separator: "/") {
                let model = slugify(plainModelName(String(name)))
                guard var price = prices[model] else { continue }
                let ratio = input / price.inputPerToken
                price.cacheCreationInputPerToken *= ratio
                price.cacheCreationInput1hPerToken = price.cacheCreationInput1hPerToken.map { $0 * ratio }
                price.cachedInputPerToken *= ratio
                price.inputPerToken = input
                price.outputPerToken = output
                price.reasoningPerToken = output
                prices[model + "|fast"] = price
            }
        }
        return prices
    }

    private func header(_ cells: [String], startsWith expected: [String]) -> Bool {
        guard cells.count >= expected.count else { return false }
        return zip(cells, expected).allSatisfy { actual, expectedValue in
            normalizedHeader(actual) == expectedValue
        }
    }

    private func normalizedHeader(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " & ", with: " and ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func markdownTableRows(in markdown: String, after heading: String, allTables: Bool = false) -> [[String]] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headingIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == heading
        }) else {
            return []
        }

        var rows: [[String]] = []
        var foundTable = false
        for line in lines.dropFirst(headingIndex + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if allTables, trimmed.hasPrefix("#") { break }
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                foundTable = true
                let body = trimmed.dropFirst().dropLast()
                rows.append(
                    body.split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                )
            } else if foundTable && !allTables {
                break
            }
        }
        return rows
    }

    private func isTableSeparator(_ cells: [String]) -> Bool {
        cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && value.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private func plainModelName(_ cell: String) -> String {
        var value = cell
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["),
           let closingBracket = value.firstIndex(of: "]") {
            value = String(value[value.index(after: value.startIndex)..<closingBracket])
        }
        if let parenthesis = value.range(of: " (") {
            value = String(value[..<parenthesis.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pricePerToken(_ cell: String) -> Double? {
        guard let dollar = cell.firstIndex(of: "$") else { return nil }
        let tail = cell[cell.index(after: dollar)...].drop(while: { $0.isWhitespace })
        let numberText = tail.prefix { $0.isNumber || $0 == "." || $0 == "," }
            .replacingOccurrences(of: ",", with: "")
        guard let perMillion = Double(numberText) else { return nil }
        return perMillion / 1_000_000
    }

    private func slugify(_ value: String) -> String {
        var result = ""
        var pendingSeparator = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSeparator, !result.isEmpty { result.append("-") }
                result.append(String(scalar))
                pendingSeparator = false
            } else {
                pendingSeparator = true
            }
        }
        return result
    }

    private func parsePrice(_ value: [String: Any]) -> ModelPrice? {
        guard let input = number(value["input_cost_per_token"]),
              let output = number(value["output_cost_per_token"])
        else {
            return nil
        }
        return ModelPrice(
            inputPerToken: input,
            cacheCreationInputPerToken: number(value["cache_creation_input_token_cost"]) ?? input,
            cacheCreationInput1hPerToken: number(
                value["cache_creation_input_token_cost_above_1hr"]
            ),
            cachedInputPerToken: number(value["cache_read_input_token_cost"]) ?? input,
            outputPerToken: output,
            reasoningPerToken: number(value["output_cost_per_reasoning_token"]) ?? output
        )
    }

    // A speed tier without a published rate stays unpriced rather than borrowing the Standard rate.
    private func resolvedPrice(
        for usageKey: String,
        in prices: [String: ModelPrice]
    ) -> (key: String, price: ModelPrice)? {
        guard let base = priceKey(for: UsagePriceKey.model(usageKey), in: prices) else { return nil }
        let key = base + UsagePriceKey.speed(usageKey)
        return prices[key].map { (key, $0) }
    }

    private func priceKey(for model: String, in prices: [String: ModelPrice]) -> String? {
        let canonical = normalize(model)
        if prices[canonical] != nil { return canonical }
        return prices.keys
            .filter { key in
                canonical.hasPrefix("\(key)-")
                    && isVersionSuffix(String(canonical.dropFirst(key.count + 1)))
            }
            .max { $0.count < $1.count }
    }

    private func isVersionSuffix(_ value: String) -> Bool {
        let compactDate = value.prefix(8)
        if compactDate.count == 8, compactDate.allSatisfy(\.isNumber) {
            return true
        }
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        return components.count >= 3
            && components[0].count == 4
            && components[1].count == 2
            && components[2].count == 2
            && components[0].allSatisfy(\.isNumber)
            && components[1].allSatisfy(\.isNumber)
            && components[2].allSatisfy(\.isNumber)
    }

    private func isClaudeModel(_ model: String) -> Bool {
        model.hasPrefix("claude-")
    }

    private func mergedPrices(from cache: PriceCache) -> [String: ModelPrice] {
        var prices = cache.fallback.models
        prices.merge(cache.openAI.models) { _, official in official }
        prices.merge(cache.claude.models) { _, official in official }
        return prices
    }

    private func normalize(_ model: String) -> String {
        var value = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["openai/", "responses/"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        // OpenAI's model page maps Daybreak Blue to GPT-5.6 Sol, and its Codex rate
        // card says Auto Review uses GPT-5.4.
        if value == "gpt-daybreak-blue-latest" || value == "daybreak-blue-latest" {
            return "gpt-5.6-sol"
        }
        if value == "codex-auto-review" {
            return "gpt-5.4"
        }
        if value == "gpt-5.6" {
            return "gpt-5.6-sol"
        }
        return value
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private func loadCache() -> PriceCache {
        if let cachedPrices { return cachedPrices }
        if let data = defaults.data(forKey: StorageKeys.priceCache),
           let cache = try? JSONDecoder().decode(PriceCache.self, from: data) {
            cachedPrices = cache
            return cache
        }
        return .empty
    }

    private func save(_ cache: PriceCache) {
        guard cache != cachedPrices else { return }
        cachedPrices = cache
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: StorageKeys.priceCache)
    }

    private func recordAttempt(_ existing: PriceSourceCache, error: String) -> PriceSourceCache {
        var attempted = existing
        attempted.lastAttemptAt = Date()
        attempted.refreshError = error
        return attempted
    }
}
