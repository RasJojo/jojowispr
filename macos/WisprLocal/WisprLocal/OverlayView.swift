import SwiftUI

struct OverlayView: View {
    @EnvironmentObject private var model: OverlayUIModel

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            HStack(spacing: 12) {
                statusIcon
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                VStack(alignment: .leading, spacing: 6) {
                    Text(statusText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)

                    levelBar
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 360, height: 72)
    }

    private var statusText: String {
        if let message = model.message, !message.isEmpty {
            return message
        }
        switch model.mode {
        case .listening: return "Dictating..."
        case .transcribing: return "Transcribing..."
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if model.message != nil {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
        } else {
            switch model.mode {
            case .listening:
                Image(systemName: "mic.fill")
                    .symbolRenderingMode(.hierarchical)
            case .transcribing:
                Image(systemName: "waveform")
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }

    private var levelBar: some View {
        let w: CGFloat = 180
        let h: CGFloat = 6
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.16))
                .frame(width: w, height: h)

            Capsule()
                .fill(Color.white.opacity(0.72))
                .frame(width: max(8, w * CGFloat(model.level)), height: h)
        }
        .animation(.easeOut(duration: 0.08), value: model.level)
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

