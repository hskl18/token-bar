import CoreGraphics

enum TokenBarLayout {
    static let panelWidth: CGFloat = 390

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
