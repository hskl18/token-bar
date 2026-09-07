import AppKit
import SwiftUI

private enum Palette {
    static let ink = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let track = Color(nsColor: .separatorColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let claude = Color(red: 1, green: 0xD8 / 255, blue: 0x87 / 255)
    static let codex = Color(red: 0x60 / 255, green: 0xAF / 255, blue: 1)
    static let warning = Color(red: 0xF0 / 255, green: 0xA3 / 255, blue: 0x3A / 255)
}

private enum AppleGeometry {
    static let panelFallbackRadius: CGFloat = 20
    static let groupFallbackRadius: CGFloat = 14
    static let controlFallbackRadius: CGFloat = 10
}

private enum TokenBarType {
    static let primary: CGFloat = 15
    static let caption: CGFloat = 10
    static let secondary: CGFloat = 11
}

private enum BrandAssets {
    static let claude = originalImage(named: "ClaudeCodeMark", extension: "svg")
    static let codex = templateImage(named: "CodexMark", extension: "svg")

    private static func templateImage(named name: String, extension fileExtension: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    private static func originalImage(named name: String, extension fileExtension: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

private struct ProviderMark: View {
    let provider: ProviderScope
    let color: Color

    var body: some View {
        Group {
            switch provider {
            case .overview:
                EmptyView()
            case .claude:
                originalBrandImage(BrandAssets.claude)
            case .codex:
                brandImage(BrandAssets.codex)
            }
        }
        .foregroundStyle(color)
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func brandImage(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "questionmark")
                .resizable()
                .scaledToFit()
        }
    }

    @ViewBuilder
    private func originalBrandImage(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "questionmark")
                .resizable()
                .scaledToFit()
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: TokenBarStore

    var body: some View {
        VStack(spacing: 0) {
            UnifiedUsagePage()
                .padding(.horizontal, 14)
                .padding(.top, 22)
                .padding(.bottom, 4)

            FooterBar()
        }
        .frame(
            width: TokenBarLayout.panelWidth,
            height: TokenBarLayout.panelHeight(for: store.snapshot)
        )
        .foregroundStyle(Palette.ink)
        .tokenBarPanelSurface()
    }
}

private struct UnifiedUsagePage: View {
    @EnvironmentObject private var store: TokenBarStore

    private var presentation: ProviderPresentation {
        store.snapshot.presentation
    }

    private var namedWindows: [NamedWindow] {
        var items: [NamedWindow] = []
        if presentation.showsClaude {
            if let window = store.snapshot.claude.shortWindow {
                items.append(NamedWindow(provider: "Claude", color: Palette.claude, window: window))
            }
            if let window = store.snapshot.claude.longWindow {
                items.append(NamedWindow(provider: "Claude", color: Palette.claude, window: window))
            }
        }
        if presentation.showsCodex {
            for window in store.snapshot.codex.displayWindows {
                let provider = window.limitID.map { $0 == "codex" ? "Codex" : "Codex · \($0)" } ?? "Codex"
                items.append(NamedWindow(provider: provider, color: Palette.codex, window: window))
            }
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if presentation.showsOverview {
                UsageActivityGroup(provider: .overview)
            }
            if presentation.showsClaude {
                UsageActivityGroup(provider: .claude)
            }
            if presentation.showsCodex {
                UsageActivityGroup(provider: .codex)
            }

            if presentation == .none {
                ErrorSummary()
                PanelCard {
                    EmptyState(
                        text: store.isRefreshing
                            ? "Connecting..."
                            : "Sign in to Claude Code or Codex to begin.",
                        isLoading: store.isRefreshing
                    )
                }
            } else if !namedWindows.isEmpty {
                PanelCard {
                    VStack(spacing: 12) {
                        ForEach(Array(namedWindows.enumerated()), id: \.element.id) { index, item in
                            WindowRow(
                                name: "\(item.provider) · \(compactWindowLabel(item.window.label))",
                                window: item.window,
                                color: item.color
                            )
                            if index < namedWindows.count - 1 {
                                Divider().opacity(0.55)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct UsageActivityGroup: View {
    @EnvironmentObject private var store: TokenBarStore
    let provider: ProviderScope

    private var color: Color {
        switch provider {
        case .overview: Palette.secondary
        case .claude: Palette.claude
        case .codex: Palette.codex
        }
    }

    private var percent: String {
        let value: Double?
        switch provider {
        case .overview:
            value = store.snapshot.combinedCapacityPercent
        case .claude:
            value = store.snapshot.claude.weeklyPercent
        case .codex:
            value = store.snapshot.codex.weeklyPercent
        }
        return value.map { "\(Int($0.rounded()))%" } ?? "--"
    }

    private var fullCapacityText: String? {
        guard let estimate = store.weeklyValue(for: provider) else { return nil }
        let value = estimate.equivalentValueUSD.formatted(
            .currency(code: "USD").precision(.fractionLength(0))
        )
        return "WEEKLY ≈ \(value) · \(compactTokens(estimate.equivalentTokens))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if provider == .overview {
                    Text(provider.title)
                        .font(.system(size: TokenBarType.primary, weight: .semibold))
                        .padding(.leading, 10)
                } else {
                    ProviderMark(provider: provider, color: color)
                        .padding(.leading, 10)
                }
                if let fullCapacityText {
                    Text(fullCapacityText)
                        .font(.system(size: TokenBarType.caption, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help("Estimated API-equivalent tokens and value at 100% of this provider's weekly window")
                }
                Spacer()
                percentStatus
            }

            if provider == .overview {
                CombinedActivitySection()
            } else {
                ActivitySection(provider: provider)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.title), \(percent) used")
    }

    @ViewBuilder
    private var percentStatus: some View {
        if store.isStale(provider) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Palette.warning)
                    .frame(width: 5, height: 5)
                percentText
            }
            .contentShape(Rectangle())
            .help(staleHelp)
            .accessibilityHint(staleHelp)
        } else {
            percentText
        }
    }

    private var percentText: some View {
        Text(percent)
            .font(.system(size: TokenBarType.primary, weight: .bold, design: .rounded))
            .monospacedDigit()
    }

    private var staleHelp: String {
        switch provider {
        case .claude:
            return store.snapshot.claude.error ?? "Showing the last successful Claude reading."
        case .codex:
            return store.snapshot.codex.error ?? "Showing the last successful Codex reading."
        case .overview:
            let staleProviders: [(name: String, error: String?)] = [
                ("Claude", store.snapshot.claude.isStale ? store.snapshot.claude.error : nil),
                ("Codex", store.snapshot.codex.isStale ? store.snapshot.codex.error : nil),
            ].filter { name, _ in
                name == "Claude" ? store.snapshot.claude.isStale : store.snapshot.codex.isStale
            }
            let names = staleProviders.map(\.name).joined(separator: " and ")
            let details = staleProviders.compactMap(\.error).joined(separator: " ")
            let summary = "All includes stale \(names) data."
            return details.isEmpty ? summary : "\(summary) \(details)"
        }
    }
}

private struct WindowRow: View {
    let name: String
    let window: LimitWindow
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name)
                    .font(.system(size: TokenBarType.primary, weight: .semibold))
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: TokenBarType.primary, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track.opacity(0.52))
                    Capsule()
                        .fill(progressColor)
                        .frame(width: max(5, proxy.size.width * window.usedPercent / 100))
                }
            }
            .frame(height: 7)

            Text(resetText(window.resetsAt))
            .font(.system(size: TokenBarType.secondary, weight: .medium))
            .foregroundStyle(Palette.secondary)
        }
    }

    private var progressColor: Color {
        window.usedPercent >= 80 ? Palette.warning : color
    }
}

private struct ActivitySection: View {
    @EnvironmentObject private var store: TokenBarStore
    let provider: ProviderScope

