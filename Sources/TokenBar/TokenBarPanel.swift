import AppKit
import SwiftUI

private enum Palette {
    static let ink = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let track = Color(nsColor: .separatorColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let claude = Color(red: 0xD7 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    static let codex = Color(red: 0x60 / 255, green: 0xAF / 255, blue: 1)
    static let warning = Color(red: 0xF0 / 255, green: 0xA3 / 255, blue: 0x3A / 255)
    static let failure = Color.yellow
}

private enum AppleGeometry {
    static let pageInset: CGFloat = 14
    static let contentInset: CGFloat = 12
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
    let onWeeklyReset: (ProviderScope, String, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            UnifiedUsagePage(onWeeklyReset: onWeeklyReset)
                .padding(.horizontal, AppleGeometry.pageInset)
                .padding(.top, 8)
                .padding(.bottom, 4)

            FooterBar()
        }
        .frame(
            width: TokenBarLayout.panelWidth,
            height: TokenBarLayout.panelSize(for: store.snapshot).height
        )
        .foregroundStyle(Palette.ink)
    }
}

private struct UnifiedUsagePage: View {
    @EnvironmentObject private var store: TokenBarStore
    let onWeeklyReset: (ProviderScope, String, String) -> Void

    private var presentation: ProviderPresentation {
        store.snapshot.presentation
    }

    private var namedWindows: [NamedWindow] {
        var items: [NamedWindow] = []
        func append(title: String, source: String, name: String, quota: ProviderSnapshot, color: NSColor,
                    showUnavailable: Bool = false) {
            let groupedWindows = quota.displayWindows.sorted {
                let leftBucket = $0.limitID ?? "codex"
                let rightBucket = $1.limitID ?? "codex"
                if leftBucket != rightBucket {
                    if leftBucket == "codex" { return true }
                    if rightBucket == "codex" { return false }
                    return leftBucket < rightBucket
                }
                return ($0.windowMinutes ?? Int.max) < ($1.windowMinutes ?? Int.max)
            }
            for window in groupedWindows {
                let detail = name == "Codex" && window.quotaDisplayName != "Codex" ? window.quotaDisplayName
                    : name == "Claude" && window.windowMinutes == 10080 ? window.limitName : nil
                let provider = detail.map { title + " · " + $0 } ?? title
                items.append(NamedWindow(
                    provider: provider, scope: name, source: source, window: window, barBase: color,
                    // Past its reset an idle reading is out of date, so the row says "Reset due" like any other.
                    status: quota.idle == true && window.resetsAt.map({ $0 > Date() }) ?? true
                        ? quota.lastSuccessAt.map { "Idle since \(readingTime($0))" } : nil,
                    weeklyResetCredits: !quota.isStale && quota.idle != true && quota.resetCreditsFetched == true
                        ? quota.weeklyResetCredits : nil
                ))
            }
            if groupedWindows.isEmpty && showUnavailable {
                items.append(NamedWindow(
                    provider: title, scope: name, source: source, window: nil, barBase: color,
                    status: store.isRefreshing ? "Connecting…" : "Quota unavailable"
                ))
            }
        }
        if presentation.showsClaude {
            append(
                title: "Claude", source: "~/.claude", name: "Claude",
                quota: store.snapshot.claude, color: QuotaBarColor.claude
            )
        }
        for account in store.snapshot.additionalClaudeAccounts ?? [] {
            append(
                title: account.name, source: account.sourceDirectory,
                name: "Claude", quota: account.quota, color: QuotaBarColor.claude, showUnavailable: true
            )
        }
        if presentation.showsCodex && !store.snapshot.primaryCodexYields {
            append(
                title: "Codex", source: "~/.codex", name: "Codex",
                quota: store.snapshot.codex, color: QuotaBarColor.codex
            )
        }
        for account in store.snapshot.visibleCodexAccounts {
            append(
                title: account.name, source: account.sourceDirectory,
                name: "Codex", quota: account.quota, color: QuotaBarColor.codex, showUnavailable: true
            )
        }
        return items.filter { $0.window?.windowMinutes == 5 * 60 }
            + items.filter { $0.window?.windowMinutes == 7 * 24 * 60 }
            + items.filter { $0.window?.windowMinutes != 5 * 60 && $0.window?.windowMinutes != 7 * 24 * 60 }
    }

