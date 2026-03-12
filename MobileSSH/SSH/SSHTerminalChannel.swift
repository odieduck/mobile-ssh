import Foundation
import NIOCore
import NIOSSH

// MARK: - Channel Handler

final class SSHTerminalChannelHandler: ChannelDuplexHandler {
    typealias InboundIn  = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn  = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let initialCols: Int
    private let initialRows: Int

    // 0 = sent PTY request, waiting for success
    // 1 = sent shell request, waiting for success
    // 2 = ready for I/O
    private var setupStage = 0

    // Stored so resize() can be called without a context parameter
    private var channelContext: ChannelHandlerContext?

    // Pending resize to send once shell is confirmed ready
    private var pendingResize: (cols: Int, rows: Int)?

    var onData:  ((Data) -> Void)?
    var onClose: (() -> Void)?
    /// Fired (on the main thread) once the shell is fully ready for I/O.
    var onReady: (() -> Void)?

    init(cols: Int = 80, rows: Int = 24) {
        self.initialCols = cols
        self.initialRows = rows
    }

    // MARK: NIO lifecycle

    func channelActive(context: ChannelHandlerContext) {
        channelContext = context
        // Explicitly set the most important terminal modes so the remote PTY
        // behaves correctly regardless of server defaults:
        //   ECHO/ECHOE  – echo input and visually erase characters on backspace
        //   ICANON      – canonical (line-editing) mode
        //   ICRNL       – map CR → NL on input (Enter key works)
        //   ISIG        – enable Ctrl-C / Ctrl-Z signals
        //   VERASE=127  – DEL (0x7f) is the erase character (matches what
        //                 SwiftTerm sends for the Backspace key)
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: initialCols,
            terminalRowHeight: initialRows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([
                .ECHO:   1,
                .ECHOE:  1,
                .ECHOK:  1,
                .ICANON: 1,
                .ISIG:   1,
                .ICRNL:  1,
                .OPOST:  1,
                .ONLCR:  1,
                .VERASE: 127,
                .VINTR:  3,
                .VKILL:  21,
                .VEOF:   4,
                .VSUSP:  26,
            ])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if setupStage == 0 {
                setupStage = 1
                context.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.ShellRequest(wantReply: true),
                    promise: nil
                )
            } else if setupStage == 1 {
                setupStage = 2
                // Flush any resize that arrived before the shell was ready
                if let r = pendingResize {
                    pendingResize = nil
                    sendWindowChange(context: context, cols: r.cols, rows: r.rows)
                }
                // Notify TerminalViewController so it can send the exact SwiftTerm dimensions
                let captured = onReady
                DispatchQueue.main.async { captured?() }
            }
        case is ChannelFailureEvent:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard channelData.type == .channel,
              case .byteBuffer(var buf) = channelData.data,
              let bytes = buf.readBytes(length: buf.readableBytes) else { return }
        let captured = onData
        DispatchQueue.main.async { captured?(Data(bytes)) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        channelContext = nil
        let captured = onClose
        DispatchQueue.main.async { captured?() }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let captured = onClose
        DispatchQueue.main.async { captured?() }
        context.close(promise: nil)
    }

    // OutboundIn (ByteBuffer) → OutboundOut (SSHChannelData)
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))), promise: promise)
    }

    // MARK: Resize helpers

    /// Queue or immediately send a window-change. Safe to call on the NIO event loop thread.
    func requestResize(cols: Int, rows: Int) {
        guard setupStage == 2, let ctx = channelContext else {
            // Shell not ready yet — stash it; will be sent once the shell succeeds.
            pendingResize = (cols, rows)
            return
        }
        sendWindowChange(context: ctx, cols: cols, rows: rows)
    }

    private func sendWindowChange(context: ChannelHandlerContext, cols: Int, rows: Int) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0
            ),
            promise: nil
        )
    }
}

// MARK: - Public Terminal Channel Wrapper

final class SSHTerminalChannel {
    private let channel: Channel
    private let handler: SSHTerminalChannelHandler

    // Callbacks are always invoked on the main thread (dispatched in the handler)
    var onData:  ((Data) -> Void)? {
        get { handler.onData }
        set { handler.onData = newValue }
    }
    var onClose: (() -> Void)? {
        get { handler.onClose }
        set { handler.onClose = newValue }
    }
    var onReady: (() -> Void)? {
        get { handler.onReady }
        set { handler.onReady = newValue }
    }

    init(channel: Channel, handler: SSHTerminalChannelHandler) {
        self.channel = channel
        self.handler = handler
    }

    // Send raw bytes to the remote shell (call from any thread)
    func send(_ data: Data) async throws {
        var buf = channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        try await channel.writeAndFlush(buf)
    }

    // Notify the server of a terminal resize.
    // Safe to call from the main thread; NIO schedules on the event loop.
    // Queued automatically if the shell isn't ready yet.
    func resize(cols: Int, rows: Int) {
        channel.eventLoop.execute { [weak self] in
            self?.handler.requestResize(cols: cols, rows: rows)
        }
    }

    func close() async {
        try? await channel.close()
    }

    var isActive: Bool { channel.isActive }
}
