import AppKit

enum TokenBarLayout {
    static let panelWidth: CGFloat = 390

    /// One account's row of quota rings, with the spacing and divider below it.
    static let quotaRowHeight: CGFloat = 73
    /// The column names above the first row, with the spacing below them.
    static let quotaHeaderHeight: CGFloat = 37

    /// The presentation's height with its quota card emptied, plus the column header and one row per listed account.
    /// The account rows the quota list shows.
    static func quotaRows(for snapshot: AppSnapshot) -> Int {
        let presentation = snapshot.presentation
        let claudeRows = (presentation.showsClaude && snapshot.showsPrimaryClaude && !snapshot.claude.displayWindows.isEmpty ? 1 : 0)
            + snapshot.visibleClaudeAccounts.count
        let codexRows = (presentation.showsCodex && snapshot.showsPrimaryCodex && !snapshot.codex.displayWindows.isEmpty ? 1 : 0)
            + snapshot.visibleCodexAccounts.count
        return claudeRows + codexRows + snapshot.visibleKiroAccounts.count
    }

    static func panelHeight(for snapshot: AppSnapshot) -> CGFloat {
        let presentation = snapshot.presentation
        // The presentation heights were measured with this many 81-point window rows in the quota card.
        let measuredRows = switch presentation {
        case .both: 3
        case .claudeOnly: 2
        case .codexOnly: 1
        case .none: 0
        }
        let rows = quotaRows(for: snapshot)
        return panelHeight(for: presentation) - CGFloat(measuredRows) * 81
            + CGFloat(rows) * quotaRowHeight + (rows > 0 ? quotaHeaderHeight : 0)
    }

    /// `correction` is what the panel measured the estimate to be off by, so the quota list fits without scrolling.
    static func panelSize(for snapshot: AppSnapshot, correction: CGFloat = 0) -> CGSize {
        let screenHeight = NSScreen.main?.frame.height ?? 800
        // The correction was measured on the quota list, so it means nothing once the list is gone.
        let correction = quotaRows(for: snapshot) > 0 ? correction : 0
        return CGSize(width: panelWidth, height: min(panelHeight(for: snapshot) + correction, max(250, screenHeight * 0.85)))
    }

    static func panelHeight(for presentation: ProviderPresentation) -> CGFloat {
        switch presentation {
        case .none:
            190
        case .claudeOnly:
            331
        // Measured with Codex's activity tiles in two rows, less the 80 points (a 72-point tile row and its gap) one row saves.
        case .codexOnly:
            255
        case .both:
            648
        }
    }

    static func panelSize(for presentation: ProviderPresentation) -> CGSize {
        CGSize(width: panelWidth, height: panelHeight(for: presentation))
    }
}
