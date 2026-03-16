import SwiftUI
import SwiftData

struct HostListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\SSHHost.lastConnected, order: .reverse)]) private var hosts: [SSHHost]

    @State private var showingAddHost = false
    @State private var editingHost: SSHHost?
    @State private var connectingHost: SSHHost?
    @State private var connectionError: String?
    @State private var showingConnectionError = false
    @State private var activeTerminalChannel: SSHTerminalChannel?
    @State private var activeHost: SSHHost?
    @State private var activeConnection: SSHConnection?   // Must stay alive for the session duration
    @State private var showingTerminal = false
    @State private var showingSettings = false
    #if DEBUG
    @State private var showingDebugTerminal = false
    #endif

    // MARK: - Grouped hosts

    private var favoriteHosts: [SSHHost] {
        hosts.filter(\.isFavorite)
    }

    private var recentHosts: [SSHHost] {
        hosts
            .filter { !$0.isFavorite && $0.lastConnected != nil }
            .prefix(5)
            .map { $0 }
    }

    private var allHosts: [SSHHost] {
        hosts.filter { !$0.isFavorite && $0.lastConnected == nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if hosts.isEmpty {
                    emptyStateView
                } else {
                    hostsList
                }
            }
            .navigationTitle("MobileSSH")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                #if DEBUG
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingDebugTerminal = true
                    } label: {
                        Image(systemName: "ladybug")
                    }
                }
                #endif
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAddHost = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddHost) {
                AddHostView()
            }
            .sheet(item: $editingHost) { host in
                AddHostView(editingHost: host)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .alert("Connection Error", isPresented: $showingConnectionError) {
                Button("OK") {}
            } message: {
                Text(connectionError ?? "Unknown error")
            }
            #if DEBUG
            .fullScreenCover(isPresented: $showingDebugTerminal) {
                NavigationStack {
                    DebugTerminalContainerView()
                        .navigationTitle("Debug Terminal")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Close") { showingDebugTerminal = false }
                            }
                        }
                }
            }
            #endif
            .fullScreenCover(isPresented: $showingTerminal, onDismiss: {
                // Clean up connection when terminal is dismissed
                Task {
                    await activeConnection?.disconnect()
                    activeConnection = nil
                    activeTerminalChannel = nil
                    activeHost = nil
                }
            }) {
                if let channel = activeTerminalChannel, let host = activeHost, let conn = activeConnection {
                    NavigationStack {
                        TerminalPresentationView(host: host, sshTerminalChannel: channel, sshConnection: conn)
                    }
                }
            }
        }
    }

    // MARK: - Hosts List

    private var hostsList: some View {
        List {
            if !favoriteHosts.isEmpty {
                Section("Favorites") {
                    ForEach(favoriteHosts) { host in
                        hostRow(host)
                    }
                }
            }

            if !recentHosts.isEmpty {
                Section("Recent") {
                    ForEach(recentHosts) { host in
                        hostRow(host)
                    }
                }
            }

            if !allHosts.isEmpty {
                Section("All Hosts") {
                    ForEach(allHosts) { host in
                        hostRow(host)
                    }
                }
            }

            if favoriteHosts.isEmpty && recentHosts.isEmpty && allHosts.isEmpty {
                // Edge case: hosts exist but don't fit categories
                Section {
                    ForEach(hosts) { host in
                        hostRow(host)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func hostRow(_ host: SSHHost) -> some View {
        Button {
            connect(to: host)
        } label: {
            HostRowView(host: host, isConnecting: connectingHost?.id == host.id)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteHost(host)
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Button {
                editingHost = host
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                toggleFavorite(host)
            } label: {
                Label(host.isFavorite ? "Unfavorite" : "Favorite",
                      systemImage: host.isFavorite ? "star.slash" : "star.fill")
            }
            .tint(.yellow)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No SSH Hosts")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add your first SSH host to get started.\nYou can connect via direct IP, Tailscale VPN, or a jump host.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            Button {
                showingAddHost = true
            } label: {
                Label("Add Host", systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Actions

    private func connect(to host: SSHHost) {
        guard connectingHost == nil else { return }
        connectingHost = host

        Task {
            do {
                let authMethod = try loadAuthMethod(for: host)
                let conn = SSHConnection()
                try await conn.connect(
                    host: host.effectiveHostname,
                    port: host.port,
                    username: host.username,
                    authMethod: authMethod
                )

                let (cols, rows) = estimatedTerminalDimensions()
                let channel = try await conn.openShell(cols: cols, rows: rows)

                // Update lastConnected
                host.lastConnected = Date()

                await MainActor.run {
                    activeTerminalChannel = channel
                    activeHost = host
                    activeConnection = conn   // Retain so NIO group stays alive
                    connectingHost = nil
                    showingTerminal = true
                }
            } catch {
                await MainActor.run {
                    connectingHost = nil
                    connectionError = error.localizedDescription
                    showingConnectionError = true
                }
            }
        }
    }

    private func loadAuthMethod(for host: SSHHost) throws -> SSHAuthMethod {
        switch host.authType {
        case .password:
            let password = try KeychainStore.getPassword(for: host.id)
            return .password(password)
        case .privateKey:
            let pem = try KeychainStore.getPrivateKey(for: host.id)
            return .privateKey(pem)
        }
    }

    private func deleteHost(_ host: SSHHost) {
        KeychainStore.delete(for: host.id)
        modelContext.delete(host)
    }

    private func toggleFavorite(_ host: SSHHost) {
        host.isFavorite.toggle()
    }

    /// Estimates terminal cols/rows from the screen size and monospaced font metrics.
    /// SwiftTerm will send the real dimensions once the terminal view is laid out,
    /// but a good initial estimate avoids a jarring resize when vim/tmux first starts.
    private func estimatedTerminalDimensions() -> (cols: Int, rows: Int) {
        let fontSize: CGFloat = UserDefaults.standard.double(forKey: "terminalFontSize") > 0
            ? CGFloat(UserDefaults.standard.double(forKey: "terminalFontSize")) : 13
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let cellWidth  = ("W" as NSString).size(withAttributes: [.font: font]).width
        let cellHeight = font.lineHeight

        // Screen bounds in the current orientation; subtract rough UI chrome (nav bar ~44 + status ~50 + toolbar ~50)
        let screen = UIScreen.main.bounds
        let usableWidth  = screen.width
        let usableHeight = screen.height - 150

        let cols = max(80, Int(usableWidth  / cellWidth))
        let rows = max(24, Int(usableHeight / cellHeight))
        return (cols, rows)
    }
}

// MARK: - Host Row View

struct HostRowView: View {
    let host: SSHHost
    let isConnecting: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(connectionTypeColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: connectionTypeIcon)
                    .foregroundColor(connectionTypeColor)
                    .font(.system(size: 18))
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(host.name.isEmpty ? host.hostname : host.name)
                        .font(.headline)
                        .lineLimit(1)
                    if host.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                }

                Text("\(host.username)@\(host.effectiveHostname):\(host.port)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if let lastConnected = host.lastConnected {
                    Text("Last: \(lastConnected.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Right side: badge + connecting indicator
            VStack(alignment: .trailing, spacing: 4) {
                ConnectionTypeBadge(connectionType: host.connectionType)

                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var connectionTypeColor: Color {
        switch host.connectionType {
        case .direct: return .blue
        case .tailscale: return .purple
        case .jumpHost: return .orange
        }
    }

    private var connectionTypeIcon: String {
        switch host.connectionType {
        case .direct: return "network"
        case .tailscale: return "shield.lefthalf.filled"
        case .jumpHost: return "arrow.triangle.branch"
        }
    }
}

struct ConnectionTypeBadge: View {
    let connectionType: SSHConnectionType

    var body: some View {
        Text(connectionType.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundColor(badgeColor)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch connectionType {
        case .direct: return .blue
        case .tailscale: return .purple
        case .jumpHost: return .orange
        }
    }
}

#Preview {
    HostListView()
        .modelContainer(for: SSHHost.self, inMemory: true)
}