    var body: some View {
        let windows = namedWindows
        return VStack(alignment: .leading, spacing: 14) {
            if presentation.showsOverview {
                UsageActivityGroup(provider: .overview)
            }
            if presentation.showsClaude {
                UsageActivityGroup(provider: .claude)
            }
            if presentation.showsCodex {
                UsageActivityGroup(provider: .codex)
            }

            if presentation == .none && windows.isEmpty {
                PanelCard {
                    EmptyState(
                        text: store.isRefreshing
                            ? "Connecting..."
                            : "Sign in to Claude Code or Codex to begin.",
                        isLoading: store.isRefreshing
                    )
                }
            } else if !windows.isEmpty {
                PanelCard(contentInset: 0) {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(Array(windows.enumerated()), id: \.element.id) { index, item in
                                WindowRow(
                                    name: item.provider + (item.window.map { " · \(compactWindowLabel($0))" } ?? ""),
                                    window: item.window,
                                    barBase: item.barBase,
                                    status: item.status,
                                    source: item.source,
                                    weeklyResetCredits: item.weeklyResetCredits,
                                    resetEnabled: !store.isRefreshing && !store.isResettingQuota,
                                    onReset: {
                                        onWeeklyReset(item.scope == "Claude" ? .claude : .codex, item.source, item.provider)
                                    }
                                )
                                if index < windows.count - 1 {
                                    Divider().opacity(0.55)
                                }
                            }
                        }
                    }
                    .contentMargins(AppleGeometry.contentInset, for: .scrollContent)
                    .contentMargins(.vertical, AppleGeometry.contentInset, for: .scrollIndicators)
                    .clipShape(RoundedRectangle(
                        cornerRadius: AppleGeometry.groupFallbackRadius, style: .continuous
                    ))
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
        case .overview, .claude, .codex:
            value = store.weeklyPercent(for: provider)
        }
        return value.map { "\(Int($0.rounded()))%" } ?? "--"
    }

