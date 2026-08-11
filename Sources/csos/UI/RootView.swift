import SwiftUI

struct RootView: View {
    @Bindable var store: SessionStore

    var body: some View {
        ZStack {
            WindowBackdrop().ignoresSafeArea()

            VStack(spacing: 0) {
                GlassChrome(store: store)

                ZStack {
                    ForEach(store.sessions) { session in
                        TerminalPane(session: session)
                            // Keep every session's view alive so scrollback and
                            // running processes survive a tab switch.
                            .opacity(session.id == store.selected ? 1 : 0)
                            .allowsHitTesting(session.id == store.selected)
                    }
                }
                .clipShape(.rect(cornerRadius: Theme.cornerRadius, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
            }
        }
        .frame(minWidth: 620, minHeight: 380)
    }
}
