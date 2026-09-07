import AppKit
import Combine
import Darwin
import SwiftUI

@main
enum TokenBarMain {
    static func main() {
        // A short-lived CLI process may close its input while a request is in flight.
        // Treat that as an ordinary I/O error instead of terminating the menu bar app.
        signal(SIGPIPE, SIG_IGN)
        if PreviewScenario.current() == nil {
            migrateLegacyStorage()
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    private static func migrateLegacyStorage() {
        let legacyDomain = "com.local.quotabarlite"
        let currentDomain = "com.local.tokenbar"
        let defaults = UserDefaults.standard
        let legacyValues = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        var currentValues = defaults.persistentDomain(forName: currentDomain) ?? [:]

        if currentValues[StorageKeys.snapshot] == nil {
            currentValues[StorageKeys.snapshot] = currentValues["quotabar-lite.snapshot.v1"]
                ?? legacyValues["quotabar-lite.snapshot.v1"]
        }
        for key in currentValues.keys where StorageKeys.isObsolete(key) {
            currentValues.removeValue(forKey: key)
        }
        defaults.setPersistentDomain(currentValues, forName: currentDomain)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = TokenBarStore()
    private var statusPanel: StatusPanelController?
    private var usageItem: NSStatusItem?
    private var refreshScheduler: NSBackgroundActivityScheduler?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusPanel = StatusPanelController(
            contentViewController: NSHostingController(
                rootView: RootView().environmentObject(store)
            ),
            contentSize: TokenBarLayout.panelSize(for: store.snapshot)
        )
        statusPanel?.onOpen = { [weak self] in self?.store.refreshIfStale() }

        usageItem = makeStatusItem(toolTip: "Yellow: Claude · Blue: Codex · White: available")

        store.$snapshot
            .sink { [weak self] snapshot in
                self?.updateStatusItems()
                self?.statusPanel?.updateContentSize(
                    TokenBarLayout.panelSize(for: snapshot)
                )
            }
            .store(in: &cancellables)

        updateStatusItems()
        store.start()

        if PreviewScenario.current() != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self,
                      let item = self.usageItem
                else { return }
                self.statusPanel?.show(relativeTo: item)
            }
        }

        let scheduler = NSBackgroundActivityScheduler(
            identifier: "com.local.tokenbar.usage-refresh"
        )
        scheduler.repeats = true
        scheduler.interval = 10 * 60
        scheduler.tolerance = 60
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                self?.store.refreshIfStale()
            }
            completion(.finished)
        }
        refreshScheduler = scheduler
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshScheduler?.invalidate()
        statusPanel?.hide()
    }

    private func makeStatusItem(toolTip: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = statusPanel?.menu
        item.button?.toolTip = toolTip
        item.button?.imagePosition = .imageOnly
        return item
    }

    private func updateStatusItems() {
        let claudePercent = mostConstrainedPercent(store.snapshot.claude)
        let codexPercent = mostConstrainedPercent(store.snapshot.codex)
        switch store.snapshot.presentation {
        case .claudeOnly:
            usageItem?.button?.image = singleGaugeImage(percent: claudePercent, color: gaugeClaude)
            usageItem?.button?.setAccessibilityLabel(
                "Claude usage gauge, \(accessibilityPercent(claudePercent))."
            )
        case .codexOnly:
            usageItem?.button?.image = singleGaugeImage(percent: codexPercent, color: gaugeCodex)
            usageItem?.button?.setAccessibilityLabel(
                "Codex usage gauge, \(accessibilityPercent(codexPercent))."
            )
        case .both, .none:
            usageItem?.button?.image = splitGaugeImage(
                leftPercent: claudePercent,
                rightPercent: codexPercent
            )
            usageItem?.button?.setAccessibilityLabel(
                "Split usage gauge. Yellow, \(accessibilityPercent(claudePercent)) Claude. "
                    + "Blue, \(accessibilityPercent(codexPercent)) Codex. White shows available quota."
            )
        }
    }

    private var gaugeClaude: NSColor {
        NSColor(srgbRed: 1, green: 0xD8 / 255, blue: 0x87 / 255, alpha: 1)
    }

    private var gaugeCodex: NSColor {
        NSColor(srgbRed: 0x60 / 255, green: 0xAF / 255, blue: 1, alpha: 1)
    }

    private func mostConstrainedPercent(_ snapshot: ProviderSnapshot) -> Double? {
        ([snapshot.shortWindow, snapshot.longWindow].compactMap { $0 } + snapshot.extraWindows)
            .map(\.usedPercent)
            .max()
    }

    private func accessibilityPercent(_ percent: Double?) -> String {
        percent.map { "\(Int($0.rounded())) percent used" } ?? "unavailable"
    }

    private func splitGaugeImage(leftPercent: Double?, rightPercent: Double?) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { [weak self] rect in
            guard let self else { return false }
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let rotationAngle: CGFloat = 35

            drawGaugeCenter(at: center)

            drawGaugeArc(
                center: center,
                startAngle: 110 + rotationAngle,
                endAngle: 250 + rotationAngle,
                percent: leftPercent,
                progressColor: gaugeClaude
            )
            drawGaugeArc(
                center: center,
                startAngle: 70 + rotationAngle,
                endAngle: -70 + rotationAngle,
                percent: rightPercent,
                progressColor: gaugeCodex
            )
            return true
        }

        image.isTemplate = false
        return image
    }

    private func singleGaugeImage(percent: Double?, color: NSColor) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { [weak self] rect in
            guard let self else { return false }
            let center = NSPoint(x: rect.midX, y: rect.midY)
            drawGaugeCenter(at: center)
            drawGaugeArc(
                center: center,
                startAngle: 75,
                endAngle: 355,
                percent: percent,
                progressColor: color
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    private func drawGaugeCenter(at center: NSPoint) {
        let centerCircle = NSBezierPath(
            ovalIn: NSRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
        )
        NSColor(srgbRed: 0xFF / 255, green: 0x5F / 255, blue: 0x5F / 255, alpha: 1)
            .setFill()
        centerCircle.fill()
    }

    private func drawGaugeArc(
        center: NSPoint,
        startAngle: CGFloat,
        endAngle: CGFloat,
        percent: Double?,
        progressColor: NSColor
    ) {
        let track = gaugeArcPath(
            center: center,
            radius: 8,
            startAngle: startAngle,
            endAngle: endAngle
        )
        track.lineWidth = 3
        track.lineCapStyle = .round
        NSColor(
            srgbRed: 0xEE / 255,
            green: 0xEE / 255,
            blue: 0xEE / 255,
            alpha: 1
        ).setStroke()
        track.stroke()

        guard let percent else { return }
        let clampedPercent = min(100, max(0, percent))
        guard clampedPercent > 0 else { return }
        let progressEnd = startAngle
            + (endAngle - startAngle) * CGFloat(clampedPercent) / 100
        let progress = gaugeArcPath(
            center: center,
            radius: 8,
            startAngle: startAngle,
            endAngle: progressEnd
        )
        progress.lineWidth = 3
        progress.lineCapStyle = .round
        progressColor.setStroke()
        progress.stroke()
    }

    private func gaugeArcPath(
        center: NSPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat
    ) -> NSBezierPath {
        let path = NSBezierPath()
        let span = endAngle - startAngle
        let segmentCount = max(1, Int(ceil(abs(span) / 4)))
        for segment in 0...segmentCount {
            let progress = CGFloat(segment) / CGFloat(segmentCount)
            let radians = (startAngle + span * progress) * .pi / 180
            let point = NSPoint(
                x: center.x + cos(radians) * radius,
                y: center.y + sin(radians) * radius
            )
            if segment == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        return path
    }
}

@MainActor
private final class StatusPanelController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    var onOpen: (() -> Void)?
    private let contentItem = NSMenuItem()
    private let contentViewController: NSViewController
    private(set) var isShown = false

    init(contentViewController: NSViewController, contentSize: NSSize) {
        self.contentViewController = contentViewController
        super.init()
        contentViewController.view.setFrameSize(contentSize)
        contentItem.view = contentViewController.view
        menu.addItem(contentItem)
        menu.autoenablesItems = false
        menu.delegate = self
    }

    func show(relativeTo item: NSStatusItem) {
        guard !isShown, let button = item.button else { return }
        button.performClick(nil)
    }

    func hide() {
        menu.cancelTracking()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isShown = true
        onOpen?()
    }

    func menuDidClose(_ menu: NSMenu) {
        isShown = false
    }

    func updateContentSize(_ size: NSSize) {
        guard contentViewController.view.frame.size != size else { return }
        contentViewController.view.setFrameSize(size)
    }
}
