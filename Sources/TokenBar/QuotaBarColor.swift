import AppKit

enum QuotaBarColor {
    static let claude = NSColor(srgbRed: 0xE5 / 255, green: 0x39 / 255, blue: 0x35 / 255, alpha: 1)
    static let codex = NSColor(srgbRed: 0x2F / 255, green: 0x6E / 255, blue: 0xDB / 255, alpha: 1)

    static func at(_ percent: Double, base: NSColor) -> NSColor {
        let percent = min(100, max(0, percent))
        if percent <= 50 {
            return base.blended(withFraction: (50 - percent) / 50 * 0.55, of: .white) ?? base
        }
        return base.blended(withFraction: (percent - 50) / 50 * 0.35, of: .black) ?? base
    }
}
