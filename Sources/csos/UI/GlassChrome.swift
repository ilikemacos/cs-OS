import AppKit
import SwiftUI

/// The Liquid Glass tab strip + toolbar.
///
/// All the translucency in cs-OS lives here. Everything in this file sits over
/// a static backdrop, so the compositor can cache the blur; the terminal grid
/// below is opaque and repaints independently.
///
/// Every Liquid Glass API used here (`GlassEffectContainer`, `.glassEffect`,
/// `.glassEffectID`, `.buttonStyle(.glass)`) is macOS 26+. The deployment floor
/// is macOS 14, so each one is gated with a material fallback rather than
/// raising the floor and cutting off 4GB-class Intel machines.
struct GlassChrome: View {
    @Bindable var store: SessionStore
    @Namespace private var glassNamespace

    /// Parallax offset driven by terminal scroll, clamped to 4pt. Any more and
    /// it stops reading as depth and starts reading as a bug.
    private var parallax: CGFloat {
        let p = store.current?.scrollPosition ?? 0
        return min(max(CGFloat(p) * 8 - 4, -4), 4)
    }

    var body: some View {
        bar
            .offset(y: parallax * 0.5)
            .animation(.smooth(duration: 0.28), value: parallax)
    }

    @ViewBuilder
    private var bar: some View {
        let content = HStack(spacing: 10) {
            tabStrip
            Spacer(minLength: 8)
            newTabButton
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.chromeHeight)

        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.sessions) { session in
                    TabChip(
                        session: session,
                        isSelected: session.id == store.selected,
                        namespace: glassNamespace,
                        select: { store.selected = session.id },
                        close: { store.close(session) }
                    )
                }
            }
            .padding(.vertical, 6)
        }
        .scrollClipDisabled()
    }

    /// With Containerization the user picks an OCI image, so this is a menu.
    /// The microVM backend has one bundled userland, so it degrades to a plain
    /// button rather than offering choices it cannot honour.
    @ViewBuilder
    private var newTabButton: some View {
        if BackendFactory.supportsImageSelection {
            Menu {
                ForEach(SessionStore.presets, id: \.self) { image in
                    Button(image.split(separator: "/").last.map(String.init) ?? image) {
                        store.newSession(image: image)
                    }
                }
            } label: {
                plusLabel
            } primaryAction: {
                store.newSession()
            }
            .menuStyle(.button)
            .modifier(GlassButtonStyle())
            .help("New Linux session")
        } else {
            Button { store.newSession() } label: { plusLabel }
                .modifier(GlassButtonStyle())
                .help("New Linux session")
        }
    }

    private var plusLabel: some View {
        Image(systemName: "plus")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 26, height: 26)
    }
}

/// `.buttonStyle(.glass)` is macOS 26 only; below it, a bordered button over a
/// thin material reads closest.
private struct GlassButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content
                .buttonStyle(.plain)
                .background(
                    .ultraThinMaterial,
                    in: .rect(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
    }
}

private struct TabChip: View {
    let session: Session
    let isSelected: Bool
    let namespace: Namespace.ID
    let select: () -> Void
    let close: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            StateDot(state: session.state)
            Text(session.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
            if hovering || isSelected {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .opacity(0.6)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .frame(minWidth: 96, maxWidth: 190)
        .modifier(ChipSurface(isSelected: isSelected, id: session.id, namespace: namespace))
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .animation(.smooth(duration: 0.22), value: isSelected)
    }
}

/// The chip's glass, with its morph identity. On macOS 26 the selected chip
/// morphs between positions instead of cross-fading, which is the whole reason
/// `glassEffectID` exists.
private struct ChipSurface: ViewModifier {
    let isSelected: Bool
    let id: Session.ID
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    isSelected
                        ? .regular.tint(Theme.accentColor.opacity(0.22)).interactive()
                        : .regular.interactive(),
                    in: .rect(cornerRadius: Theme.cornerRadius, style: .continuous)
                )
                .glassEffectID(id, in: namespace)
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: .rect(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(
                            Theme.accentColor.opacity(isSelected ? 0.45 : 0.10),
                            lineWidth: isSelected ? 1 : 0.5)
                )
        }
    }
}

private struct StateDot: View {
    let state: Session.State

    private var color: Color {
        switch state {
        case .idle, .exited: return Theme.mutedColor
        case .booting: return Theme.statusBooting
        case .running: return Theme.statusRunning
        case .failed: return Theme.statusFailed
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(state == .booting ? 0.5 : 1)
            .animation(
                state == .booting
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: state)
    }
}

/// `NSVisualEffectView` bridge for the window backdrop. `.underWindowBackground`
/// is what gives Liquid Glass something to refract; without it the chrome reads flat.
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
