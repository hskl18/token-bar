enum StorageKeys {
    static let snapshot = "tokenbar.snapshot.v1"
    static let claudeLedger = "tokenbar.claude-ledger.v5"
    static let claudeWindowLedger = "tokenbar.claude-window-ledger.v5"
    static let codexUsageLedger = "tokenbar.codex-usage-ledger.v1"
    static let codexWindowLedger = "tokenbar.codex-window-ledger.v3"
    static let codexLastKnownMix = "tokenbar.codex-last-known-mix.v2"
    static let codexRuntimeExecutable = "tokenbar.codex-runtime-executable.v1"
    static let priceCache = "tokenbar.price-cache.v4"

    static let active: Set<String> = [
        snapshot,
        claudeLedger,
        claudeWindowLedger,
        codexUsageLedger,
        codexWindowLedger,
        codexLastKnownMix,
        codexRuntimeExecutable,
        priceCache,
    ]

    static func isObsolete(_ key: String) -> Bool {
        (key.hasPrefix("tokenbar.") || key.hasPrefix("quotabar-lite."))
            && !active.contains(key)
    }
}