    @ViewBuilder
    var body: some View {
        if provider == .claude {
            HStack(spacing: 8) {
                activityTile(label: "TODAY", period: .today)
                activityTile(label: "THIS WEEK", period: .week)
                activityTile(label: "THIS MONTH", period: .month)
            }
        } else {
            LazyVGrid(columns: activityColumns, spacing: 8) {
                activityTile(label: "TODAY", period: .today)
                activityTile(label: "THIS WEEK", period: .week)
                activityTile(label: "THIS MONTH", period: .month)
                activityTile(label: "THIS YEAR", period: .year)
            }
        }
    }

    private var activityColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 8), GridItem(.flexible())]
    }

    private func activityTile(label: String, period: ActivityPeriod) -> some View {
        let tokens = store.tokens(for: provider, period: period)
        return ActivityTile(
            label: label,
            tokens: tokens,
            estimatedCost: store.estimatedCost(for: provider, period: period)
        )
    }
}

private struct CombinedActivitySection: View {
    @EnvironmentObject private var store: TokenBarStore

    var body: some View {
        let today = combinedMetric(period: .today)
        let week = combinedMetric(period: .week)
        let month = combinedMetric(period: .month)

        HStack(spacing: 8) {
            ActivityTile(
                label: "TODAY",
                tokens: today.tokens,
                estimatedCost: today.estimatedCost
            )
            ActivityTile(
                label: "THIS WEEK",
                tokens: week.tokens,
                estimatedCost: week.estimatedCost
            )
            ActivityTile(
                label: "THIS MONTH",
                tokens: month.tokens,
                estimatedCost: month.estimatedCost
            )
        }
    }

