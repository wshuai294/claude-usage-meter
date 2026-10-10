import Foundation

/// "Used today" / "last 24 hours", derived from the recorded history of official weekly percentages.
struct Insights {
    struct Point: Identifiable {
        let date: Date
        let pct: Double
        var id: Date { date }
    }

    struct Limit: Identifiable {
        let item: LimitItem
        let family: String?        // nil = all models
        var today: Double?         // % increase since midnight (or since tracking began)
        var last24h: Double?
        var id: String { item.id }
        var name: String { item.title }
    }

    var limits: [Limit] = []
    var windowStart: Date

    var all: Limit? { limits.first { $0.family == nil } }

    static func build(plan: PlanSnapshot?, history: [HistorySample], now: Date) -> Insights? {
        guard let plan, let weekly = plan.weekly else { return nil }
        let start = weekly.windowStart ?? now.addingTimeInterval(-7 * 86400)
        var out = Insights(windowStart: start)
        let cal = Calendar.current

        for item in plan.weeklyLimits {
            let family: String? = item.kind == "weekly_all" ? nil : ModelFamily.family(item.title)
            var limit = Limit(item: item, family: family)
            let winStart = item.windowStart ?? start
            var pts = history.filter { $0.t >= winStart }.compactMap { s in s.v[item.id].map { Point(date: s.t, pct: $0) } }
            pts.append(Point(date: now, pct: item.percent))

            limit.today = delta(pts, from: max(cal.startOfDay(for: now), winStart), windowStart: winStart, now: now)
            limit.last24h = delta(pts, from: max(now.addingTimeInterval(-86400), winStart), windowStart: winStart, now: now)

            out.limits.append(limit)
        }
        return out
    }

    /// Last measured value at or before `date`; 0 exactly at the window start; nil if unknown.
    static func value(_ pts: [Point], at date: Date, windowStart: Date) -> Double? {
        if let p = pts.last(where: { $0.date <= date }) { return p.pct }
        return date <= windowStart ? 0 : nil
    }

    /// Increase since `from`; if tracking began later, the increase since the first sample.
    private static func delta(_ pts: [Point], from: Date, windowStart: Date, now: Date) -> Double? {
        guard let current = pts.last?.pct else { return nil }
        if let base = value(pts, at: from, windowStart: windowStart) { return current - base }
        guard let first = pts.first, first.date < now else { return nil }
        return current - first.pct
    }
}
