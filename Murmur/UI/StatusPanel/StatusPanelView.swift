import SwiftUI

/// Murmur's brand colours, taken from the app icon (indigo → violet). Used
/// as accents on glyphs only; the pill itself stays frosted so it sits
/// quietly on any desktop.
enum MurmurBrand {
    static let indigo = Color(red: 86 / 255, green: 111 / 255, blue: 255 / 255)
    static let violet = Color(red: 122 / 255, green: 63 / 255, blue: 224 / 255)
    static let gradient = LinearGradient(colors: [indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Observable state behind `StatusPanelView`. Written only by `StatusPanel`.
@MainActor
final class StatusPanelModel: ObservableObject {
    @Published var state: PanelState = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: StatusPanelModel.barCount)
    @Published var elapsed: TimeInterval = 0

    static let barCount = 18

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
        elapsed = 0
    }
}

struct StatusPanelView: View {
    @ObservedObject var model: StatusPanelModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .hidden:
                EmptyView()
            case let .idle(idle):
                Image(systemName: idle.isWarning ? "exclamationmark.triangle.fill" : "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(idle.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(MurmurBrand.gradient))
                Text("Murmur")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                if !idle.hint.isEmpty {
                    Text(idle.hint)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 260)
                }
            case .recording:
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: .red.opacity(0.6), radius: 4)
                Waveform(levels: model.levels)
                    .frame(width: 90, height: 22)
                Text(timeString(model.elapsed))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            case let .working(label):
                ProgressView()
                    .controlSize(.small)
                    .tint(MurmurBrand.indigo)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            case let .message(text, _):
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        // Two subtle layers instead of one big halo: a hairline contact
        // shadow and a soft, low-opacity lift.
        .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        .padding(8) // room for the shadow inside the transparent panel
        .animation(.easeInOut(duration: 0.15), value: model.state)
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Level bars painted with the brand gradient across the whole strip (the
/// gradient is masked by the bars rather than applied per bar, so it flows
/// left to right instead of repeating on every capsule).
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        MurmurBrand.gradient
            .mask(
                HStack(alignment: .center, spacing: 2) {
                    ForEach(levels.indices, id: \.self) { i in
                        Capsule()
                            .frame(width: 3, height: max(3, CGFloat(levels[i]) * 22))
                    }
                }
                .animation(.linear(duration: 0.05), value: levels)
            )
    }
}