    private func combinedMetric(period: ActivityPeriod) -> ActivityMetric {
        let claudeTokens = store.tokens(for: .claude, period: period)
        let codexTokens = store.tokens(for: .codex, period: period)
        let estimatedCost: Double?
        if let claudeCost = store.estimatedCost(for: .claude, period: period),
           let codexCost = store.estimatedCost(for: .codex, period: period) {
            estimatedCost = claudeCost + codexCost
        } else {
            estimatedCost = nil
        }
        return ActivityMetric(tokens: claudeTokens + codexTokens, estimatedCost: estimatedCost)
    }
}

private struct ActivityMetric {
    let tokens: Int64
    let estimatedCost: Double?
}

private struct ActivityTile: View {
    let label: String
    let tokens: Int64
    let estimatedCost: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: TokenBarType.caption, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Palette.secondary)
            if let estimatedCost {
                Text(estimatedCost.formatted(
                    .currency(code: "USD").precision(.fractionLength(2))
                ))
                    .font(.system(size: TokenBarType.primary, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                Text("--")
                    .font(.system(size: TokenBarType.primary, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Text(compactTokens(tokens) + " tokens")
                .font(.system(size: TokenBarType.caption, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .appleConcentricSurface(
            fill: Palette.surface.opacity(0.76),
            border: Palette.separator.opacity(0.32),
            fallbackRadius: AppleGeometry.controlFallbackRadius
        )
    }
}

private struct ErrorSummary: View {
    @EnvironmentObject private var store: TokenBarStore

    var body: some View {
        let providers = [store.snapshot.claude, store.snapshot.codex]
        let providerErrors: [String] = providers.compactMap { provider -> String? in
            guard !provider.isStale || provider.headlinePercent == nil else { return nil }
            return provider.error
        } + [
            store.snapshot.codexActivityError,
            store.snapshot.claudeWeeklyValueError?.hasPrefix("Exact local scan failed") == true
                ? store.snapshot.claudeWeeklyValueError
                : nil,
        ].compactMap { $0 }
        let errors = Array(Set(providerErrors)).sorted()
        if !errors.isEmpty {
            ErrorBanner(text: errors.joined(separator: " "))
        }
    }
}

private struct ErrorBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warning)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .appleConcentricSurface(
            fill: Palette.warning.opacity(0.09),
            border: Color.clear,
            fallbackRadius: AppleGeometry.controlFallbackRadius
        )
    }
}

private struct FooterBar: View {
    @EnvironmentObject private var store: TokenBarStore

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if store.isRefreshing {
                    store.cancelRefresh()
                } else {
                    store.refresh()
                }
            } label: {
                footerIcon(store.isRefreshing ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Auto-refreshes about every 10 minutes. Click to refresh now.")
            .accessibilityLabel(store.isRefreshing ? "Cancel refresh" : "Refresh now")

            Spacer()

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(updatedText(at: context.date))
                    .font(.system(size: TokenBarType.secondary, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                footerIcon("power")
            }
            .buttonStyle(.plain)
            .help("Quit Token Bar")
            .accessibilityLabel("Quit Token Bar")
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 22)
    }

    private func footerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .frame(width: 36, height: 28)
            .footerControlSurface()
    }

    private func updatedText(at now: Date) -> String {
        if store.isRefreshing {
            return "Refreshing"
        }

        let staleProviders: [(name: String, snapshot: ProviderSnapshot)] = [
            ("Claude", store.snapshot.claude),
            ("Codex", store.snapshot.codex),
        ].filter { $0.snapshot.isStale }

        if staleProviders.count == 1, let stale = staleProviders.first {
            if stale.name == "Claude",
               stale.snapshot.error?.localizedCaseInsensitiveContains("expired") == true {
                return "Claude sign-in required"
            }
            guard let date = stale.snapshot.lastSuccessAt else {
                return "\(stale.name) stale"
            }
            return "\(stale.name) stale · \(compactElapsedTime(from: date, to: now))"
        }

        if staleProviders.count > 1 {
            let oldest = staleProviders.compactMap(\.snapshot.lastSuccessAt).min()
            guard let oldest else { return "Stale" }
            return "Stale · \(compactElapsedTime(from: oldest, to: now))"
        }

        guard let date = store.lastSuccessDate(for: .overview) else {
            return "Not updated"
        }
        let relative = compactElapsedTime(from: date, to: now)
        return relative
    }

    private func compactElapsedTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case 0:
            return "now"
        case ..<60:
            return "\(seconds)s ago"
        case ..<3_600:
            return "\(seconds / 60)m ago"
        case ..<86_400:
            return "\(seconds / 3_600)h ago"
        default:
            return "\(seconds / 86_400)d ago"
        }
    }
}

