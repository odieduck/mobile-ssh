import Foundation
import NIOCore
import NIOSSH

// MARK: - SFTP Errors

enum SFTPError: LocalizedError {
    case notReady
    case subsystemFailed
    case protocolError(String)
    case serverError(UInt32, String)
    case fileReadError(String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "SFTP session not ready"
        case .subsystemFailed:
            return "Server rejected SFTP subsystem request"
        case .protocolError(let msg):
            return "SFTP protocol error: \(msg)"
        case .serverError(let code, let msg):
            let desc = SFTPStatusDescription(code)
            return msg.isEmpty ? "SFTP error: \(desc)" : "SFTP error: \(msg)"
        case .fileReadError(let msg):
            return "Cannot read file: \(msg)"
        case .unexpectedResponse:
            return "Unexpected SFTP response"
        }
    }
}

private func SFTPStatusDescription(_ code: UInt32) -> String {
    switch code {
    case 0: return "OK"
    case 1: return "EOF"
    case 2: return "No such file or directory"
    case 3: return "Permission denied"
    case 4: return "Failure"
    case 5: return "Bad message"
    case 6: return "No connection"
    case 7: return "Connection lost"
    case 8: return "Unsupported operation"
    default: return "Unknown error (\(code))"
    }
}

// MARK: - SFTP Response (internal)

fileprivate enum SFTPResponse {
    case handle(Data)
    case status(UInt32, String)
}

// MARK: - SFTP Channel Handler
//
// NIO ChannelDuplexHandler that:
//   1. Sends a SubsystemRequest("sftp") on channel activation
//   2. Sends SSH_FXP_INIT (v3) after subsystem success
//   3. Parses incoming SFTP packets and resumes async continuations
//   4. Wraps outbound ByteBuffers as SSHChannelData

final class SFTPChannelHandler: ChannelDuplexHandler {
    typealias InboundIn  = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn  = ByteBuffer
    typealias OutboundOut = SSHChannelData

    enum State {
        case initializing
        case ready
        case failed(Error)
    }

    private(set) var state: State = .initializing
    private var channelContext: ChannelHandlerContext?
    private var inBuffer = ByteBufferAllocator().buffer(capacity: 4096)
    private var nextRequestId: UInt32 = 1
    private var pendingResponses: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    var readyContinuation: CheckedContinuation<Void, Error>?
    private var subsystemConfirmed = false

    // MARK: - NIO Lifecycle

    func channelActive(context: ChannelHandlerContext) {
        channelContext = context
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true),
            promise: nil
        )
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if !subsystemConfirmed {
                subsystemConfirmed = true
                sendInit(context: context)
            }
        case is ChannelFailureEvent:
            state = .failed(SFTPError.subsystemFailed)
            readyContinuation?.resume(throwing: SFTPError.subsystemFailed)
            readyContinuation = nil
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard channelData.type == .channel,
              case .byteBuffer(var buf) = channelData.data else { return }
        inBuffer.writeBuffer(&buf)
        processIncoming()
    }

    func channelInactive(context: ChannelHandlerContext) {
        channelContext = nil
        failAll(SFTPError.protocolError("Channel closed"))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(error)
        context.close(promise: nil)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))),
            promise: promise
        )
    }

    // MARK: - INIT Handshake

    private func sendInit(context: ChannelHandlerContext) {
        // SSH_FXP_INIT: length(4) + type(1) + version(4)
        var buf = context.channel.allocator.buffer(capacity: 9)
        buf.writeInteger(UInt32(5))   // payload length = type(1) + version(4)
        buf.writeInteger(UInt8(1))    // SSH_FXP_INIT
        buf.writeInteger(UInt32(3))   // SFTP version 3
        context.writeAndFlush(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))),
            promise: nil
        )
    }

    // MARK: - Incoming Packet Parser

    private func processIncoming() {
        while inBuffer.readableBytes >= 5 {
            let readerIdx = inBuffer.readerIndex
            guard let length = inBuffer.getInteger(at: readerIdx, as: UInt32.self),
                  inBuffer.readableBytes >= Int(length) + 4 else {
                break // incomplete packet
            }

            // Consume the length prefix
            inBuffer.moveReaderIndex(forwardBy: 4)
            guard let typeByte = inBuffer.readInteger(as: UInt8.self) else { break }
            let payloadRemaining = Int(length) - 1

            if typeByte == 2 { // SSH_FXP_VERSION
                let _ = inBuffer.readInteger(as: UInt32.self) // server version
                // Skip any extensions
                let consumed = 4
                let skip = payloadRemaining - consumed
                if skip > 0 { inBuffer.moveReaderIndex(forwardBy: skip) }
                state = .ready
                readyContinuation?.resume()
                readyContinuation = nil
                continue
            }

            // All other types have a request-id after the type byte
            guard let requestId = inBuffer.readInteger(as: UInt32.self) else { break }

            switch typeByte {
            case 102: // SSH_FXP_HANDLE
                if let handleData = readSFTPString() {
                    pendingResponses.removeValue(forKey: requestId)?.resume(returning: .handle(handleData))
                } else {
                    let skip = payloadRemaining - 4
                    if skip > 0 { inBuffer.moveReaderIndex(forwardBy: skip) }
                }

            case 101: // SSH_FXP_STATUS
                if let code = inBuffer.readInteger(as: UInt32.self) {
                    let message: String
                    if let msgData = readSFTPString() {
                        message = String(data: msgData, encoding: .utf8) ?? ""
                    } else {
                        message = ""
                    }
                    let _ = readSFTPString() // language tag (optional, may fail at end-of-packet)
                    pendingResponses.removeValue(forKey: requestId)?
                        .resume(returning: .status(code, message))
                } else {
                    let skip = payloadRemaining - 4
                    if skip > 0 { inBuffer.moveReaderIndex(forwardBy: skip) }
                }

            default:
                // Unknown packet — skip it
                let consumed = 4 // requestId
                let skip = payloadRemaining - consumed
                if skip > 0 { inBuffer.moveReaderIndex(forwardBy: skip) }
            }
        }
    }

    private func readSFTPString() -> Data? {
        guard let length = inBuffer.readInteger(as: UInt32.self),
              length <= inBuffer.readableBytes,
              let bytes = inBuffer.readBytes(length: Int(length)) else {
            return nil
        }
        return Data(bytes)
    }

    // MARK: - Request helpers (called from event loop)

    func allocateRequestId() -> UInt32 {
        let id = nextRequestId
        nextRequestId += 1
        return id
    }

    fileprivate func registerContinuation(requestId: UInt32, continuation: CheckedContinuation<SFTPResponse, Error>) {
        pendingResponses[requestId] = continuation
    }

    // MARK: - Cleanup

    private func failAll(_ error: Error) {
        state = .failed(error)
        for (_, cont) in pendingResponses {
            cont.resume(throwing: error)
        }
        pendingResponses.removeAll()
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
    }
}

