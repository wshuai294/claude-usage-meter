import SwiftUI
import AppKit

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = UsageStore.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            if let dir = Snapshot.outputDir {
                Snapshot.run(to: dir)
            } else {
                UsageStore.shared.start()
                WidgetController.shared.restore()
            }
        }
    }

    /// Double-clicking the app while it's already running brings the widget back (e.g. after "Hide widget").
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { WidgetController.shared.show() }
        return false
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let all = store.weekly?.percent
        let model = store.modelLimits.first
        HStack(spacing: 3) {
            Image(systemName: icon(all ?? 0))
            if let model {
                Text("\(fmt(all)) · \(model.title) \(fmt(model.percent))").monospacedDigit()
            } else {
                Text(fmt(all)).monospacedDigit()
            }
        }
    }

    private func fmt(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "–" }

    private func icon(_ pct: Double) -> String {
        switch pct {
        case ..<33: return "gauge.with.dots.needle.0percent"
        case ..<50: return "gauge.with.dots.needle.33percent"
        case ..<67: return "gauge.with.dots.needle.50percent"
        case ..<90: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }
}
