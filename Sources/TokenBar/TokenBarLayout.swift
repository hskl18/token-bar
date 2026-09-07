import CoreGraphics

enum TokenBarLayout {
    static let panelWidth: CGFloat = 390

    static func panelHeight(for snapshot: AppSnapshot) -> CGFloat {
        let extraRows = snapshot.presentation.showsCodex
            ? max(0, snapshot.codex.displayWindows.count - 1) : 0
        return panelHeight(for: snapshot.presentation) + CGFloat(extraRows) * 81
    }

    static func panelSize(for snapshot: AppSnapshot) -> CGSize {
        CGSize(width: panelWidth, height: panelHeight(for: snapshot))
    }

    static func panelHeight(for presentation: ProviderPresentation) -> CGFloat {
        switch presentation {
        case .none:
            190
        case .claudeOnly:
            356
        case .codexOnly:
            362
        case .both:
            740
        }
    }

    static func panelSize(for presentation: ProviderPresentation) -> CGSize {
        CGSize(width: panelWidth, height: panelHeight(for: presentation))
    }
}
