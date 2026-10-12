import AppKit

enum TokenBarLayout {
    static let panelWidth: CGFloat = 390

    static func panelHeight(for snapshot: AppSnapshot) -> CGFloat {
        let codexRows = snapshot.primaryCodexYields ? -1 : max(0, snapshot.codex.displayWindows.count - 1)
        let extraRows = (snapshot.presentation.showsCodex ? codexRows : 0)
            + (snapshot.presentation.showsClaude ? max(0, snapshot.claude.displayWindows.count - 2) : 0)
        let additionalRows = (snapshot.additionalClaudeAccounts ?? []).reduce(0) {
            $0 + max(1, $1.quota.displayWindows.count)
        } + (snapshot.visibleCodexAccounts).reduce(0) {
            $0 + max(1, $1.quota.displayWindows.count)
        }
        return panelHeight(for: snapshot.presentation) + CGFloat(extraRows + additionalRows) * 81
    }

    static func panelSize(for snapshot: AppSnapshot) -> CGSize {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return CGSize(width: panelWidth, height: min(panelHeight(for: snapshot), max(250, screenHeight - 40)))
    }

    static func panelHeight(for presentation: ProviderPresentation) -> CGFloat {
        switch presentation {
        case .none:
            190
        case .claudeOnly:
            331
        case .codexOnly:
            335
        case .both:
            728
        }
    }

    static func panelSize(for presentation: ProviderPresentation) -> CGSize {
        CGSize(width: panelWidth, height: panelHeight(for: presentation))
    }
}