private struct PanelCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appleConcentricSurface(
                fill: Palette.surface.opacity(0.76),
                border: Palette.separator.opacity(0.32),
                fallbackRadius: AppleGeometry.groupFallbackRadius
            )
    }
}

private extension View {
    @ViewBuilder
    func tokenBarPanelSurface() -> some View {
        if #available(macOS 26.0, *) {
            let shape = ConcentricRectangle(
                corners: .concentric(
                    minimum: .fixed(AppleGeometry.panelFallbackRadius)
                ),
                isUniform: true
            )
            containerShape(
                RoundedRectangle(
                    cornerRadius: AppleGeometry.panelFallbackRadius,
                    style: .continuous
                )
            )
                .glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppleGeometry.panelFallbackRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: AppleGeometry.panelFallbackRadius,
                        style: .continuous
                    )
                        .stroke(Palette.separator.opacity(0.42), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func appleConcentricSurface(
        fill: Color,
        border: Color,
        fallbackRadius: CGFloat
    ) -> some View {
        if #available(macOS 26.0, *) {
            let shape = ConcentricRectangle(
                corners: .concentric(minimum: .fixed(fallbackRadius)),
                isUniform: true
            )
            containerShape(
                RoundedRectangle(cornerRadius: fallbackRadius, style: .continuous)
            )
                .background(fill, in: shape)
                .overlay { shape.stroke(border, lineWidth: 1) }
        } else {
            let shape = RoundedRectangle(cornerRadius: fallbackRadius, style: .continuous)
            background(fill, in: shape)
                .overlay { shape.stroke(border, lineWidth: 1) }
        }
    }

    @ViewBuilder
    func footerControlSurface() -> some View {
        if #available(macOS 26.0, *) {
            let shape = ConcentricRectangle(
                corners: .concentric(
                    minimum: .fixed(AppleGeometry.controlFallbackRadius)
                ),
                isUniform: true
            )
            containerShape(
                RoundedRectangle(
                    cornerRadius: AppleGeometry.controlFallbackRadius,
                    style: .continuous
                )
            )
                .glassEffect(.regular, in: shape)
        } else {
            let shape = RoundedRectangle(
                cornerRadius: AppleGeometry.controlFallbackRadius,
                style: .continuous
            )
            background(.thinMaterial, in: shape)
                .overlay {
                    shape.stroke(Color.white.opacity(0.42), lineWidth: 1)
                }
        }
    }
}

private struct EmptyState: View {
    let text: String
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 9) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(Palette.warning)
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondary)
        }
    }
}

private struct NamedWindow: Identifiable {
    let provider: String
    let color: Color
    let window: LimitWindow

    var id: String { provider + window.label }
}

private func resetText(_ date: Date?) -> String {
    guard let date else { return "Reset unavailable" }
    if date <= Date() { return "Reset due" }
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = date.timeIntervalSinceNow > 24 * 60 * 60 ? [.day, .hour] : [.hour, .minute]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    return "Resets in " + (formatter.string(from: Date(), to: date) ?? "soon")
}

private func compactWindowLabel(_ label: String) -> String {
    label.replacingOccurrences(of: " window", with: "")
}

private func compactTokens(_ value: Int64) -> String {
    let absolute = Double(abs(value))
    let sign = value < 0 ? "-" : ""
    if absolute >= 1_000_000_000 {
        return sign + String(format: "%.1fB", absolute / 1_000_000_000)
    }
    if absolute >= 1_000_000 {
        return sign + String(format: "%.1fM", absolute / 1_000_000)
    }
    if absolute >= 1_000 {
        return sign + String(format: "%.1fK", absolute / 1_000)
    }
    return "\(value)"
}

private func compactTokens(_ value: Double) -> String {
    guard value.isFinite else { return "--" }
    let absolute = abs(value)
    let sign = value < 0 ? "-" : ""
    if absolute >= 1_000_000_000 {
        return sign + String(format: "%.1fB", absolute / 1_000_000_000)
    }
    if absolute >= 1_000_000 {
        return sign + String(format: "%.1fM", absolute / 1_000_000)
    }
    if absolute >= 1_000 {
        return sign + String(format: "%.1fK", absolute / 1_000)
    }
    return sign + String(format: "%.0f", absolute)
}
