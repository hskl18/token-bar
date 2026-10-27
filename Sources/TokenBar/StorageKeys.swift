enum StorageKeys {
    static let snapshot = "tokenbar.snapshot.v1"
    static let claudeLedger = "tokenbar.claude-ledger.v6"
    static let claudeWindowLedger = "tokenbar.claude-window-ledger.v6"
    static let codexUsageLedger = "tokenbar.codex-usage-ledger.v7"
    static let codexWindowLedger = "tokenbar.codex-window-ledger.v9"
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

    static let profileLedgers = [claudeWindowLedger, codexWindowLedger, codexUsageLedger]

    /// An extra account's ledger: a profile ledger prefix plus its directory.
    static func profileLedger(_ base: String, directory: String) -> String {
        base + "." + directory
    }

    static func codexLedger(_ base: String, directories: [String]) -> String {
        if directories == [AccountSource.primaryDirectory(for: .codex).path] { return base }
        return profileLedger(base, directory: directories.sorted().joined(separator: "\n"))
    }

    static func isObsolete(_ key: String) -> Bool {
        (key.hasPrefix("tokenbar.") || key.hasPrefix("quotabar-lite."))
            && !active.contains(key)
            && !profileLedgers.contains { key.hasPrefix($0 + ".") }
    }
}