    private var fullCapacityText: String? {
        let estimates = store.weeklyValues(for: provider)
        guard !estimates.isEmpty else { return nil }
        let tokens = estimates.reduce(0) { $0 + $1.equivalentTokens }
        let value = estimates.reduce(0) { $0 + $1.equivalentValueUSD }
            .formatted(.currency(code: "USD").precision(.fractionLength(0)))
        return "WEEKLY ≈ \(value) · \(compactTokens(tokens))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if provider == .overview {
                    Text(provider.title)
                        .font(.system(size: TokenBarType.primary, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                } else {
                    ProviderMark(provider: provider, color: color)
                }
                if let fullCapacityText {
                    Text(fullCapacityText)
                        .font(.system(size: TokenBarType.caption, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .hoverHelp(store.weeklyCostHelp(for: provider))
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
            .hoverHelp(staleHelp)
        } else {
            percentText
        }
    }

    private var percentText: some View {
        Text(percent)
            .font(.system(size: TokenBarType.primary, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Palette.ink)
    }

    private var staleHelp: String {
        (provider == .overview ? [.claude, .codex] : [provider]).compactMap(store.staleDetails).joined(separator: "\n")
    }
}

private struct WindowRow: View {
    let name: String
    let window: LimitWindow?
    let barBase: NSColor
    let status: String?
    let source: String
    let weeklyResetCredits: Int?
    let resetEnabled: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name)
                    .font(.system(size: TokenBarType.primary, weight: .semibold))
                    .lineLimit(2)
                Spacer()
                Text(window.map { "\(Int($0.usedPercent.rounded()))%" } ?? "--")
                    .font(.system(size: TokenBarType.primary, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track.opacity(0.52))
                    if let window {
                        Capsule()
                            .fill(Color(nsColor: QuotaBarColor.at(window.usedPercent, base: barBase)))
                            .frame(width: max(5, proxy.size.width * window.usedPercent / 100))
                    }
                }
            }
            .frame(height: 7)

            HStack {
                Text(status ?? resetText(window?.resetsAt))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let weeklyResetCredits, weeklyResetCredits > 0,
                   window?.windowMinutes == 7 * 24 * 60,
                   window?.limitID == nil || ["claude", "codex"].contains(window?.limitID ?? "") {
                    Button(action: onReset) {
                        Text("Reset \(weeklyResetCredits)")
                            .monospacedDigit()
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .background(Palette.secondary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!resetEnabled)
                    .hoverHelp("Use 1 of \(weeklyResetCredits) weekly reset credits")
                }
            }
            .font(.system(size: TokenBarType.secondary, weight: .medium))
            .foregroundStyle(Palette.secondary)
        }
        .hoverHelp(source)
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
        .hoverHelp(store.activityHelp(for: provider, period: period))
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
            .hoverHelp(store.activityHelp(for: .overview, period: .today))
            ActivityTile(
                label: "THIS WEEK",
                tokens: week.tokens,
                estimatedCost: week.estimatedCost
            )
            .hoverHelp(store.activityHelp(for: .overview, period: .week))
            ActivityTile(
                label: "THIS MONTH",
                tokens: month.tokens,
                estimatedCost: month.estimatedCost
            )
            .hoverHelp(store.activityHelp(for: .overview, period: .month))
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
        .padding(.horizontal, AppleGeometry.contentInset)
        .padding(.vertical, 10)
        .appleConcentricSurface(
            fill: Palette.surface.opacity(0.76),
            border: Palette.separator.opacity(0.32),
            fallbackRadius: AppleGeometry.controlFallbackRadius
        )
    }
}

private struct FooterBar: View {
    @EnvironmentObject private var store: TokenBarStore

    var body: some View {
        let errors = errorDetails
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
            .hoverHelp(store.isRefreshing ? "Cancel refresh" : "Refresh now")
            .accessibilityLabel(store.isRefreshing ? "Cancel refresh" : "Refresh now")

            Spacer()

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(updatedText(at: context.date))
                    .font(.system(size: TokenBarType.secondary, weight: .medium))
                    .foregroundStyle(errors.isEmpty ? Palette.secondary : Palette.failure)
                    .hoverHelp(errors)
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                footerIcon("power")
            }
            .buttonStyle(.plain)
            .hoverHelp("Quit Token Bar")
            .accessibilityLabel("Quit Token Bar")
        }
        .padding(.horizontal, AppleGeometry.pageInset)
        .padding(.top, 4)
        .padding(.bottom, 8)
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

        guard let date = store.lastSuccessDate(for: .overview) else {
            return "Not updated"
        }
        return compactElapsedTime(from: date, to: now)
    }