// MARK: - SFTPClient
//
// High-level async/await API for SFTP file uploads.
// Thread model: public methods can be called from any context;
// all NIO operations are dispatched to the channel's event loop.

final class SFTPClient {

    private let channel: Channel
    private let handler: SFTPChannelHandler

    init(channel: Channel, handler: SFTPChannelHandler) {
        self.channel = channel
        self.handler = handler
    }

    /// Blocks until the SFTP subsystem handshake completes (INIT→VERSION).
    func waitForReady() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            channel.eventLoop.execute {
                switch self.handler.state {
                case .ready:
                    cont.resume()
                case .failed(let error):
                    cont.resume(throwing: error)
                case .initializing:
                    self.handler.readyContinuation = cont
                }
            }
        }
    }

    /// Upload a local file to the remote server.
    ///
    /// - Parameters:
    ///   - localURL: File URL on the iOS device (may be security-scoped).
    ///   - remotePath: Full remote path including filename (e.g. "uploads/photo.jpg").
    ///   - progress: Called on the main thread with values 0.0…1.0.
    func upload(
        localURL: URL,
        remotePath: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        // Gain access to security-scoped resources (document picker files)
        let scoped = localURL.startAccessingSecurityScopedResource()
        defer { if scoped { localURL.stopAccessingSecurityScopedResource() } }

        guard let fileHandle = FileHandle(forReadingAtPath: localURL.path) else {
            throw SFTPError.fileReadError("Cannot open \(localURL.lastPathComponent)")
        }
        defer { fileHandle.closeFile() }

        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalBytes = (attrs[.size] as? UInt64) ?? 0
        guard totalBytes > 0 else {
            throw SFTPError.fileReadError("File is empty")
        }

        // SFTP OPEN (create + write + truncate)
        let handle = try await openFile(remotePath: remotePath)

        // SFTP WRITE in 32 KB chunks
        let chunkSize = 32_768
        var offset: UInt64 = 0

        while true {
            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            try await writeChunk(handle: handle, offset: offset, data: chunk)
            offset += UInt64(chunk.count)

            let fraction = min(1.0, Double(offset) / Double(totalBytes))
            await MainActor.run { progress(fraction) }
        }

        // SFTP CLOSE
        try await closeHandle(handle)
    }

    /// Create a directory on the remote server. Ignores "already exists" errors.
    func mkdir(_ path: String) async throws {
        let response = try await sendRequest { alloc, reqId in
            let pathBytes = Array(path.utf8)
            // SSH_FXP_MKDIR: type(1) + reqId(4) + string(4+N) + attrs(4, flags=0)
            let payloadLen = 1 + 4 + 4 + pathBytes.count + 4
            var buf = alloc.buffer(capacity: 4 + payloadLen)
            buf.writeInteger(UInt32(payloadLen))
            buf.writeInteger(UInt8(14))                   // SSH_FXP_MKDIR
            buf.writeInteger(reqId)
            buf.writeInteger(UInt32(pathBytes.count))
            buf.writeBytes(pathBytes)
            buf.writeInteger(UInt32(0))                   // ATTRS flags = 0 (no attrs)
            return buf
        }
        switch response {
        case .status(let code, _):
            // 0 = OK, 4 = Failure (often "already exists") — both acceptable
            if code != 0 && code != 4 {
                throw SFTPError.serverError(code, "Cannot create directory: \(path)")
            }
        case .handle:
            throw SFTPError.unexpectedResponse
        }
    }

    func close() async {
        try? await channel.close()
    }

    // MARK: - Private SFTP Operations

    private func openFile(remotePath: String) async throws -> Data {
        let response = try await sendRequest { alloc, reqId in
            let pathBytes = Array(remotePath.utf8)
            // SSH_FXP_OPEN: type(1) + reqId(4) + string(4+N) + pflags(4) + attrs(4+4)
            let payloadLen = 1 + 4 + 4 + pathBytes.count + 4 + 4 + 4
            var buf = alloc.buffer(capacity: 4 + payloadLen)
            buf.writeInteger(UInt32(payloadLen))
            buf.writeInteger(UInt8(3))                    // SSH_FXP_OPEN
            buf.writeInteger(reqId)
            buf.writeInteger(UInt32(pathBytes.count))
            buf.writeBytes(pathBytes)
            buf.writeInteger(UInt32(0x0000_001A))         // WRITE | CREAT | TRUNC
            buf.writeInteger(UInt32(0x0000_0004))         // ATTRS flags: SSH_FILEXFER_ATTR_PERMISSIONS
            buf.writeInteger(UInt32(0o644))               // permissions
            return buf
        }
        switch response {
        case .handle(let h):
            return h
        case .status(let code, let msg):
            throw SFTPError.serverError(code, msg.isEmpty ? "Cannot open remote file" : msg)
        }
    }

    private func writeChunk(handle: Data, offset: UInt64, data: Data) async throws {
        let response = try await sendRequest { alloc, reqId in
            let handleBytes = Array(handle)
            let dataBytes = Array(data)
            // SSH_FXP_WRITE: type(1) + reqId(4) + handle(4+N) + offset(8) + data(4+N)
            let payloadLen = 1 + 4 + 4 + handleBytes.count + 8 + 4 + dataBytes.count
            var buf = alloc.buffer(capacity: 4 + payloadLen)
            buf.writeInteger(UInt32(payloadLen))
            buf.writeInteger(UInt8(6))                    // SSH_FXP_WRITE
            buf.writeInteger(reqId)
            buf.writeInteger(UInt32(handleBytes.count))
            buf.writeBytes(handleBytes)
            buf.writeInteger(offset)                      // uint64 offset
            buf.writeInteger(UInt32(dataBytes.count))
            buf.writeBytes(dataBytes)
            return buf
        }
        switch response {
        case .status(let code, let msg):
            if code != 0 { throw SFTPError.serverError(code, msg) }
        case .handle:
            throw SFTPError.unexpectedResponse
        }
    }

    private func closeHandle(_ handle: Data) async throws {
        let response = try await sendRequest { alloc, reqId in
            let handleBytes = Array(handle)
            // SSH_FXP_CLOSE: type(1) + reqId(4) + handle(4+N)
            let payloadLen = 1 + 4 + 4 + handleBytes.count
            var buf = alloc.buffer(capacity: 4 + payloadLen)
            buf.writeInteger(UInt32(payloadLen))
            buf.writeInteger(UInt8(4))                    // SSH_FXP_CLOSE
            buf.writeInteger(reqId)
            buf.writeInteger(UInt32(handleBytes.count))
            buf.writeBytes(handleBytes)
            return buf
        }
        switch response {
        case .status(let code, let msg):
            if code != 0 { throw SFTPError.serverError(code, msg) }
        case .handle:
            throw SFTPError.unexpectedResponse
        }
    }

    // MARK: - Request/Response Bridge

    /// Builds an SFTP packet on the caller's context, then sends it on the NIO
    /// event loop and awaits the server response via a CheckedContinuation.
    /// The `build` closure receives a ByteBufferAllocator and the allocated request-id.
    private func sendRequest(
        build: @escaping @Sendable (ByteBufferAllocator, UInt32) -> ByteBuffer
    ) async throws -> SFTPResponse {
        try await withCheckedThrowingContinuation { cont in
            channel.eventLoop.execute {
                let requestId = self.handler.allocateRequestId()
                self.handler.registerContinuation(requestId: requestId, continuation: cont)
                let buf = build(self.channel.allocator, requestId)
                self.channel.writeAndFlush(buf, promise: nil)
            }
        }
    }
}
