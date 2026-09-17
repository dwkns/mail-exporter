import AppKit
import SwiftUI

/// Squircle glyph used on Export chips and job rows.
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

/// Quiet well chip (New Export / Export All / Choose Files). Label first, icon on the right.
enum PaneActionStyle {
    case primary
    case secondary
}

struct HeaderActionButton: View {
    let title: String
    let symbol: String
    var style: PaneActionStyle = .primary
    var enabled: Bool = true
    var spinning: Bool = false
    var width: CGFloat = 176
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style == .primary ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                ZStack {
                    if spinning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.72)
                            .tint(style == .primary ? Color.white : Color.primary)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(style == .primary ? Color.white : Color.secondary)
                            .frame(width: 28, height: 28)
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        style == .primary
                            ? Color.clear
                            : Color(nsColor: .separatorColor).opacity(0.55),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.42)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }

    private var fillColor: Color {
        switch style {
        case .primary:
            return hovering ? Color.accentColor.opacity(0.86) : Color.accentColor
        case .secondary:
            return hovering
                ? Color.primary.opacity(0.06)
                : Color(nsColor: .controlBackgroundColor)
        }
    }
}

/// Title then symbol — used on every text+icon button.
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title
            configuration.icon
        }
    }
}

extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: TrailingIconLabelStyle { TrailingIconLabelStyle() }
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
