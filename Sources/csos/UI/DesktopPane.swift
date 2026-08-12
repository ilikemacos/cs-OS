import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

/// The macOS guest's screen, plus every state that precedes it.
struct DesktopPane: View {
    @Bindable var guest: MacGuest

    var body: some View {
        Group {
            switch guest.phase {
            case .idle, .stopped:
                ContentUnavailableView {
                    Label("macOS Desktop", systemImage: "macwindow.on.rectangle")
                } description: {
                    Text("Start a full macOS desktop where .dmg and .pkg installers work.")
                } actions: {
                    Button("Start") { Task { await guest.start() } }
                        .buttonStyle(.borderedProminent)
                }

            case .needsRestoreImage:
                setupView

            case .downloadingRestoreImage(let fraction):
                progressView(
                    title: "Downloading macOS…",
                    detail: "About 14 GB from Apple. This runs once.",
                    fraction: fraction,
                    cancel: { guest.cancelDownload() })

            case .preparing:
                progressView(title: "Preparing…", detail: "Creating the guest disk.", fraction: nil)

            case .installing(let fraction):
                progressView(
                    title: "Installing macOS…",
                    detail: "Takes 15–30 minutes. The restore image is deleted afterwards.",
                    fraction: fraction)

            case .running:
                if let machine = guest.virtualMachine {
                    VirtualMachineScreen(machine: machine)
                } else {
                    ProgressView()
                }

            case .failed(let message):
                ContentUnavailableView {
                    Label("macOS didn't start", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    Button("Try Again") { Task { await guest.start() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - First-run setup

    private var setupView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("macOS needs to be installed first")
                .font(.title3.weight(.semibold))

            // Say the real numbers up front rather than surprising someone
            // mid-download with 14GB of traffic.
            VStack(alignment: .leading, spacing: 6) {
                Label("~14 GB download from Apple, once", systemImage: "network")
                Label("~20 GB on disk once installed", systemImage: "internaldrive")
                Label("The 14 GB image is deleted after install", systemImage: "trash")
                Label("No sudo, no admin password", systemImage: "lock.open")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Button("Download macOS") {
                    Task { await guest.downloadLatestRestoreImage() }
                }
                .buttonStyle(.borderedProminent)

                Button("Use an .ipsw I already have…") { chooseLocalImage() }
            }
            .padding(.top, 4)
        }
        .padding(40)
    }

    private func chooseLocalImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a macOS restore image (.ipsw)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await guest.useLocalRestoreImage(at: url) }
    }

    private func progressView(
        title: String, detail: String, fraction: Double?, cancel: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            if let fraction {
                ProgressView(value: fraction) { Text(title) }
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 340)
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.large)
                Text(title).font(.headline)
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let cancel {
                Button("Cancel", action: cancel)
                    .padding(.top, 4)
            }
        }
        .padding(40)
    }
}

/// `VZVirtualMachineView` is the only way to see a graphical guest. It handles
/// its own drawing, keyboard and pointer routing; we only configure capture
/// behaviour and hand it the machine.
private struct VirtualMachineScreen: NSViewRepresentable {
    let machine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        // Send ⌘Tab, ⌘Space and friends to the guest while it has focus —
        // otherwise the host swallows exactly the keys you need in a desktop.
        view.capturesSystemKeys = true
        if #available(macOS 14.0, *) {
            // Let the guest resize its display to match the window instead of
            // letterboxing a fixed resolution.
            view.automaticallyReconfiguresDisplay = true
        }
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine {
            view.virtualMachine = machine
        }
    }
}
