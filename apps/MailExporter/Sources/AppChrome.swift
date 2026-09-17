import AppKit
import SwiftUI

/// Squircle glyph used on Export chips, job rows, and Settings groups.
struct JobGlyph: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(tint.gradient)
            )
            .accessibilityHidden(true)
    }
}

/// Quiet well chip (New / Export All, and matching Settings actions).
struct HeaderActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var enabled: Bool = true
    var spinning: Bool = false
    var width: CGFloat = 148
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    if spinning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.72)
                            .frame(width: 28, height: 28)
                    } else {
                        JobGlyph(symbol: symbol, tint: tint, size: 28)
                    }
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        hovering
                            ? Color.primary.opacity(0.06)
                            : Color(nsColor: .controlBackgroundColor)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.42)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// Inset grouped table used by the Export list and Settings sections.
struct GroupedWell<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
    }
}

struct GroupedWellDivider: View {
    var leading: CGFloat = 62

    var body: some View {
        Divider()
            .padding(.leading, leading)
            .padding(.trailing, 14)
    }
}

/// Empty the window title so traffic lights stay and the pane heading is the name.
struct HiddenWindowTitle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TitleHidingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TitleHidingView)?.hideTitle()
    }
}

private final class TitleHidingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideTitle()
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.hideTitle()
            }
        }
    }

    func hideTitle() {
        guard let window else { return }
        if !window.title.isEmpty {
            window.title = ""
        }
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
        }
    }
}
