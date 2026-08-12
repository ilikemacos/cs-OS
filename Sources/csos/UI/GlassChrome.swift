import AppKit
import SwiftUI

// Window materials.
//
// cs-OS uses the *native* unified toolbar for its chrome, which on macOS 26
// already gets Liquid Glass from the system — and on macOS 14/15 already gets
// the correct vibrancy. That is both more Mac-like and less code than the
// bespoke floating bar this file used to hold.
//
// What remains here is the window backdrop plus the two helpers used for
// non-toolbar surfaces (overlays, popovers), with a material fallback below 26.

/// `NSVisualEffectView` bridge for the window backdrop.
///
/// SwiftUI's `.background(.ultraThinMaterial)` cannot express `behindWindow`
/// blending, which is what lets the desktop show through the window instead of
/// the window's own contents. Without this the window reads as a flat black
/// rectangle and the toolbar has nothing to sample.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Liquid Glass panel treatment, with a material fallback below macOS 26.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = Theme.cornerRadius
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: .rect(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.30), .white.opacity(0.04)],
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 0.5))
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = Theme.cornerRadius,
                    interactive: Bool = false) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, interactive: interactive))
    }

    /// Groups sibling glass elements so their highlights merge rather than each
    /// sampling the backdrop independently. No-op below macOS 26.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}
