import SwiftUI
import Foundation

struct SettingsView: View {
    // Fixed UUID used as the Keychain key for the device-generated SSH key pair.
    static let deviceKeyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    @Environment(\.dismiss) private var dismiss
    @AppStorage("terminalFontSize") private var fontSize: Double = 13
    @AppStorage("terminalTheme") private var terminalTheme: String = "dark"
    @AppStorage("defaultUsername") private var defaultUsername: String = ""

    @State private var showingKeyGenSheet = false
    @State private var generatedPublicKey: String = ""
    @State private var generatedPrivateKey: String = ""
    @State private var showingGeneratedKey = false
    @State private var showingCopied = false
    @State private var showingKeySaved = false
    @State private var keyGenError: String?
    @State private var showingTailscaleGuide = false
    @State private var showingVPSGuide = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Terminal
                Section("Terminal") {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(fontSize))pt")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $fontSize, in: 9...24, step: 1)

                    Picker("Theme", selection: $terminalTheme) {
                        Text("Dark").tag("dark")
                        Text("Solarized Dark").tag("solarized")
                        Text("Default").tag("default")
                    }

                    LabeledContent("Default Username") {
                        TextField("root", text: $defaultUsername)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }

                // MARK: SSH Keys
                Section("SSH Keys") {
                    Button {
                        generateKey()
                    } label: {
                        Label("Generate Ed25519 Key Pair", systemImage: "key.fill")
                    }

                    if showingGeneratedKey {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Public Key (add to Mac's authorized_keys):")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text(generatedPublicKey)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(6)

                            HStack {
                                Button {
                                    UIPasteboard.general.string = generatedPublicKey
                                    showingCopied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        showingCopied = false
                                    }
                                } label: {
                                    Label(showingCopied ? "Copied!" : "Copy Public Key",
                                          systemImage: showingCopied ? "checkmark" : "doc.on.doc")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    saveDeviceKeyToKeychain()
                                } label: {
                                    Label(showingKeySaved ? "Saved!" : "Save Key",
                                          systemImage: showingKeySaved ? "checkmark.seal.fill" : "key.fill")
                                }
                                .buttonStyle(.bordered)
                                .tint(.green)
                            }

                            Text("Tap 'Save Key' to store the private key in the iOS Keychain so you can select it when adding a host.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("Important: The private key below is shown only once per generation.")
                                .font(.caption)
                                .foregroundColor(.orange)

                            Text(generatedPrivateKey)
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(6)
                                .lineLimit(6)
                        }
                    }

                    if let error = keyGenError {
                        Text("Key generation failed: \(error)")
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    Text("How to authorize the key on your Mac:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("1. Generate a key pair above\n2. Copy the public key\n3. On your Mac, run:\n   mkdir -p ~/.ssh && echo 'PASTE_HERE' >> ~/.ssh/authorized_keys\n   chmod 600 ~/.ssh/authorized_keys")
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(6)
                        .textSelection(.enabled)
                }

                // MARK: Remote Access
                Section("Remote Access Setup") {
                    Button {
                        showingTailscaleGuide = true
                    } label: {
                        Label("Tailscale Setup Guide", systemImage: "shield.lefthalf.filled")
                    }

                    Button {
                        showingVPSGuide = true
                    } label: {
                        Label("VPS Reverse Tunnel Guide", systemImage: "arrow.triangle.branch")
                    }
                }

                // MARK: About
                Section("About") {
                    LabeledContent("Version") {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundColor(.secondary)
                    }
                    LabeledContent("Build") {
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingTailscaleGuide) {
                TailscaleGuideView()
            }
            .sheet(isPresented: $showingVPSGuide) {
                VPSGuideView()
            }
        }
    }

    private func generateKey() {
        do {
            let (privPEM, pubOpenSSH) = try generateEd25519KeyPair()
            generatedPrivateKey = privPEM
            generatedPublicKey = pubOpenSSH
            showingGeneratedKey = true
            showingKeySaved = false
            keyGenError = nil
        } catch {
            keyGenError = error.localizedDescription
        }
    }

    /// Saves the generated private key to the iOS Keychain under a fixed "device key" UUID.
    /// When adding a host, the user can choose to load this stored key.
    private func saveDeviceKeyToKeychain() {
        guard !generatedPrivateKey.isEmpty else { return }
        do {
            try KeychainStore.savePrivateKey(generatedPrivateKey, for: SettingsView.deviceKeyID)
            showingKeySaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showingKeySaved = false }
        } catch {
            keyGenError = "Keychain save failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Tailscale Guide

struct TailscaleGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    guideSection("What is Tailscale?") {
                        Text("Tailscale creates a secure private network (VPN mesh) between your devices using WireGuard. Your Mac and iPhone join the same Tailscale network, so you can SSH from anywhere as if you're on a local network.")
                    }

                    guideSection("Step 1: Set up Tailscale on your Mac") {
                        numberedStep(1, "Go to tailscale.com and create a free account")
                        numberedStep(2, "Download and install Tailscale for macOS")
                        numberedStep(3, "Sign in — your Mac gets a 100.x.x.x IP address")
                        numberedStep(4, "Enable SSH: System Settings → General → Sharing → Remote Login → ON")
                    }

                    guideSection("Step 2: Set up Tailscale on your iPhone") {
                        numberedStep(1, "Install Tailscale from the App Store")
                        numberedStep(2, "Sign in with the same account as your Mac")
                        numberedStep(3, "Your iPhone can now reach your Mac at its 100.x.x.x address")
                    }

                    guideSection("Step 3: Find your Mac's Tailscale IP") {
                        numberedStep(1, "On your Mac, open the Tailscale menu bar app")
                        numberedStep(2, "Your IP address is shown (e.g. 100.64.0.1)")
                        numberedStep(3, "Or run in Terminal: tailscale ip -4")
                    }

                    guideSection("Step 4: Add host in MobileSSH") {
                        numberedStep(1, "Tap + to add a new host")
                        numberedStep(2, "Enter your Mac's username and the 100.x.x.x IP")
                        numberedStep(3, "Set Connection Type to Tailscale")
                        numberedStep(4, "Enter the 100.x.x.x address in the Tailscale IP field")
                        numberedStep(5, "Use password or SSH key authentication")
                    }

                    guideSection("Tip: Keep Tailscale running") {
                        Text("Make sure Tailscale is running on both devices when you want to SSH. The free Tailscale plan supports up to 3 users and 100 devices — more than enough for personal use.")
                    }
                }
                .padding()
            }
            .navigationTitle("Tailscale Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - VPS Guide

struct VPSGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    guideSection("Overview") {
                        Text("If you have a VPS (e.g. DigitalOcean, Linode, AWS), you can create a reverse SSH tunnel so your iPhone can reach your Mac through the VPS's public IP.")
                    }

                    guideSection("Step 1: Set up reverse tunnel on your Mac") {
                        Text("On your Mac, run:")
                        codeBlock("ssh -R 2222:localhost:22 user@YOUR_VPS_IP -N")
                        Text("This forwards VPS port 2222 → your Mac's port 22.")
                        Text("To make it persistent, use autossh:")
                        codeBlock("brew install autossh\nautossh -M 0 -f -N -R 2222:localhost:22 user@YOUR_VPS_IP")
                    }

                    guideSection("Step 2: Configure VPS sshd") {
                        Text("On your VPS, edit /etc/ssh/sshd_config and add:")
                        codeBlock("GatewayPorts yes")
                        Text("Then restart: sudo systemctl restart sshd")
                    }

                    guideSection("Step 3: Add a Jump Host in MobileSSH") {
                        numberedStep(1, "First add your VPS as a host (Direct connection type)")
                        numberedStep(2, "Add your Mac as another host")
                        numberedStep(3, "For the Mac host: set Connection Type to Jump Host")
                        numberedStep(4, "Select your VPS as the jump host")
                        numberedStep(5, "Set hostname to localhost and port to 2222")
                    }

                    guideSection("Alternative: LaunchAgent for persistent tunnel") {
                        Text("Create ~/Library/LaunchAgents/com.autossh.plist to auto-start the tunnel when your Mac boots:")
                        codeBlock("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist ...>\n<plist version=\"1.0\">\n<dict>\n  <key>Label</key>\n  <string>com.autossh</string>\n  <key>ProgramArguments</key>\n  <array>\n    <string>/usr/local/bin/autossh</string>\n    <string>-M</string><string>0</string>\n    <string>-N</string>\n    <string>-R</string>\n    <string>2222:localhost:22</string>\n    <string>user@YOUR_VPS_IP</string>\n  </array>\n  <key>RunAtLoad</key><true/>\n  <key>KeepAlive</key><true/>\n</dict>\n</plist>")
                    }
                }
                .padding()
            }
            .navigationTitle("VPS Reverse Tunnel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Guide Helpers

@ViewBuilder
private func guideSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title)
            .font(.headline)
        content()
    }
    Divider()
}

@ViewBuilder
private func numberedStep(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
        Text("\(number).")
            .fontWeight(.semibold)
            .frame(width: 20, alignment: .leading)
        Text(text)
    }
    .font(.subheadline)
}

@ViewBuilder
private func codeBlock(_ code: String) -> some View {
    Text(code)
        .font(.system(size: 11, design: .monospaced))
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(6)
        .textSelection(.enabled)
}

#Preview {
    SettingsView()
}
