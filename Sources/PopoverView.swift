import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: UsageStore
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            limitsSection
            if let ins = store.insights {
                Divider()
                statsTable(ins)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { store.refreshPlanIfStale() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude Usage").font(.system(size: 14, weight: .semibold))
            if let name = store.plan?.planName {
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            Spacer()
            if let t = store.planUpdatedAt {
                Text("Updated \(Fmt.ago(t, now: store.now))").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if snapshotMode {
                Image(systemName: "arrow.clockwise").frame(width: 16, height: 16).foregroundStyle(Color.accentColor)
            } else {
                refreshButton
            }
        }
    }

    private var refreshButton: some View {
        Button {
            store.refreshPlan(manual: true)
        } label: {
            if store.planLoading {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            } else {
                Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
            }
        }
        .buttonStyle(.borderless)
        .help("Refresh now")
    }

    // MARK: Weekly limits

    @ViewBuilder private var limitsSection: some View {
        if let plan = store.plan, let weekly = plan.weekly {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Weekly limits").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let r = weekly.resetsAt {
                        Text("Resets \(Fmt.dayTime.string(from: r)) · in \(Fmt.duration(r.timeIntervalSince(store.now)))")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                ForEach(plan.weeklyLimits) { item in
                    LimitRow(item: item, now: store.now, showReset: resetDiffers(item, from: weekly))
                }
                if !plan.breakdown.isEmpty {
                    Text("Used this week via: " + plan.breakdown.filter { $0.percent > 0 }
                        .map { "\($0.name) \(Int($0.percent))%" }.joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                if plan.source == .cliText {
                    Text("From `claude /usage` text; reset times unavailable.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        } else if store.planError == nil {
            HStack { ProgressView().controlSize(.small); Text("Fetching plan usage…").foregroundStyle(.secondary) }
                .font(.system(size: 12))
        }
        if let err = store.planError {
            Label(err, systemImage: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resetDiffers(_ item: LimitItem, from weekly: LimitItem) -> Bool {
        guard item.kind != weekly.kind, let a = item.resetsAt, let b = weekly.resetsAt else { return false }
        return abs(a.timeIntervalSince(b)) > 3600
    }

    // MARK: Stats

    private func statsTable(_ ins: Insights) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("")
                ForEach(ins.limits) { l in
                    Text(l.name)
                        .font(.system(size: 11, weight: .semibold))
                        .gridColumnAlignment(.trailing)
                }
            }
            statRow("Used today", help: "Increase in each weekly limit since midnight.",
                    ins.limits.map { delta($0.today) })
            statRow("Last 24 hours", help: "Increase in each weekly limit over the past 24 hours.",
                    ins.limits.map { delta($0.last24h) })
        }
    }

    private func delta(_ d: Double?) -> String {
        d.map { "+" + Fmt.pct($0) } ?? "–"
    }

    private func statRow(_ label: String, help: String, _ values: [String]) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).help(help)
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                Text(v).monospacedDigit().gridColumnAlignment(.trailing)
            }
        }
        .font(.system(size: 12))
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        if snapshotMode { snapshotFooter } else { liveFooter }
    }

    /// Static look-alike of the footer for screenshots.
    private var snapshotFooter: some View {
        HStack(spacing: 12) {
            Text("Desktop widget").font(.system(size: 11.5))
            Capsule().fill(Color.accentColor).frame(width: 26, height: 15)
                .overlay(alignment: .trailing) { Circle().fill(.white).padding(2) }
            Spacer()
            Image(systemName: "safari").foregroundStyle(Color.accentColor)
            Image(systemName: "gearshape").foregroundStyle(Color.accentColor)
        }
    }

    private var liveFooter: some View {
        HStack(spacing: 12) {
            Toggle("Desktop widget", isOn: Binding(
                get: { store.widgetVisible },
                set: { $0 ? WidgetController.shared.show() : WidgetController.shared.hide() }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11.5))
            Spacer()
            Button {
                NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
            } label: { Image(systemName: "safari") }
                .buttonStyle(.borderless)
                .help("Open claude.ai usage settings")
            Menu {
                Picker("Refresh every", selection: $store.refreshInterval) {
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                    Text("30 minutes").tag(1800.0)
                    Text("1 hour").tag(3600.0)
                }
                Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                Divider()
                Button("Quit Claude Usage") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
