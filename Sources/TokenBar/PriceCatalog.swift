import Foundation

struct PriceCatalog {
    private enum SourceKind {
        case openAI
        case claude
        case fallback
    }

    private let maxAge: TimeInterval = 24 * 60 * 60
    private let retryCooldown: TimeInterval = 60
    private let openAIURL = "https://developers.openai.com/api/docs/pricing.md"
    private let claudeURL = "https://platform.claude.com/docs/en/about-claude/pricing.md"
    private let defaultFallbackURL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func costMix(for ledger: MixLedger) async -> CostMix {
        await costLedger(for: ledger).overall
    }

    func costLedger(for ledger: MixLedger) async -> CostLedger {
        let observedModels = Set(ledger.byModel.keys)
        guard !observedModels.isEmpty else { return .empty }

        var cache = loadCache()
        cache = await refreshed(cache, requiredModels: observedModels)
        let prices = mergedPrices(from: cache)
        return CostLedger(byDay: ledger.byDayAndModel.mapValues { models in
            pricedMix(for: models, prices: prices)
        })
    }

    private func pricedMix(
        for models: [String: TokenBreakdown],
        prices: [String: ModelPrice]
    ) -> CostMix {

        var sampledTokens: Int64 = 0
        var sampledCost = 0.0
        var missingModels: [String] = []
        var unpricedTokens: Int64 = 0

        for (model, tokens) in models {
            guard let price = resolvePrice(for: model, in: prices) else {
                missingModels.append(model)
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
            sampledCost += Double(tokens.input) * price.inputPerToken
            sampledCost += Double(cacheCreation5m + unsplitCacheCreation)
                * price.cacheCreationInputPerToken
            sampledCost += Double(cacheCreation1h)
                * (price.cacheCreationInput1hPerToken ?? price.cacheCreationInputPerToken)
            sampledCost += Double(tokens.cachedInput) * price.cachedInputPerToken
            sampledCost += Double(tokens.output) * price.outputPerToken
            sampledCost += Double(tokens.reasoning) * price.reasoningPerToken
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
            sourceURL: openAIURL,
            kind: .openAI
        )
        async let claude = refreshedSource(
            existing.claude,
            requiredModels: claudeModels,
            sourceURL: claudeURL,
            kind: .claude
        )
        async let fallback = refreshedSource(
            existing.fallback,
            requiredModels: canonicalModels,
            sourceURL: configuredFallbackURL(),
            kind: .fallback
        )

        let updated = await PriceCache(
            openAI: openAI,
            claude: claude,
            fallback: fallback
        )
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
        let missing = requiredModels.filter { resolvePrice(for: $0, in: existing.models) == nil }
        let checkedModels = Set(existing.checkedModels ?? [])
        let uncheckedMissing = Set(missing).subtracting(checkedModels)
        let stale = Date().timeIntervalSince(existing.fetchedAt) >= maxAge
        let needsRefresh = stale || sourceChanged || !uncheckedMissing.isEmpty
        let recentlyAttempted = existing.lastAttemptAt.map {
            Date().timeIntervalSince($0) < retryCooldown
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

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return recordAttempt(existing)
            }
            if http.statusCode == 304 {
                var updated = existing
                updated.fetchedAt = Date()
                updated.sourceURL = sourceURL
                updated.checkedModels = checkedModels.union(requiredModels).sorted()
                updated.lastAttemptAt = Date()
                return updated
            }
            guard (200..<300).contains(http.statusCode),
                  let models = parsedModels(data, kind: kind, requiredModels: requiredModels),
                  !models.isEmpty else {
                return recordAttempt(existing)
            }

            return PriceSourceCache(
                fetchedAt: Date(),
                etag: http.value(forHTTPHeaderField: "ETag"),
                models: models,
                sourceURL: sourceURL,
                checkedModels: sourceChanged
                    ? requiredModels.sorted()
                    : checkedModels.union(requiredModels).sorted(),
                lastAttemptAt: Date()
            )
        } catch {
            return recordAttempt(existing)
        }
    }

    private func configuredFallbackURL() -> String {
        let environment = ProcessInfo.processInfo.environment
        return environment["TOKENBAR_PRICE_URL"]
            ?? defaultFallbackURL
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

    private func parseOpenAIPrices(_ markdown: String) -> [String: ModelPrice] {
        let rows = markdownTableRows(in: markdown, after: "### Standard pricing data")
        let expectedHeader = [
            "model",
            "short context input",
            "short context cached input",
            "short context cache writes",
            "short context output"
        ]
        guard rows.count > 1,
              header(rows[0], startsWith: expectedHeader) else {
            return [:]
        }

        var prices: [String: ModelPrice] = [:]
        for cells in rows.dropFirst() where cells.count >= 5 && !isTableSeparator(cells) {
            let model = normalize(plainModelName(cells[0]))
            guard !model.isEmpty,
                  let input = pricePerToken(cells[1]),
                  let output = pricePerToken(cells[4]) else {
                continue
            }
            prices[model] = ModelPrice(
                inputPerToken: input,
                cacheCreationInputPerToken: pricePerToken(cells[3]) ?? input,
                cacheCreationInput1hPerToken: nil,
                cachedInputPerToken: pricePerToken(cells[2]) ?? input,
                outputPerToken: output,
                reasoningPerToken: output
            )
        }
        return prices.count >= 3 ? prices : [:]
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
        return prices.count >= 3 ? prices : [:]
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

    private func markdownTableRows(in markdown: String, after heading: String) -> [[String]] {
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
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                foundTable = true
                let body = trimmed.dropFirst().dropLast()
                rows.append(
                    body.split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                )
            } else if foundTable {
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

    private func resolvePrice(for model: String, in prices: [String: ModelPrice]) -> ModelPrice? {
        let canonical = normalize(model)
        if let exact = prices[canonical] { return exact }
        return prices.keys
            .filter { key in
                canonical.hasPrefix("\(key)-")
                    && isVersionSuffix(String(canonical.dropFirst(key.count + 1)))
            }
            .sorted { $0.count > $1.count }
            .first
            .flatMap { prices[$0] }
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
        if let data = defaults.data(forKey: StorageKeys.priceCache),
           let cache = try? JSONDecoder().decode(PriceCache.self, from: data) {
            return cache
        }
        return .empty
    }

    private func save(_ cache: PriceCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: StorageKeys.priceCache)
    }

    private func recordAttempt(_ existing: PriceSourceCache) -> PriceSourceCache {
        var attempted = existing
        attempted.lastAttemptAt = Date()
        return attempted
    }
}
