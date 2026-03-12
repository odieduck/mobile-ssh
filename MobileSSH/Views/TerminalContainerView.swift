import SwiftUI
import UIKit

struct TerminalContainerView: UIViewControllerRepresentable {
    let sshTerminalChannel: SSHTerminalChannel
    var onConnectionClosed: (() -> Void)?

    func makeUIViewController(context: Context) -> TerminalViewController {
        let vc = TerminalViewController()
        return vc
    }

    func updateUIViewController(_ uiViewController: TerminalViewController, context: Context) {
        // Start session if not already started
        if uiViewController.sshTerminalChannel == nil {
            uiViewController.onConnectionClosed = onConnectionClosed
            uiViewController.startSession(sshTerminalChannel)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        // Future delegate callbacks can be bridged here
    }
}

// MARK: - Debug terminal (no SSH, triple-tap to inject test sequences)

#if DEBUG
struct DebugTerminalContainerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TerminalViewController {
        TerminalViewController()
    }
    func updateUIViewController(_ uiViewController: TerminalViewController, context: Context) {}
}
#endif

// MARK: - Full-screen terminal presentation wrapper

struct TerminalPresentationView: View {
    let host: SSHHost
    let sshTerminalChannel: SSHTerminalChannel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TerminalContainerView(
            sshTerminalChannel: sshTerminalChannel,
            onConnectionClosed: {
                dismiss()
            }
        )
        .navigationTitle(host.name.isEmpty ? host.hostname : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Disconnect") {
                    Task {
                        await sshTerminalChannel.close()
                        dismiss()
                    }
                }
                .foregroundColor(.red)
            }
        }
    }
}
