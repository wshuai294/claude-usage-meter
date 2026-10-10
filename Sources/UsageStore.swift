import SwiftUI
import ServiceManagement

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var plan: PlanSnapshot?
    @Published private(set) var planError: String?
    @Published private(set) var planUpdatedAt: Date?
    @Published private(set) var planLoading = false
    @Published private(set) var insights: Insights?
    @Published private(set) var now = Date()
    @Published var widgetVisible = false

    @Published var refreshInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            schedulePlanTimer()
        }
    }

    private let planService = PlanUsageService()
    private let history = UsageHistory()
    private var planTimer: Timer?
    private var tickTimer: Timer?
    private var retryTimer: Timer?
    private var failures = 0
    private var blockedUntil: Date?   // after a 429, automatic refreshes wait until this

    private init() {
        let saved = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = saved >= 60 ? saved : 1800
    }

    var weekly: LimitItem? { plan?.weekly }
    /// Per-model weekly limits (e.g. Fable), excluding the all-models one.
    var modelLimits: [LimitItem] { plan?.weeklyLimits.filter { $0.kind != "weekly_all" } ?? [] }

    func start() {
        if let (snap, fetched) = PlanUsageService.loadCache() {
            plan = snap
            planUpdatedAt = fetched
            recompute()
        }
        // Restarting shouldn't hit the endpoint again if the cached numbers are recent.
        if planUpdatedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true { refreshPlan() }
        schedulePlanTimer()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in UsageStore.shared.recompute() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { _ in
            Task { @MainActor in UsageStore.shared.refreshPlan() }
        }
    }

    private func schedulePlanTimer() {
        planTimer?.invalidate()
        planTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            Task { @MainActor in UsageStore.shared.refreshPlan() }
        }
    }

    func refreshPlanIfStale() {
        if let t = planUpdatedAt, Date().timeIntervalSince(t) < 300 { return }
        refreshPlan()
    }

    /// Retries a failed refresh sooner than the regular interval, backing off 2 → 5 → 10 → 20 min.
    private func scheduleRetry(after explicit: TimeInterval?) {
        let steps: [TimeInterval] = [120, 300, 600, 1200]
        let delay = min(explicit ?? steps[min(failures - 1, steps.count - 1)], refreshInterval)
        blockedUntil = Date().addingTimeInterval(delay)
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in UsageStore.shared.refreshPlan() }
        }
    }

    /// `manual` (the refresh button) ignores the back-off after a rate limit.
    func refreshPlan(manual: Bool = false) {
        guard !planLoading else { return }
        if !manual, let until = blockedUntil, until > Date() { return }
        planLoading = true
        Task {
            let result = await planService.fetch()
            planLoading = false
            switch result {
            case .success(let snap):
                plan = snap
                planError = nil
                planUpdatedAt = Date()
                failures = 0
                blockedUntil = nil
                retryTimer?.invalidate()
                history.record(snap, at: Date())
            case .failure(let err):
                planError = err.message
                failures += 1
                if case .rateLimited(let after) = err {
                    scheduleRetry(after: after)
                } else if case .network = err {
                    scheduleRetry(after: nil)
                }
            }
            recompute()
        }
    }

    /// Fills the store with made-up numbers for README screenshots (`--snapshot <dir> --demo`); no network.
    func showDemo(plan: PlanSnapshot, history: [HistorySample], now: Date) {
        self.plan = plan
        self.now = now
        planUpdatedAt = now.addingTimeInterval(-60)
        widgetVisible = true
        insights = Insights.build(plan: plan, history: history, now: now)
    }

    func recompute() {
        now = Date()
        insights = Insights.build(plan: plan, history: history.samples, now: now)
    }

    // MARK: Launch at login

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("ClaudeUsage: launch-at-login change failed: \(error)")
        }
        objectWillChange.send()
    }
}
