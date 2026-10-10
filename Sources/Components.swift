import SwiftUI

// MARK: - Limit bar

struct UsageBar: View {
    let percent: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(Palette.status(percent))
                    .frame(width: max(percent > 0 ? height : 0, geo.size.width * min(percent / 100, 1)))
            }
        }
        .frame(height: height)
    }
}

struct LimitRow: View {
    let item: LimitItem
    let now: Date
    var showReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.title).font(.system(size: 12, weight: .medium))
                Spacer()
                if item.percent >= 75 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.status(item.percent))
                }
                Text("\(Int(item.percent.rounded()))% used")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            UsageBar(percent: item.percent)
            if showReset, let r = item.resetsAt {
                Text("Resets \(Fmt.dayTime.string(from: r))").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Ring gauge (widget)

struct RingGauge: View {
    let item: LimitItem?
    let label: String
    var size: CGFloat = 64
    var line: CGFloat = 7

    var body: some View {
        let pct = item?.percent ?? 0
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: line)
                Circle()
                    .trim(from: 0, to: min(pct / 100, 1))
                    .stroke(Palette.status(pct), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(item.map { "\(Int($0.percent.rounded()))%" } ?? "–")
                    .font(.system(size: size * 0.27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: size, height: size)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .animation(.easeOut(duration: 0.4), value: pct)
    }
}

// MARK: - Snapshot mode

/// True while rendering screenshots: AppKit-backed views (blur, buttons, switches, menus)
/// don't render through ImageRenderer, so views swap in plain SwiftUI look-alikes.
private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// The widget/popover background: live blur, or a flat fill in snapshot mode.
struct PanelBackground: View {
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        if snapshotMode {
            Color(light: 0xf4f4f6, dark: 0x29292c).opacity(0.94)
        } else {
            VisualEffectBackground()
        }
    }
}

// MARK: - Visual effect background (widget)

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
