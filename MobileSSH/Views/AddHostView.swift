import SwiftUI
import SwiftData

struct AddHostView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allHosts: [SSHHost]

    // Editing existing host or creating new
    var editingHost: SSHHost?

    // Form fields
    @State private var name: String = ""
    @State private var hostname: String = ""
    @State private var portString: String = "22"
    @State private var username: String = ""
    @State private var authType: SSHAuthType = .password
    @State private var password: String = ""
    @State private var privateKeyPEM: String = ""
    @State private var connectionType: SSHConnectionType = .direct
    @State private var tailscaleAddress: String = ""
    @State private var selectedJumpHostId: UUID? = nil
    @State private var notes: String = ""
    @State private var isFavorite: Bool = false
    @State private var uploadPath: String = "uploads"
    @State private var defaultDirectory: String = ""

    // UI state
    @State private var showingTestResult = false
    @State private var testResultMessage = ""
    @State private var testResultSuccess = false
    @State private var isTesting = false
    @State private var showingPrivateKeyInfo = false
    @State private var testConnection_conn: SSHConnection?  // retained for test duration

    var port: Int {
        let p = Int(portString) ?? 22
        return (1...65535).contains(p) ? p : 22
    }

    var portIsValid: Bool {
        if let p = Int(portString) { return (1...65535).contains(p) }
        return false
    }

    var jumpHosts: [SSHHost] {
        allHosts.filter { $0.id != editingHost?.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Basic Info
                Section("Connection") {
                    LabeledContent("Name") {
                        TextField("My Mac (optional)", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Hostname / IP") {
                        TextField("192.168.1.100 or hostname", text: $hostname)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                    LabeledContent("Port") {
                        TextField("22", text: $portString)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    LabeledContent("Username") {
                        TextField("username", text: $username)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }

                // MARK: Auth
                Section("Authentication") {
                    Picker("Auth Type", selection: $authType) {
                        ForEach(SSHAuthType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }

                    if authType == .password {
                        LabeledContent("Password") {
                            SecureField("password", text: $password)
                                .multilineTextAlignment(.trailing)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Private Key (PEM)")
                                    .font(.subheadline)
                                Spacer()
                                Button {
                                    showingPrivateKeyInfo = true
                                } label: {
                                    Image(systemName: "questionmark.circle")
                                        .foregroundColor(.secondary)
                                }
                            }
                            TextEditor(text: $privateKeyPEM)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(minHeight: 120)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )

                            HStack {
                                if privateKeyPEM.isEmpty {
                                    Text("Paste your Ed25519 private key (-----BEGIN OPENSSH PRIVATE KEY-----)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if let deviceKey = try? KeychainStore.getPrivateKey(for: SettingsView.deviceKeyID) {
                                    Button("Use Device Key") {
                                        privateKeyPEM = deviceKey
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }

                // MARK: Connection Type
                Section {
                    Picker("Connection Type", selection: $connectionType) {
                        ForEach(SSHConnectionType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch connectionType {
                    case .direct:
                        Text("Connect directly via the hostname above. Works on the same LAN or with port forwarding.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                    case .tailscale:
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Tailscale IP") {
                                TextField("100.x.x.x", text: $tailscaleAddress)
                                    .multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.decimalPad)
                            }
                            Text("Install Tailscale on your Mac and iPhone. Find your Mac's Tailscale IP in the Tailscale app (starts with 100.x).")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                    case .jumpHost:
                        if jumpHosts.isEmpty {
                            Text("No hosts available. Add a jump host first.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Picker("Jump Host", selection: $selectedJumpHostId) {
                                Text("None").tag(Optional<UUID>.none)
                                ForEach(jumpHosts) { host in
                                    Text(host.name.isEmpty ? host.hostname : host.name)
                                        .tag(Optional(host.id))
                                }
                            }
                        }
                        Text("SSH through a VPS or bastion host to reach this server.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Connection Type")
                }

                // MARK: Options
                Section("Options") {
                    Toggle("Favorite", isOn: $isFavorite)

                    LabeledContent("Default Directory") {
                        TextField("~/projects", text: $defaultDirectory)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Text("Automatically cd into this directory after connecting.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    LabeledContent("Upload Path") {
                        TextField("uploads", text: $uploadPath)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Text("Remote directory for file uploads. Relative to home directory, or use an absolute path (e.g. /tmp/uploads).")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes")
                            .font(.subheadline)
                        TextEditor(text: $notes)
                            .frame(minHeight: 60)
                            .font(.body)
                    }
                }

                // MARK: Test Connection
                Section {
                    Button {
                        testConnection()
                    } label: {
                        if isTesting {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Testing...")
                            }
                        } else {
                            Label("Test Connection", systemImage: "network")
                        }
                    }
                    .disabled(isTesting || hostname.isEmpty || username.isEmpty || !portIsValid)
                }
            }
            .navigationTitle(editingHost == nil ? "Add Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(hostname.isEmpty || username.isEmpty)
                }
            }
            .alert(testResultSuccess ? "Connection Successful" : "Connection Failed",
                   isPresented: $showingTestResult) {
                Button("OK") {}
            } message: {
                Text(testResultMessage)
            }
            .alert("Private Key Help", isPresented: $showingPrivateKeyInfo) {
                Button("OK") {}
            } message: {
                Text("On your Mac, run:\n\ncat ~/.ssh/id_ed25519\n\nCopy the entire output (including the BEGIN/END lines) and paste it here.\n\nIf you don't have a key, go to Settings > Generate SSH Key.")
            }
            .onAppear {
                loadExistingHost()
            }
        }
    }

    // MARK: - Load Existing

    private func loadExistingHost() {
        guard let host = editingHost else { return }
        name = host.name
        hostname = host.hostname
        portString = String(host.port)
        username = host.username
        authType = host.authType
        connectionType = host.connectionType
        tailscaleAddress = host.tailscaleAddress ?? ""
        selectedJumpHostId = host.jumpHostId
        notes = host.notes
        isFavorite = host.isFavorite
        uploadPath = host.effectiveUploadPath
        defaultDirectory = host.defaultDirectory ?? ""

        // Load from Keychain
        if authType == .password {
            password = (try? KeychainStore.getPassword(for: host.id)) ?? ""
        } else {
            privateKeyPEM = (try? KeychainStore.getPrivateKey(for: host.id)) ?? ""
        }
    }

    // MARK: - Save

    private func save() {
        let host: SSHHost
        if let existing = editingHost {
            host = existing
        } else {
            host = SSHHost()
            modelContext.insert(host)
        }

        host.name = name
        host.hostname = hostname
        host.port = port
        host.username = username
        host.authType = authType
        host.connectionType = connectionType
        host.tailscaleAddress = tailscaleAddress.isEmpty ? nil : tailscaleAddress
        host.jumpHostId = selectedJumpHostId
        host.notes = notes
        host.isFavorite = isFavorite
        host.uploadPath = uploadPath.isEmpty ? nil : uploadPath
        host.defaultDirectory = defaultDirectory.isEmpty ? nil : defaultDirectory

        // Save credentials to Keychain
        do {
            if authType == .password && !password.isEmpty {
                try KeychainStore.savePassword(password, for: host.id)
            } else if authType == .privateKey && !privateKeyPEM.isEmpty {
                try KeychainStore.savePrivateKey(privateKeyPEM, for: host.id)
            }
        } catch {
            // Keychain errors are non-fatal; show in notes for debugging
            print("Keychain save error: \(error)")
        }

        dismiss()
    }

    // MARK: - Test Connection

    private func testConnection() {
        guard !isTesting else { return }
        isTesting = true
        let conn = SSHConnection()
        testConnection_conn = conn  // retain strongly so NIO group isn't torn down mid-test
        Task {
            do {
                let testHost = buildTestHost()
                try await conn.connect(
                    host: testHost.effectiveHostname,
                    port: testHost.port,
                    username: testHost.username,
                    authMethod: try buildAuthMethod()
                )
                await conn.disconnect()
                testConnection_conn = nil
                testResultSuccess = true
                testResultMessage = "Successfully connected to \(testHost.effectiveHostname):\(testHost.port)"
                showingTestResult = true
                isTesting = false
            } catch {
                testConnection_conn = nil
                testResultSuccess = false
                testResultMessage = error.localizedDescription
                showingTestResult = true
                isTesting = false
            }
        }
    }

    private func buildTestHost() -> SSHHost {
        let h = SSHHost(
            name: name,
            hostname: hostname,
            port: port,
            username: username,
            authType: authType,
            connectionType: connectionType,
            tailscaleAddress: tailscaleAddress.isEmpty ? nil : tailscaleAddress
        )
        return h
    }

    private func buildAuthMethod() throws -> SSHAuthMethod {
        switch authType {
        case .password:
            return .password(password)
        case .privateKey:
            return .privateKey(privateKeyPEM)
        }
    }
}

#Preview {
    AddHostView()
        .modelContainer(for: SSHHost.self, inMemory: true)
}
