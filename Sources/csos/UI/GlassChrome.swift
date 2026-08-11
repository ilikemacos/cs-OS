import SwiftUI

/// The Liquid Glass tab strip + toolbar.
///
/// All the translucency in cs-OS lives here. Everything in this file sits over
/// a static backdrop, so the compositor can cache the blur; the terminal grid
/// below is opaque and repaints independently.
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
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                tabStrip
                Spacer(minLength: 8)
                newTabButton
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.chromeHeight)
        }
        .offset(y: parallax * 0.5)
        .animation(.smooth(duration: 0.28), value: parallax)
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

    private var newTabButton: some View {
        Menu {
            ForEach(SessionStore.presets, id: \.self) { image in
                Button(image.split(separator: "/").last.map(String.init) ?? image) {
                    store.newSession(image: image)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
        } primaryAction: {
            store.newSession()
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .help("New Linux session")
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
        .glassEffect(
            isSelected
                ? .regular.tint(Theme.accentColor.opacity(0.22)).interactive()
                : .regular.interactive(),
            in: .rect(cornerRadius: Theme.cornerRadius, style: .continuous)
        )
        // Lets the selected chip morph between positions rather than cross-fade.
        .glassEffectID(session.id, in: namespace)
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .animation(.smooth(duration: 0.22), value: isSelected)
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
