import SwiftUI
import AppKit

/// A small floating desktop panel with the same live numbers as the menu bar popover.
@MainActor
final class WidgetController {
    static let shared = WidgetController()
    private var panel: WidgetPanel?
    private let frameName = "ClaudeUsageWidget"

    var onTop: Bool {
        get { UserDefaults.standard.object(forKey: "widgetOnTop") as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: "widgetOnTop")
            applyLevel()
            UsageStore.shared.objectWillChange.send()
        }
    }

    func restore() {
        if UserDefaults.standard.object(forKey: "widgetVisible") as? Bool ?? true { show() }
    }

    func show() {
        if panel == nil { makePanel() }
        keepOnScreen()
        panel?.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: "widgetVisible")
        UsageStore.shared.widgetVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: "widgetVisible")
        UsageStore.shared.widgetVisible = false
    }

    private func makePanel() {
        let host = NSHostingController(rootView: WidgetView().environmentObject(UsageStore.shared))
        host.sizingOptions = [.preferredContentSize]

        let p = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 170),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.contentViewController = host
        // Size to the content now, so the default position below uses the real width.
        p.setContentSize(host.view.fittingSize)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel = p
        applyLevel()

        if !p.setFrameUsingName(frameName) { moveToDefaultPosition(p) }
        p.setFrameAutosaveName(frameName)
        keepOnScreen()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in WidgetController.shared.keepOnScreen() }
        }
        // The content can grow after launch (e.g. once data arrives); keep the whole widget visible.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p, queue: .main) { _ in
            Task { @MainActor in WidgetController.shared.keepOnScreen() }
        }
    }

    private func moveToDefaultPosition(_ p: NSPanel) {
        // The primary display (the one with the menu bar), not whichever screen has focus right now.
        guard let vf = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame else { return }
        p.setFrameTopLeftPoint(NSPoint(x: vf.maxX - p.frame.width - 24, y: vf.maxY - 24))
    }

    /// Borderless panels aren't kept on screen by AppKit; a saved position from another display
    /// (or a resolution change) can leave the widget off-screen, so pull it back fully inside.
    func keepOnScreen() {
        guard let p = panel else { return }
        let f = p.frame
        let screen = NSScreen.screens.max {
            $0.visibleFrame.intersection(f).width * $0.visibleFrame.intersection(f).height
                < $1.visibleFrame.intersection(f).width * $1.visibleFrame.intersection(f).height
        }
        guard let vf = screen?.visibleFrame, !vf.intersection(f).isNull else { return moveToDefaultPosition(p) }
        let x = min(max(f.minX, vf.minX), vf.maxX - f.width)
        let y = min(max(f.minY, vf.minY), vf.maxY - f.height)
        if x != f.minX || y != f.minY { p.setFrameOrigin(NSPoint(x: x, y: y)) }
    }

    private func applyLevel() {
        guard let p = panel else { return }
        // "Desktop" mode sits just above the desktop icons and below normal windows, like a widget.
        p.level = onTop ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }
}

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        performDrag(with: event)
    }
}

struct WidgetView: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("Claude weekly limits").font(.system(size: 12, weight: .semibold))
                if let name = store.plan?.planName {
                    Text(name).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let err = store.planError {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(.secondary).help(err)
                }
                if let r = store.weekly?.resetsAt {
                    Text("resets in \(Fmt.duration(r.timeIntervalSince(store.now)))")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                RingGauge(item: store.weekly, label: "All models")
                ForEach(store.modelLimits.prefix(2)) { RingGauge(item: $0, label: $0.title) }
                details.padding(.top, 4)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(PanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .contextMenu {
            Button("Refresh now") {
                store.refreshPlan(manual: true)
            }
            Divider()
            Button {
                WidgetController.shared.onTop = true
            } label: {
                if WidgetController.shared.onTop { Label("Always on top", systemImage: "checkmark") } else { Text("Always on top") }
            }
            Button {
                WidgetController.shared.onTop = false
            } label: {
                if !WidgetController.shared.onTop { Label("On desktop (behind windows)", systemImage: "checkmark") } else { Text("On desktop (behind windows)") }
            }
            Divider()
            Button("Open claude.ai usage settings") {
                NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
            }
            Button("Hide widget (double-click the app to show again)") { WidgetController.shared.hide() }
            Button("Quit Claude Usage") { NSApp.terminate(nil) }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let today = store.insights?.all?.today {
                row("Today", "+" + Fmt.pct(today))
            }
            if let day = store.insights?.all?.last24h {
                row("Last 24h", "+" + Fmt.pct(day))
            }
            if let t = store.planUpdatedAt {
                Text("Updated \(Fmt.ago(t, now: store.now))").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
    }
}
