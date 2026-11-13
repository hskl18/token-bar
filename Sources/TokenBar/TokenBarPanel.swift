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

private enum QuotaList {
    static let rowSpacing: CGFloat = 16
    static let verticalInset: CGFloat = 16
    static let horizontalInset: CGFloat = 16
    /// The width the name and ring columns share.
    static var cardWidth: CGFloat { TokenBarLayout.panelWidth - 2 * AppleGeometry.pageInset - 2 * horizontalInset }
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
    /// Provider, account folder, account name, and whether to spend a Fable reset instead of a full weekly one.
    let onWeeklyReset: (ProviderScope, String, String, Bool) -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            UnifiedUsagePage(onWeeklyReset: onWeeklyReset)
                .padding(.horizontal, AppleGeometry.pageInset)
                .padding(.top, 8)
                .padding(.bottom, 4)

            FooterBar(onSettings: onSettings)
        }
        .frame(
            width: TokenBarLayout.panelWidth,
            height: TokenBarLayout.panelSize(for: store.snapshot, correction: store.panelHeightCorrection).height
        )
        .foregroundStyle(Palette.ink)
    }
}

private struct UnifiedUsagePage: View {
    @EnvironmentObject private var store: TokenBarStore
    let onWeeklyReset: (ProviderScope, String, String, Bool) -> Void
    @State private var listContentHeight: CGFloat = 0
    @State private var listViewportHeight: CGFloat = 0

