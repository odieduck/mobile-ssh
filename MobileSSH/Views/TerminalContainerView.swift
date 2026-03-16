import SwiftUI
import UIKit

struct TerminalContainerView: UIViewControllerRepresentable {
    let hostTitle: String
    let sshTerminalChannel: SSHTerminalChannel
    let sshConnection: SSHConnection
    let uploadPath: String
    let defaultDirectory: String?
    var onConnectionClosed: (() -> Void)?

    func makeUIViewController(context: Context) -> TerminalViewController {
        TerminalViewController()
    }

    func updateUIViewController(_ uiViewController: TerminalViewController, context: Context) {
        uiViewController.hostTitle = hostTitle
        uiViewController.sshConnection = sshConnection
        uiViewController.uploadPath = uploadPath
        uiViewController.defaultDirectory = defaultDirectory
        if uiViewController.sshTerminalChannel == nil {
            uiViewController.onConnectionClosed = onConnectionClosed
            uiViewController.onDisconnect = onConnectionClosed
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
    let sshConnection: SSHConnection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TerminalContainerView(
            hostTitle: host.name.isEmpty ? host.hostname : host.name,
            sshTerminalChannel: sshTerminalChannel,
            sshConnection: sshConnection,
            uploadPath: host.effectiveUploadPath,
            defaultDirectory: host.defaultDirectory,
            onConnectionClosed: { dismiss() }
        )
        .toolbar(.hidden, for: .navigationBar)
    }
}
