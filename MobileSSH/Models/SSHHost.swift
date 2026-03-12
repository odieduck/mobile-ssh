import Foundation
import SwiftData

enum SSHAuthType: String, Codable, CaseIterable {
    case password = "password"
    case privateKey = "privateKey"

    var displayName: String {
        switch self {
        case .password: return "Password"
        case .privateKey: return "Private Key"
        }
    }
}

enum SSHConnectionType: String, Codable, CaseIterable {
    case direct = "direct"
    case tailscale = "tailscale"
    case jumpHost = "jumpHost"

    var displayName: String {
        switch self {
        case .direct: return "Direct"
        case .tailscale: return "Tailscale"
        case .jumpHost: return "Jump Host"
        }
    }

    var badgeColor: String {
        switch self {
        case .direct: return "blue"
        case .tailscale: return "purple"
        case .jumpHost: return "orange"
        }
    }
}

@Model
final class SSHHost {
    var id: UUID
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var authType: SSHAuthType
    var connectionType: SSHConnectionType

    /// Tailscale IP address (e.g. "100.x.x.x") — fill in with your Mac's Tailscale IP
    var tailscaleAddress: String?

    /// UUID of the jump host, if connectionType == .jumpHost
    var jumpHostId: UUID?

    var isFavorite: Bool
    var lastConnected: Date?
    var createdAt: Date
    var notes: String

    init(
        id: UUID = UUID(),
        name: String = "",
        hostname: String = "",
        port: Int = 22,
        username: String = "",
        authType: SSHAuthType = .password,
        connectionType: SSHConnectionType = .direct,
        tailscaleAddress: String? = nil,
        jumpHostId: UUID? = nil,
        isFavorite: Bool = false,
        lastConnected: Date? = nil,
        createdAt: Date = Date(),
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authType = authType
        self.connectionType = connectionType
        self.tailscaleAddress = tailscaleAddress
        self.jumpHostId = jumpHostId
        self.isFavorite = isFavorite
        self.lastConnected = lastConnected
        self.createdAt = createdAt
        self.notes = notes
    }

    /// Returns the effective hostname to connect to based on connectionType
    var effectiveHostname: String {
        switch connectionType {
        case .tailscale:
            return tailscaleAddress ?? hostname
        case .direct, .jumpHost:
            return hostname
        }
    }
}
