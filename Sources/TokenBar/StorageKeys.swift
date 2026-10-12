enum StorageKeys {
    static let snapshot = "tokenbar.snapshot.v1"
    static let claudeLedger = "tokenbar.claude-ledger.v6"
    static let claudeWindowLedger = "tokenbar.claude-window-ledger.v6"
    static let codexUsageLedger = "tokenbar.codex-usage-ledger.v6"
    static let codexWindowLedger = "tokenbar.codex-window-ledger.v8"
    static let codexLastKnownMix = "tokenbar.codex-last-known-mix.v4"
    static let codexRuntimeExecutable = "tokenbar.codex-runtime-executable.v1"
    static let priceCache = "tokenbar.price-cache.v7"
    static let priceHistory = "tokenbar.price-history.v1"
    static let imageGenerationUsage = "tokenbar.image-generation-usage.v2"

    static let active: Set<String> = [
        snapshot,
        claudeLedger,
        claudeWindowLedger,
        codexUsageLedger,
        codexWindowLedger,
        codexLastKnownMix,
        codexRuntimeExecutable,
        priceCache,
        priceHistory,
        imageGenerationUsage,
    ]

    static let profileWindowLedgers = [claudeWindowLedger, codexWindowLedger]

    /// An extra account's current-window ledger: a profile ledger prefix plus its directory.
    static func profileWindowLedger(_ base: String, directory: String) -> String {
        base + "." + directory
    }

    static func isObsolete(_ key: String) -> Bool {
        (key.hasPrefix("tokenbar.") || key.hasPrefix("quotabar-lite."))
            && !active.contains(key)
            && !profileWindowLedgers.contains { key.hasPrefix($0 + ".") }
    }
}