    /// A clear background that reports its height when it appears and whenever it changes, then refits the panel.
    private func heightReader(_ record: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { record(proxy.size.height); reportOverflow() }
                .onChange(of: proxy.size.height) { _, height in record(height); reportOverflow() }
        }
    }

    /// Sizes the panel so the quota list fits without scrolling: the height it has now, plus what the list is
    /// taller (or shorter) than the space it got, kept as a correction to the estimate.
    /// The same measurement always gives the same correction, so a repeated report does not add up.
    private func reportOverflow() {
        guard listContentHeight > 0, listViewportHeight > 0 else { return }
        let snapshot = store.snapshot
        let current = TokenBarLayout.panelSize(for: snapshot, correction: store.panelHeightCorrection).height
        let needed = current + listContentHeight + 2 * QuotaList.verticalInset - listViewportHeight
        let correction = needed - TokenBarLayout.panelHeight(for: snapshot)
        if abs(correction - store.panelHeightCorrection) > 0.5 { store.panelHeightCorrection = correction }
    }

    private var presentation: ProviderPresentation {
        store.snapshot.presentation
    }

    private var accountRows: [[NamedWindow]] {
        var items: [NamedWindow] = []
        func append(title: String, source: String, name: String, key: String?, quota: ProviderSnapshot,
                    color: NSColor, showUnavailable: Bool = false) {
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
            let creditsCurrent = !quota.isStale && quota.idle != true && quota.resetCreditsFetched == true
            // A Claude model's own weekly limit, such as Fable's, gets no ring when a Week ring can list it in its hover.
            let hasWeek = groupedWindows.contains { $0.limitID == "claude" && $0.windowMinutes == LimitWindow.weeklyMinutes }
            let modelWeeks = name == "Claude" && hasWeek ? groupedWindows.filter {
                $0.windowMinutes == LimitWindow.weeklyMinutes && $0.limitID != "claude"
            } : []
            let modelLines = modelWeeks.map { "\($0.limitName ?? $0.label): \(Int($0.usedPercent.rounded()))% used" }
            for window in groupedWindows where !modelWeeks.contains(window) {
                let isWeek = window.limitID == "claude" && window.windowMinutes == LimitWindow.weeklyMinutes
                let idleSince = quota.idle == true && window.resetsAt.map({ $0 > Date() }) ?? true ? quota.lastSuccessAt : nil
                let detail = name == "Codex" && window.quotaDisplayName != "Codex" ? window.quotaDisplayName
                    : name == "Claude" && window.windowMinutes == LimitWindow.weeklyMinutes ? window.limitName : nil
                let provider = detail.map { title + " · " + $0 } ?? title
                items.append(NamedWindow(
                    provider: provider, account: title, detail: detail,
                    scope: name, source: source, window: window, barBase: color,
                    // Past its reset an idle reading is out of date, so the row says "Reset due" like any other.
                    // Kiro has no header to mark a failed refresh, so its row says so.
                    status: idleSince.map { _ in "Idle" } ?? (name == "Kiro" && quota.error != nil ? "Out of date" : nil),
                    statusHelp: idleSince.map { "Idle since \(readingTime($0))\n" + idleReason(name) }
                        ?? quota.error.map { error in quota.lastSuccessAt.map { "\(error) As of \(readingTime($0))." } ?? error },
                    weeklyResetCredits: creditsCurrent ? quota.weeklyResetCredits : nil,
                    resetCreditExpiries: quota.resetCreditExpiries,
                    fableResetCredits: creditsCurrent ? quota.fableResetCredits : nil,
                    fableResetCreditExpiries: quota.fableResetCreditExpiries,
                    help: ([windowHelp(window, readAt: quota.lastSuccessAt, estimate: name == "Kiro" ? nil : store.weeklyEstimate(
                        for: name == "Claude" ? .claude : .codex, account: key, window: window, in: quota
                    ))] + (isWeek ? modelLines : [])).filter { !$0.isEmpty }.joined(separator: "\n")
                ))
            }
            if groupedWindows.isEmpty && showUnavailable {
                items.append(NamedWindow(
                    provider: title, account: title, detail: nil,
                    scope: name, source: source, window: nil, barBase: color,
                    // Kiro's errors are short, so its row names the reason; an idle Kiro has no reading yet.
                    status: store.isRefreshing ? "Connecting…" : quota.idle == true ? "Idle"
                        : name == "Kiro" ? quota.error ?? "Quota unavailable" : "Quota unavailable",
                    statusHelp: quota.idle == true ? idleReason(name) : quota.error
                ))
            }
        }
        if presentation.showsClaude && store.snapshot.showsPrimaryClaude {
            append(
                title: "claude", source: "~/.claude", name: "Claude", key: store.snapshot.claudeAccountID,
                quota: store.snapshot.claude, color: QuotaBarColor.claude
            )
        }
        for account in store.snapshot.visibleClaudeAccounts {
            append(
                title: account.name, source: account.sourceDirectory,
                name: "Claude", key: account.id, quota: account.quota, color: QuotaBarColor.claude, showUnavailable: true
            )
        }
        if presentation.showsCodex && store.snapshot.showsPrimaryCodex {
            append(
                title: "codex", source: "~/.codex", name: "Codex", key: store.snapshot.codexAccountID,
                quota: store.snapshot.codex, color: QuotaBarColor.codex
            )
        }
        for account in store.snapshot.visibleCodexAccounts {
            append(
                title: account.name, source: account.sourceDirectory,
                name: "Codex", key: account.accountID ?? account.id, quota: account.quota, color: QuotaBarColor.codex, showUnavailable: true
            )
        }
        for account in store.snapshot.visibleKiroAccounts {
            append(
                title: account.name, source: account.id,
                name: "Kiro", key: nil, quota: account.quota, color: QuotaBarColor.kiro, showUnavailable: true
            )
        }
        return quotaAccountRows(items, provider: { $0.scope }, account: { $0.source })
    }

    var body: some View {
        let rows = accountRows
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

            if presentation == .none && rows.isEmpty {
                PanelCard {
                    EmptyState(
                        text: store.isRefreshing
                            ? "Connecting..."
                            : "Sign in to Claude Code or Codex to begin.",
                        isLoading: store.isRefreshing
                    )
                }
            } else if !rows.isEmpty {
                PanelCard(contentInset: 0) {
                    ScrollView {
                        VStack(spacing: QuotaList.rowSpacing) {
                            let columns = quotaColumns(rows, column: \.column, rank: \.rank)
                            let diameter = quotaRingDiameter(columns: columns.count)
                            let nameWidth = accountNameWidth(rows, columns: columns.count, diameter: diameter)
                            QuotaColumnHeader(columns: columns, nameWidth: nameWidth)
                            ForEach(Array(rows.enumerated()), id: \.element[0].id) { index, row in
                                AccountRow(
                                    windows: row,
                                    columns: columns,
                                    nameWidth: nameWidth,
                                    diameter: diameter,
                                    resetEnabled: !store.isRefreshing && !store.isResettingQuota,
                                    onReset: { item, fable in
                                        onWeeklyReset(item.scope == "Claude" ? .claude : .codex, item.source, item.provider, fable)
                                    }
                                )
                                if index < rows.count - 1 {
                                    Divider().opacity(0.55)
                                }
                            }
                        }
                        .background(heightReader { listContentHeight = $0 })
                    }
                    .contentMargins(.horizontal, QuotaList.horizontalInset, for: .scrollContent)
                    .contentMargins(.vertical, QuotaList.verticalInset, for: .scrollContent)
                    .contentMargins(.vertical, QuotaList.verticalInset, for: .scrollIndicators)
                    // macOS lets a ScrollView rubber-band even when its rows fit; only a list taller than the panel scrolls.
                    .scrollBounceBehavior(.basedOnSize)
                    .background(heightReader { listViewportHeight = $0 })
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

/// One account: its title, then a ring per quota window; each ring's hover gives that window's reset and projection.
private struct AccountRow: View {
    let windows: [NamedWindow]
    let columns: [QuotaColumn]
    let nameWidth: CGFloat
    let diameter: CGFloat
    let resetEnabled: Bool
    /// The window, and whether to spend a Fable reset instead of a full weekly one.
    let onReset: (NamedWindow, Bool) -> Void

    /// The main Weekly window, the one a reset credit clears or a Fable reset gives back to.
    private var resettable: NamedWindow? {
        windows.first {
            ($0.weeklyResetCredits ?? 0) + ($0.fableResetCredits ?? 0) > 0
                && $0.window?.windowMinutes == LimitWindow.weeklyMinutes
                && ($0.window?.limitID == nil || ["claude", "codex"].contains($0.window?.limitID ?? ""))
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: QuotaRing.nameSpacing) {
            // Every row centers its name, status and reset capsule on the name column's middle, so they share one axis.
            VStack(alignment: .center, spacing: 5) {
                Text(windows[0].account)
                    .font(.system(size: TokenBarType.primary, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let item = windows.first(where: { $0.status != nil }), let status = item.status {
                    Text(status)
                        .font(.system(size: TokenBarType.secondary, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .hoverHelp(item.statusHelp ?? "")
                }
                if let item = resettable {
                    let full = item.weeklyResetCredits ?? 0
                    // One capsule, `2 Reset | 3`: full weekly resets, then Claude's Fable resets after the divider.
                    HStack(spacing: 0) {
                        resetSegment(item, "\(full) Reset", credits: full, fable: false, expiries: item.resetCreditExpiries)
                        if let fable = item.fableResetCredits, fable > 0 {
                            Divider().frame(height: 10)
                            resetSegment(item, "\(fable)", credits: fable, fable: true, expiries: item.fableResetCreditExpiries)
                        }
                    }
                    .fixedSize()
                    .background(Palette.secondary.opacity(0.12), in: Capsule())
                    .font(.system(size: TokenBarType.secondary, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                }
            }
            .frame(width: nameWidth, alignment: .center)
            // Equal columns share what the names leave, so the rings spread out instead of crowding right.
            HStack(spacing: 0) {
                ForEach(columns, id: \.key) { column in
                    Group {
                        if let item = windows.first(where: { $0.column == column }), let window = item.window {
                            QuotaRing(item: item, window: window, diameter: diameter)
                        } else {
                            Color.clear.frame(height: diameter)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func resetSegment(
        _ item: NamedWindow, _ title: String, credits: Int, fable: Bool, expiries: [Date?]?
    ) -> some View {
        Button { onReset(item, fable) } label: {
            Text(title)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `0 Reset` beside Fable resets has nothing to spend.
        .disabled(!resetEnabled || credits == 0)
        .hoverHelp(credits > 0 ? resetCreditHelp(credits, fable: fable, expiries: expiries) : "")
    }
}

/// The names of the ring columns, above the first account row.
private struct QuotaColumnHeader: View {
    let columns: [QuotaColumn]
    let nameWidth: CGFloat

    var body: some View {
        HStack(spacing: QuotaRing.nameSpacing) {
            Color.clear.frame(width: nameWidth, height: 0)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                ForEach(columns, id: \.key) { column in
                    Text(column.title)
                        .font(.system(size: TokenBarType.caption, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct QuotaRing: View {
    /// Between the name column and the first ring column.
    static let nameSpacing: CGFloat = 16
    let item: NamedWindow
    let window: LimitWindow
    let diameter: CGFloat

    var body: some View {
        let percent = min(100, max(0, window.usedPercent))
        ZStack {
            Circle().stroke(Palette.track.opacity(0.52), lineWidth: 5)
            let fill = quotaRingFill(window.usedPercent)
            if fill > 0 {
                Circle()
                    .trim(from: 0, to: fill)
                    .stroke(
                        Color(nsColor: QuotaBarColor.at(percent, base: item.barBase)),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            TimelineView(.everyMinute) { context in
                Text(ringCenterText(window, now: context.date))
                    .font(.system(size: TokenBarType.secondary, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.account), \(item.column?.title ?? "")")
        .accessibilityValue("\(Int(window.usedPercent.rounded()))%")
        .hoverHelp(ringHelp(window, help: item.help))
    }
}

private struct ActivitySection: View {
    @EnvironmentObject private var store: TokenBarStore
    let provider: ProviderScope

    var body: some View {
        HStack(spacing: 8) {
            activityTile(label: "TODAY", period: .today)
            activityTile(label: "WEEKLY", period: .week)
            activityTile(label: "MONTHLY", period: .month)
            if provider != .claude {
                activityTile(label: "YEARLY", period: .year)
            }
        }
    }

    private func activityTile(label: String, period: ActivityPeriod) -> some View {
        let tokens = store.tokens(for: provider, period: period)
        return ActivityTile(
            label: label,
            tokens: tokens,
            estimatedCost: store.estimatedCost(for: provider, period: period),
            // Four tiles share the row Claude's three do, so they give their text more of the width.
            horizontalInset: provider == .claude ? AppleGeometry.contentInset : 8
        )
        .hoverHelp(store.activityHelp(for: provider, period: period), chart: store.periodUsage(for: provider, period: period))
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
            .hoverHelp(store.activityHelp(for: .overview, period: .today), chart: store.periodUsage(for: .overview, period: .today))
            ActivityTile(
                label: "WEEKLY",
                tokens: week.tokens,
                estimatedCost: week.estimatedCost
            )
            .hoverHelp(store.activityHelp(for: .overview, period: .week), chart: store.periodUsage(for: .overview, period: .week))
            ActivityTile(
                label: "MONTHLY",
                tokens: month.tokens,
                estimatedCost: month.estimatedCost
            )
            .hoverHelp(store.activityHelp(for: .overview, period: .month), chart: store.periodUsage(for: .overview, period: .month))
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
    var horizontalInset = AppleGeometry.contentInset

    var body: some View {
        // Each line shrinks rather than truncates or wraps when a narrow tile cannot fit it, such as a yearly cost.
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: TokenBarType.caption, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let estimatedCost {
                Text(estimatedCost.formatted(
                    .currency(code: "USD").precision(.fractionLength(2))
                ))
                    .font(.system(size: TokenBarType.primary, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalInset)
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
    let onSettings: () -> Void

    var body: some View {
        let errors = errorDetails
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Button(action: onSettings) {
                    footerIcon("gearshape")
                }
                .buttonStyle(.plain)
                .hoverHelp("Settings")
                .accessibilityLabel("Settings")

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
            }

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
        let profiles: [(String, ProviderSnapshot)] = (snapshot.showsPrimaryClaude ? [("claude", snapshot.claude)] : [])
            + (snapshot.isHidden(AccountSource.primaryDirectory(for: .codex).path) ? [] : [("codex", snapshot.codex)])
            + snapshot.visibleClaudeAccounts.map {
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

/// One row per account, accounts grouped by provider in the order providers first appear, so each provider's
/// accounts sit together under its usage cards; each row keeps its windows in the order they came.
/// The ring columns every account row shares: each window name the rows show, in the order they first appear,
/// so Claude's and Codex's `5h` and `Week` line up.
/// How much of a ring to fill: none for a window that reads 0%, so it does not look used,
/// and at least a short arc for any other, so a small percentage still shows.
func quotaRingFill(_ percent: Double) -> Double {
    percent.rounded() <= 0 ? 0 : max(0.02, min(100, percent) / 100)
}

func quotaColumns<Window, Column: Hashable>(
    _ rows: [[Window]], column: (Window) -> Column?, rank: (Column) -> Int
) -> [Column] {
    var columns: [Column] = []
    for found in rows.joined().compactMap(column) where !columns.contains(found) { columns.append(found) }
    return columns.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
}

/// A ring column. Every provider's main 5-hour and Weekly windows share `5h` and `Week`; any other window gets its
/// own column, keyed by provider, bucket and length, so two buckets with the same caption stay apart.
struct QuotaColumn: Hashable {
    let key: String
    let title: String

    // A column is its key: a bucket's caption can differ between a cached and a fresh reading, and the first wins.
    static func == (lhs: QuotaColumn, rhs: QuotaColumn) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }

    /// `5h` and `Week` lead, then Codex's other columns in the order they first appear, then `Credit`.
    var rank: Int { key == "5h" ? 0 : key == "Week" ? 1 : key == "Credit" ? 3 : 2 }
}

extension QuotaColumn {
    init(window: LimitWindow, detail: String?, scope: String) {
        let title = ringLabel(window, detail: detail)
        // A credit pool without a length, such as Claude's usage credits or Kiro's credits, shares `Credit`.
        let main = detail == nil
            && [LimitWindow.sessionMinutes, LimitWindow.weeklyMinutes, nil].contains(window.windowMinutes)
        self.init(
            key: main ? title : "\(scope)|\(window.limitID ?? "")|\(window.windowMinutes.map(String.init) ?? "")",
            title: title
        )
    }
}

func quotaAccountRows<Window>(
    _ windows: [Window], provider: (Window) -> String, account: (Window) -> String
) -> [[Window]] {
    var providers: [String] = [], accounts: [String] = []
    for window in windows {
        if !providers.contains(provider(window)) { providers.append(provider(window)) }
        if !accounts.contains(account(window)) { accounts.append(account(window)) }
    }
    return providers.flatMap { name in
        accounts.compactMap { folder in
            let row = windows.filter { provider($0) == name && account($0) == folder }
            return row.isEmpty ? nil : row
        }
    }
}

private struct NamedWindow: Identifiable {
    let provider: String
    /// The account folder's title, such as `claude-work`, and what tells this window apart in its row.
    let account: String
    let detail: String?
    let scope: String
    let source: String
    let window: LimitWindow?
    let barBase: NSColor
    let status: String?
    /// The status's hover, such as when an idle account was last read.
    var statusHelp: String? = nil
    var weeklyResetCredits: Int? = nil
    var resetCreditExpiries: [Date?]? = nil
    var fableResetCredits: Int? = nil
    var fableResetCreditExpiries: [Date?]? = nil
    var help = ""

    var id: String { scope + source + (window?.id ?? "unavailable") }
    var column: QuotaColumn? { window.map { QuotaColumn(window: $0, detail: detail, scope: scope) } }
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

/// A quota row's hover: what its weekly percentage has used and would allow, its reset time and, at the pace
/// so far in the window, where it ends up.
private func windowHelp(_ window: LimitWindow, readAt: Date?, estimate: WeeklyValueEstimate?) -> String {
    let used = window.usedPercent
    var lines: [String] = []
    if let estimate {
        lines.append("So far: \(compactTokens(estimate.observedTokens)) tokens"
            + " · \(usdText(estimate.observedCostUSD))")
        if used < 100 {
            lines.append("100% ≈ \(compactTokens(estimate.equivalentTokens)) tokens · \(usdText(estimate.equivalentValueUSD))")
        }
    }
    guard let reset = window.resetsAt, reset > Date() else { return lines.joined(separator: "\n") }
    lines.append("Resets \(readingTime(reset))")
    if let minutes = window.windowMinutes, let readAt, used > 0, used < 100 {
        let length = Double(minutes) * 60
        let elapsed = length - reset.timeIntervalSince(readAt)
        // Early in a window, or with a reading from an earlier one, a pace means little.
        if elapsed >= length / 20 {
            let atReset = used * length / elapsed
            lines.append("At this pace: " + (atReset < 100
                ? "\(Int(atReset.rounded()))% at reset"
                : "100% by \(readingTime(readAt.addingTimeInterval((100 - used) / used * elapsed)))"))
        }
    }
    return lines.joined(separator: "\n")
}

/// A reset button's hover: what it spends and when the credits expire, soonest first.
private func resetCreditHelp(_ count: Int, fable: Bool, expiries: [Date?]?) -> String {
    let groups = Dictionary(grouping: (expiries ?? []).filter { $0.map { $0 > Date() } ?? true }, by: { $0 })
        .sorted { ($0.key ?? .distantFuture) < ($1.key ?? .distantFuture) }
    let spends = fable ? ["Use 1 of \(count) Fable resets", "Returns what Fable used to your weekly limit"]
        : ["Use 1 of \(count) weekly reset credits"]
    return (spends + groups.map { date, credits in
        "\(credits.count) " + (date.map { "\(credits.count == 1 ? "expires" : "expire") \(readingTime($0))" } ?? "never expire"
            + (credits.count == 1 ? "s" : ""))
    }).joined(separator: "\n")
}

/// The name column's width: the widest account title or `2 Reset | 3` capsule, capped so a long folder name shrinks
/// instead of squeezing the rings, and so every ring column keeps room for its ring.
private func accountNameWidth(_ rows: [[NamedWindow]], columns: Int, diameter: CGFloat) -> CGFloat {
    let title = NSFont.systemFont(ofSize: TokenBarType.primary, weight: .semibold)
    let badge = NSFont.monospacedDigitSystemFont(ofSize: TokenBarType.secondary, weight: .medium)
    func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    let widest = rows.map { row in
        let full = row.compactMap(\.weeklyResetCredits).max()
        let fable = row.compactMap(\.fableResetCredits).max().flatMap { $0 > 0 ? $0 : nil }
        let capsule = (full ?? 0) == 0 && fable == nil ? 0
            : width("\(full ?? 0) Reset", badge) + 12 + (fable.map { width("\($0)", badge) + 13 } ?? 0)
        return max(width(row[0].account, title), capsule)
    }.max() ?? 0
    let roomForName = QuotaList.cardWidth - QuotaRing.nameSpacing - CGFloat(columns) * (diameter + 4)
    return min(ceil(widest) + 2, 140, max(48, roomForName))
}

/// One size for every ring: 40 points, smaller when that many columns would not fit beside a 48-point name column.
private func quotaRingDiameter(columns: Int) -> CGFloat {
    let room = QuotaList.cardWidth - QuotaRing.nameSpacing - 48
    return min(40, max(26, room / CGFloat(max(columns, 1)) - 4))
}

/// A ring's caption: the model or quota it is for, else the window's length.
func ringLabel(_ window: LimitWindow, detail: String?) -> String {
    // A model's 5-hour window needs its own column beside the model's Weekly one.
    if let detail { return window.windowMinutes == LimitWindow.sessionMinutes ? detail + " 5h" : detail }
    switch window.windowMinutes {
    case LimitWindow.sessionMinutes?: return "5h"
    case LimitWindow.weeklyMinutes?: return "Week"
    // A window without a length is a spending pool, such as Claude's usage credits.
    case nil: return "Credit"
    default: return compactWindowLabel(window)
    }
}

/// Why an idle row shows its last reading: Kiro renews its own sign-in when it next runs; Claude's lapsed for good.
private func idleReason(_ provider: String) -> String {
    provider == "Kiro" ? "Kiro has not run since; it renews its sign-in when it next does" : "Sign-in expired; showing its last reading"
}

/// A ring's center shows the time to its reset, so its hover starts with the used percentage and exact countdown.
private func ringHelp(_ window: LimitWindow, help: String) -> String {
    ["\(Int(window.usedPercent.rounded()))% used", window.amounts ?? "", resetText(window.resetsAt), help]
        .filter { !$0.isEmpty }.joined(separator: "\n")
}

/// A ring's center: the time left until its window resets, such as `45m`, `1.6h` or `3.2d`, with one decimal
/// below 10 so it fits the ring; the used percentage when no reset is ahead.
func ringCenterText(_ window: LimitWindow, now: Date) -> String {
    guard let reset = window.resetsAt, reset > now else { return "\(Int(window.usedPercent.rounded()))%" }
    // Rounded up, so a window resetting within the minute reads `1m`, never `0m`.
    let minutes = (reset.timeIntervalSince(now) / 60).rounded(.up)
    if minutes < 60 { return "\(Int(minutes))m" }
    // Each unit is chosen after rounding, so 9.97 hours reads `10h`, not `10.0h`, and 23.9 hours `1.0d`, not `24h`.
    func rounded(_ value: Double) -> Double { value < 9.95 ? (value * 10).rounded() / 10 : value.rounded() }
    func amount(_ value: Double) -> String { value < 9.95 ? String(format: "%.1f", value) : "\(Int(value.rounded()))" }
    let hours = minutes / 60
    return rounded(hours) < 24 ? amount(hours) + "h" : amount(hours / 24) + "d"
}

private func compactWindowLabel(_ window: LimitWindow) -> String {
    if window.windowMinutes == LimitWindow.weeklyMinutes { return "Weekly" }
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
    /// `chart` adds rows of cost and tokens above the text.
    func hoverHelp(_ text: String, chart: [PeriodUsage] = []) -> some View {
        let spoken = chart.map { "\($0.label): \(usdText($0.usd)), \(compactTokens($0.tokens)) tokens" } + [text]
        return overlay(HoverTracker(content: HoverContent(text: text, chart: chart)))
            .accessibilityHint(spoken.filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}

struct HoverContent: Equatable {
    var text: String
    var chart: [PeriodUsage]
}

private func usdText(_ value: Double?) -> String {
    value.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(2))) } ?? "--"
}

private struct HoverTracker: NSViewRepresentable {
    let content: HoverContent

    func makeNSView(context: Context) -> HoverTrackingView { HoverTrackingView() }

    func updateNSView(_ view: HoverTrackingView, context: Context) { view.content = content }
}

private final class HoverTrackingView: NSView {
    // A refresh can change the text under a still pointer, so the shown tip follows it.
    var content = HoverContent(text: "", chart: []) { didSet { if isInside, content != oldValue { report() } } }
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
        guard let window, !content.text.isEmpty || !content.chart.isEmpty else { return HoverTip.shared.exit(self) }
        HoverTip.shared.enter(self, content: content, rect: window.convertToScreen(convert(bounds, to: nil)), menu: window.frame)
    }
}

/// A tooltip window above the open status menu, placed beside it so it never covers the panel.
@MainActor
final class HoverTip {
    static let shared = HoverTip()
    private let panel: NSPanel
    private let tipView = NSHostingController(rootView: HoverTipView(content: HoverContent(text: "", chart: [])))
    private var timer: Timer?
    // Areas the pointer is inside. Enter and exit events arrive in any order, so the smallest area, the
    // innermost, wins, and leaving a button inside a row returns to the row's text.
    private var entered: [(owner: ObjectIdentifier, content: HoverContent, rect: NSRect, menu: NSRect)] = []

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
        // Sized and placed by hand in present(); a view with layout constraints here would resize the panel.
        tipView.sizingOptions = []
        background.addSubview(tipView.view)
        panel.contentView = background
    }

    func enter(_ owner: NSView, content: HoverContent, rect: NSRect, menu: NSRect) {
        let id = ObjectIdentifier(owner)
        entered.removeAll { $0.owner == id }
        entered.append((id, content, rect, menu))
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
        tipView.rootView = HoverTipView(content: tip.content)
        let fitting = tipView.sizeThatFits(in: NSSize(width: width + 16, height: screen.height - 12))
        let size = NSSize(width: ceil(fitting.width), height: min(ceil(fitting.height), screen.height - 12))
        var x = left >= right ? tip.menu.minX - size.width - 6 : tip.menu.maxX + 6
        x = min(max(x, screen.minX + 6), screen.maxX - size.width - 6)
        let y = min(max(tip.rect.maxY - size.height, screen.minY + 6), screen.maxY - size.height - 6)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        tipView.view.frame = NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()
    }
}

/// The tip's text, under a chart of cost and tokens per period when there is one.
/// Each row's bar is sized by cost; All stacks Claude and Codex in their panel colors.
private struct HoverTipView: View {
    let content: HoverContent

    var body: some View {
        let peak = content.chart.map { $0.segments.reduce(0) { $0 + $1.usd } }.max() ?? 0
        VStack(alignment: .leading, spacing: 6) {
            if !content.chart.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    ForEach(content.chart, id: \.label) { row in
                        GridRow {
                            Text(row.label)
                            HStack(spacing: 0) {
                                ForEach(row.segments, id: \.provider) { part in
                                    Rectangle()
                                        .fill(part.provider == .codex ? Palette.codex : Palette.claude)
                                        .frame(width: peak > 0 ? 120 * part.usd / peak : 0)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .frame(width: 120, height: 8, alignment: .leading)
                            Text(usdText(row.usd)).gridColumnAlignment(.trailing)
                            Text(compactTokens(row.tokens)).gridColumnAlignment(.trailing)
                        }
                        .fontWeight(row == content.chart.last ? .semibold : nil)
                    }
                }
            }
            if !content.text.isEmpty {
                Text(content.text)
            }
        }
        .font(Font(NSFont.toolTipsFont(ofSize: 0)))
        .monospacedDigit()
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