    private var errorDetails: String {
        let snapshot = store.snapshot
        let profiles: [(String, ProviderSnapshot)] = [
            ("Claude", snapshot.claude),
            ("Codex", snapshot.codex),
        ] + (snapshot.additionalClaudeAccounts ?? []).map {
            ($0.name, $0.quota)
        } + snapshot.visibleCodexAccounts.map {
            ($0.name, $0.quota)
        }
        var messages = profiles.compactMap { name, quota in
            quota.error.map { "\(name): \($0)" }
        }
        if let error = snapshot.codexActivityError, error != snapshot.codex.error {
            messages.append("Codex activity: \(error)")
        }
        messages += store.estimateFailures.map { "\($0.key): \($0.value)" }
        return Array(Set(messages)).sorted().joined(separator: "\n\n")
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
    var contentInset: CGFloat = AppleGeometry.contentInset
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(contentInset)
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
    let scope: String
    let source: String
    let window: LimitWindow?
    let barBase: NSColor
    let status: String?
    var weeklyResetCredits: Int? = nil

    var id: String { scope + source + (window?.id ?? "unavailable") }
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

private func compactWindowLabel(_ window: LimitWindow) -> String {
    if window.windowMinutes == 7 * 24 * 60 { return "Weekly" }
    return window.label.replacingOccurrences(of: " window", with: "")
}

func compactTokens(_ value: Int64) -> String {
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

extension View {
    /// Hover text for the status menu, where AppKit never shows `.help` tooltips during menu tracking.
    func hoverHelp(_ text: String) -> some View {
        overlay(HoverTracker(text: text)).accessibilityHint(text)
    }
}

private struct HoverTracker: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> HoverTrackingView { HoverTrackingView() }

    func updateNSView(_ view: HoverTrackingView, context: Context) { view.text = text }
}

private final class HoverTrackingView: NSView {
    // A refresh can change the text under a still pointer, so the shown tip follows it.
    var text = "" { didSet { if isInside, text != oldValue { report() } } }
    private var isInside = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The menu window is never key, so only an always-active area hears the pointer, also while dragging.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { nil }

    // Clicks and scrolling reach the SwiftUI views beneath; tracking areas do not need hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) {
        isInside = true
        report()
    }

    override func mouseExited(with event: NSEvent) {
        isInside = false
        HoverTip.shared.exit(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isInside = false
            HoverTip.shared.exit(self)
        }
    }

    private func report() {
        guard let window, !text.isEmpty else { return HoverTip.shared.exit(self) }
        HoverTip.shared.enter(self, text: text, rect: window.convertToScreen(convert(bounds, to: nil)), menu: window.frame)
    }
}

/// A tooltip window above the open status menu, placed beside it so it never covers the panel.
@MainActor
final class HoverTip {
    static let shared = HoverTip()
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    // Areas the pointer is inside. Enter and exit events arrive in any order, so the smallest area, the
    // innermost, wins, and leaving a button inside a row returns to the row's text.
    private var entered: [(owner: ObjectIdentifier, text: String, rect: NSRect, menu: NSRect)] = []

    private init() {
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        label.font = .toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        label.isSelectable = false
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
        ])
        panel.contentView = background
    }

    func enter(_ owner: NSView, text: String, rect: NSRect, menu: NSRect) {
        let id = ObjectIdentifier(owner)
        entered.removeAll { $0.owner == id }
        entered.append((id, text, rect, menu))
        schedule()
    }

    func exit(_ owner: NSView) {
        let id = ObjectIdentifier(owner)
        guard entered.contains(where: { $0.owner == id }) else { return }
        entered.removeAll { $0.owner == id }
        panel.orderOut(nil)
        schedule()
    }

    func hide() {
        entered.removeAll()
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func schedule() {
        timer?.invalidate()
        guard !entered.isEmpty else { return }
        // A run-loop timer in common modes fires during menu tracking, even when a main-queue task opened the
        // menu and the queue cannot run again until it closes.
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.present() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func present() {
        guard let tip = entered.min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height })
        else { return }
        let screen = (NSScreen.screens.first { $0.frame.intersects(tip.menu) } ?? NSScreen.main)?.visibleFrame ?? tip.menu
        // The wider side of the menu, which sits under the menu bar; it overlaps the menu only when neither fits.
        let left = tip.menu.minX - screen.minX - 12
        let right = screen.maxX - tip.menu.maxX - 12
        let width = min(340, max(160, max(left, right)) - 16)
        label.stringValue = tip.text
        label.preferredMaxLayoutWidth = width
        let fitting = label.intrinsicContentSize
        let size = NSSize(width: min(width, fitting.width) + 16, height: min(fitting.height + 12, screen.height - 12))
        var x = left >= right ? tip.menu.minX - size.width - 6 : tip.menu.maxX + 6
        x = min(max(x, screen.minX + 6), screen.maxX - size.width - 6)
        let y = min(max(tip.rect.maxY - size.height, screen.minY + 6), screen.maxY - size.height - 6)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
}
