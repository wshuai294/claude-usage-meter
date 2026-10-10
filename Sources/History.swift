import Foundation

/// Persisted samples of the official percentages, so "today", "per day" and the weekly curve
/// come from real measurements rather than guesses.
struct HistorySample: Codable {
    let t: Date
    let v: [String: Double]   // limit id -> percent
}

@MainActor
final class UsageHistory {
    private(set) var samples: [HistorySample] = []
    private let url: URL = {
        // CLAUDE_USAGE_HISTORY overrides the file (used for snapshot testing).
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_USAGE_HISTORY"] { return URL(fileURLWithPath: custom) }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            samples = (try? decoder.decode([HistorySample].self, from: data)) ?? []
        }
    }

    /// Records a sample when any value changed, or at least every 15 minutes.
    func record(_ plan: PlanSnapshot, at now: Date) {
        let values = Dictionary(plan.weeklyLimits.map { ($0.id, $0.percent) }, uniquingKeysWith: { a, _ in a })
        guard !values.isEmpty else { return }
        if let last = samples.last, last.v == values, now.timeIntervalSince(last.t) < 15 * 60 { return }
        samples.append(HistorySample(t: now, v: values))
        let cutoff = now.addingTimeInterval(-15 * 86400)
        samples.removeAll { $0.t < cutoff }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(samples) { try? data.write(to: url, options: .atomic) }
    }
}
