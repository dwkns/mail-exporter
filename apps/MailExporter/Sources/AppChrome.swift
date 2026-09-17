import AppKit
import SwiftUI

/// Squircle glyph used on Export chips and job rows. One accent tint — not a rainbow.
struct JobGlyph: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(tint)
            )
            .accessibilityHidden(true)
    }
}

/// Quiet well chip. Label first, icon on the left (standard Mac).
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
                            .tint(style == .primary ? Color.white : Color.primary)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(style == .primary ? Color.white : Color.secondary)
                            .frame(width: 22, height: 22)
                    }
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style == .primary ? Color.white : Color.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: width, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        style == .primary
                            ? Color.clear
                            : Color(nsColor: .separatorColor).opacity(0.55),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.42)
        .disabled(!enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
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

/// Symbol then title — standard Mac button order.
struct LeadingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == LeadingIconLabelStyle {
    static var leadingIcon: LeadingIconLabelStyle { LeadingIconLabelStyle() }
    static var trailingIcon: LeadingIconLabelStyle { LeadingIconLabelStyle() }
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
