import SwiftUI
import AppKit

/// Screenshot aid: `ClaudeUsage --snapshot <dir> [--demo]` renders the popover and widget (light + dark)
/// to PNGs and quits. With `--demo` it uses made-up numbers and never touches the network or keychain,
/// and also renders the composed README images (`showcase-light.png`, `showcase-dark.png`).
@MainActor
enum Snapshot {
    static var outputDir: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static var demo: Bool { CommandLine.arguments.contains("--demo") }

    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if demo {
            loadDemo()
        } else {
            UsageStore.shared.start()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (demo ? 1 : 12)) {
            for scheme in [ColorScheme.light, .dark] {
                let name = scheme == .dark ? "dark" : "light"
                render(PopoverView().background(PanelBackground()), scheme: scheme, to: dir.appendingPathComponent("popover-\(name).png"))
                render(WidgetView().padding(20), scheme: scheme, to: dir.appendingPathComponent("widget-\(name).png"))
                if demo {
                    render(Showcase(), scheme: scheme, to: dir.appendingPathComponent("showcase-\(name).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func render<V: View>(_ view: V, scheme: ColorScheme, to url: URL) {
        let renderer = ImageRenderer(content: view
            .environmentObject(UsageStore.shared)
            .environment(\.snapshotMode, true)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Demo data

    private static func loadDemo() {
        let now = Date()
        let reset = now.addingTimeInterval(3 * 86400 + 4 * 3600)
        let week: TimeInterval = 7 * 86400
        let start = reset.addingTimeInterval(-week)
        let allNow = 46.0, fableShare = 0.83

        // Usage accrues mostly during the day; scale the cumulative curve to end at `allNow`.
        var t = start, raw = 0.0
        var points: [(Date, Double)] = []
        while t < now {
            let hour = Calendar.current.component(.hour, from: t)
            raw += (9..<23).contains(hour) ? 1 : 0.1
            points.append((t, raw))
            t = t.addingTimeInterval(1800)
        }
        let all = LimitItem(kind: "weekly_all", title: "All models", percent: allNow, resetsAt: reset, windowLength: week)
        let fable = LimitItem(kind: "weekly_scoped", title: "Fable", percent: allNow * fableShare, resetsAt: reset, windowLength: week)
        let history = points.map { date, r in
            let pct = (allNow * r / raw * 10).rounded() / 10
            return HistorySample(t: date, v: [all.id: pct, fable.id: (pct * fableShare * 10).rounded() / 10])
        }
        let plan = PlanSnapshot(
            limits: [all, fable],
            breakdown: [BreakdownRow(key: "claude_code", name: "Claude Code", percent: 82),
                        BreakdownRow(key: "chat", name: "Chat", percent: 15),
                        BreakdownRow(key: "cowork", name: "Cowork", percent: 3)],
            planName: "Max 5x",
            source: .api)
        UsageStore.shared.showDemo(plan: plan, history: history, now: now)
    }
}

/// README hero: a desktop with a menu bar, the open popover, and the widget.
private struct Showcase: View {
    @EnvironmentObject var store: UsageStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack(alignment: .top) {
            LinearGradient(colors: dark ? [Color(hex: 0x1d2b4f), Color(hex: 0x3b2a55)]
                                        : [Color(hex: 0x9cc7ef), Color(hex: 0xc9b8ea)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "apple.logo")
                    Text("Finder").fontWeight(.semibold)
                    Spacer()
                    MenuBarLabel(store: store)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                }
                .font(.system(size: 13))
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(Color(white: dark ? 0.1 : 1).opacity(0.35))

                HStack(alignment: .top, spacing: 40) {
                    WidgetView()
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                        .padding(.top, 40)
                    Spacer(minLength: 0)
                    PopoverView()
                        .background(PanelBackground())
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
        .frame(width: 880)
    }
}
