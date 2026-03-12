import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// MARK: - Errors

enum SSHConnectionError: LocalizedError {
    case notConnected
    case authFailed
    case channelCreationFailed
    case handlerNotFound
    case connectionTimeout
    case hostKeyRejected
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to SSH server"
        case .authFailed: return "Authentication failed"
        case .channelCreationFailed: return "Failed to create SSH channel"
        case .handlerNotFound: return "SSH handler not found in pipeline"
        case .connectionTimeout: return "Connection timed out"
        case .hostKeyRejected: return "Host key rejected"
        case .unknown(let error): return "SSH error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Auth Delegates

final class SSHClientAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let authMethod: SSHAuthMethod
    private var authAttempted = false

    init(username: String, authMethod: SSHAuthMethod) {
        self.username = username
        self.authMethod = authMethod
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !authAttempted else {
            nextChallengePromise.succeed(nil)
            return
        }
        authAttempted = true

        switch authMethod {
        case .password(let password):
            guard availableMethods.contains(.password) else {
                nextChallengePromise.succeed(nil)
                return
            }
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .password(.init(password: password))
                )
            )

        case .privateKey(let pem):
            guard availableMethods.contains(.publicKey) else {
                nextChallengePromise.succeed(nil)
                return
            }
            do {
                let nioKey = try parseOpenSSHEd25519PrivateKey(pem: pem)
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(
                        username: username,
                        serviceName: "ssh-connection",
                        offer: .privateKey(.init(privateKey: nioKey))
                    )
                )
            } catch {
                nextChallengePromise.fail(error)
            }
        }
    }
}

final class SSHServerAuthDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        // TODO: Implement known-hosts verification for production security.
        // For now, accept all host keys (trust-on-first-use behavior).
        validationCompletePromise.succeed(())
    }
}

// MARK: - Connection Manager

@MainActor
final class SSHConnection: ObservableObject {
    @Published var isConnected = false
    @Published var statusMessage = ""

    private var channel: Channel?
    private let group: MultiThreadedEventLoopGroup

    init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        // Shut down the event loop group on a background thread.
        // Using DispatchQueue avoids blocking a Swift concurrency thread during shutdown.
        let g = group
        DispatchQueue.global(qos: .utility).async {
            try? g.syncShutdownGracefully()
        }
    }

    func connect(
        host: String,
        port: Int,
        username: String,
        authMethod: SSHAuthMethod
    ) async throws {
        statusMessage = "Connecting to \(host):\(port)..."

        let authDelegate = SSHClientAuthDelegate(username: username, authMethod: authMethod)
        let serverAuthDelegate = SSHServerAuthDelegate()

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                let sshHandler = NIOSSHHandler(
                    role: .client(.init(
                        userAuthDelegate: authDelegate,
                        serverAuthDelegate: serverAuthDelegate
                    )),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                return channel.pipeline.addHandler(sshHandler)
            }
            .connectTimeout(.seconds(30))

        do {
            let connectedChannel = try await bootstrap.connect(host: host, port: port).get()
            self.channel = connectedChannel
            self.isConnected = true
            self.statusMessage = "Connected"
        } catch {
            self.statusMessage = "Connection failed: \(error.localizedDescription)"
            throw SSHConnectionError.unknown(error)
        }
    }

    func openShell(cols: Int = 80, rows: Int = 24) async throws -> SSHTerminalChannel {
        guard let channel = channel else {
            throw SSHConnectionError.notConnected
        }

        // Get the NIOSSHHandler from the pipeline
        let sshHandler: NIOSSHHandler = try await withCheckedThrowingContinuation { cont in
            channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                switch result {
                case .success(let handler):
                    cont.resume(returning: handler)
                case .failure:
                    cont.resume(throwing: SSHConnectionError.handlerNotFound)
                }
            }
        }

        // Create a session channel
        let termHandler = SSHTerminalChannelHandler(cols: cols, rows: rows)
        let sessionChannel: Channel = try await withCheckedThrowingContinuation { cont in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            promise.futureResult.whenComplete { result in
                switch result {
                case .success(let ch):
                    cont.resume(returning: ch)
                case .failure(let err):
                    cont.resume(throwing: err)
                }
            }
            sshHandler.createChannel(promise) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SSHConnectionError.channelCreationFailed)
                }
                return childChannel.pipeline.addHandler(termHandler)
            }
        }

        return SSHTerminalChannel(channel: sessionChannel, handler: termHandler)
    }

    func disconnect() async {
        guard let channel = channel else { return }
        try? await channel.close()
        self.channel = nil
        self.isConnected = false
        self.statusMessage = "Disconnected"
    }
}
