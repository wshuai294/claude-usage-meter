import Foundation
import SwiftUI

// MARK: - Plan limits (from Anthropic's usage endpoint)

struct LimitItem: Identifiable, Sendable {
    let kind: String
    let title: String
    let percent: Double
    let resetsAt: Date?
    let windowLength: TimeInterval?

    var id: String { kind + "|" + title }
    var isWeekly: Bool { windowLength == 7 * 86400 }

    var windowStart: Date? {
        guard let r = resetsAt, let w = windowLength else { return nil }
        return r.addingTimeInterval(-w)
    }
}

struct BreakdownRow: Identifiable, Sendable {
    let key: String
    let name: String
    let percent: Double
    var id: String { key }
}

struct PlanSnapshot: Sendable {
    var limits: [LimitItem]
    var breakdown: [BreakdownRow]
    var planName: String?
    var source: Source

    enum Source: Sendable { case api, cliText }

    var weekly: LimitItem? { limits.first { $0.kind == "weekly_all" } }
    /// The all-models weekly limit first, then per-model weekly limits.
    var weeklyLimits: [LimitItem] {
        (weekly.map { [$0] } ?? []) + limits.filter { $0.kind != "weekly_all" && $0.isWeekly }
    }
}

// MARK: - Model families (for colors)

enum ModelFamily {
    static let families = ["Fable", "Opus", "Sonnet", "Haiku", "Other"]

    static func family(_ model: String) -> String {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("mythos") { return "Fable" }
        if m.contains("opus") { return "Opus" }
        if m.contains("sonnet") { return "Sonnet" }
        if m.contains("haiku") { return "Haiku" }
        return "Other"
    }
}

// MARK: - Colors (model families keep one hue everywhere; status palette reserved for limit bars)

enum Palette {
    static func status(_ percent: Double) -> Color {
        switch percent {
        case ..<50: return Color(hex: 0x0ca30c)
        case ..<75: return Color(hex: 0xfab219)
        case ..<90: return Color(hex: 0xec835a)
        default: return Color(hex: 0xd03b3b)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                           green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

// MARK: - Formatting

enum Fmt {
    static func pct(_ v: Double) -> String {
        v < 10 && v > 0 ? String(format: "%.1f%%", v) : "\(Int(v.rounded()))%"
    }

    static func duration(_ s: TimeInterval) -> String {
        let total = max(Int(s), 0)
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = now.timeIntervalSince(date)
        return s < 60 ? "just now" : "\(duration(s)) ago"
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = format
        return f
    }

    static let dayTime = formatter("EEE h:mm a")
    static let dayHour = formatter("EEE h a")
    static let weekday = formatter("EEE")
    static let time = formatter("h:mm a")
}
