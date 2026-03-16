import UIKit
import SwiftTerm
import Combine
import PhotosUI
import UniformTypeIdentifiers

final class TerminalViewController: UIViewController {

    // MARK: - Properties

    var sshTerminalChannel: SSHTerminalChannel?
    var sshConnection: SSHConnection?
    var uploadPath: String = "uploads"
    var defaultDirectory: String?
    var onConnectionClosed: (() -> Void)?
    /// Called immediately when the user taps Disconnect (before channel close completes).
    var onDisconnect: (() -> Void)?

    var hostTitle: String = "Terminal" {
        didSet { headerTitleLabel?.text = hostTitle }
    }

    private var terminalView: SSHTerminalView!
    private var keyboardProxy: TerminalKeyboardProxy!
    private var keyboardToolbar: KeyboardToolbar!
    private var tmuxPanel: TmuxPanelInputView?
    private var headerBar: UIView!
    private var headerTitleLabel: UILabel!
    private var uploadProgressView: UIProgressView?
    private var uploadStatusLabel: UILabel?
    private var statusLabel: UILabel!
    private var statusOverlay: UIView!
    private var scrollToBottomButton: UIButton!
    private var scrollObserver: AnyCancellable?

    /// Last size successfully sent to the SSH server.  Used to suppress duplicate
    /// resize requests that fire from viewDidLayoutSubviews / sizeChanged / onReady.
    private var lastReportedSize: (cols: Int, rows: Int) = (0, 0)

    // MARK: - Write coalescing (Blink-style)
    //
    // SSH data arrives as many small packets dispatched individually to the main queue.
    // Feeding SwiftTerm once per packet causes dozens of intermediate draws with stale
    // scroll positions, making new output appear to overlap old output.
    //
    // Solution: accumulate incoming bytes in pendingFeed and schedule a single flush
    // per run-loop turn.  By the time flushFeed() runs, all packets that arrived in the
    // same NIO event-loop iteration are already in the buffer, so SwiftTerm receives one
    // large coherent update and draws once with a correct, final scroll position.
    private var pendingFeed = [UInt8]()
    private var feedPending = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        setupHeaderBar()
        setupTerminalView()
        setupStatusOverlay()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        keyboardProxy.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        keyboardProxy.resignFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Dispatch to next runloop tick so SwiftTerm has already recalculated
        // cols/rows from the new bounds before we forward them to SSH.
        DispatchQueue.main.async { [weak self] in
            self?.notifyTerminalSize()
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.notifyTerminalSize()
        }
    }

    // MARK: - Setup

    private func setupHeaderBar() {
        headerBar = UIView()
        // True Black — extends from screen top behind Dynamic Island / status bar
        headerBar.backgroundColor = .black
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)

        let sep = UIView()
        sep.backgroundColor = UIColor(white: 0.2, alpha: 1)
        sep.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(sep)

        headerTitleLabel = UILabel()
        headerTitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        headerTitleLabel.textColor = .white
        headerTitleLabel.text = hostTitle
        headerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerTitleLabel)

        let uploadButton = UIButton(type: .system)
        uploadButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        uploadButton.tintColor = .systemBlue
        uploadButton.translatesAutoresizingMaskIntoConstraints = false
        uploadButton.addTarget(self, action: #selector(uploadTapped), for: .touchUpInside)
        headerBar.addSubview(uploadButton)

        let disconnectButton = UIButton(type: .system)
        disconnectButton.setTitle("Disconnect", for: .normal)
        disconnectButton.setTitleColor(.systemRed, for: .normal)
        disconnectButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        disconnectButton.translatesAutoresizingMaskIntoConstraints = false
        disconnectButton.addTarget(self, action: #selector(disconnectTapped), for: .touchUpInside)
        headerBar.addSubview(disconnectButton)

        // Upload progress bar (hidden by default)
        let progress = UIProgressView(progressViewStyle: .bar)
        progress.trackTintColor = UIColor(white: 0.2, alpha: 1)
        progress.progressTintColor = .systemBlue
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.isHidden = true
        headerBar.addSubview(progress)
        uploadProgressView = progress

        let uploadLbl = UILabel()
        uploadLbl.font = UIFont.systemFont(ofSize: 10, weight: .medium)
        uploadLbl.textColor = .secondaryLabel
        uploadLbl.translatesAutoresizingMaskIntoConstraints = false
        uploadLbl.isHidden = true
        headerBar.addSubview(uploadLbl)
        uploadStatusLabel = uploadLbl

        NSLayoutConstraint.activate([
            // Extend to screen top so background fills behind Dynamic Island / status bar
            headerBar.topAnchor.constraint(equalTo: view.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // 36pt content area starts below the safe area (Dynamic Island / status bar)
            headerBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 36),

            // Pin content to the center of the 36pt content area below the safe area
            headerTitleLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            headerTitleLabel.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),

            uploadButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            uploadButton.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 12),

            disconnectButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            disconnectButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -12),

            progress.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),

            uploadLbl.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            uploadLbl.leadingAnchor.constraint(equalTo: uploadButton.trailingAnchor, constant: 6),

            sep.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    @objc private func disconnectTapped() {
        Task { try? await sshTerminalChannel?.close() }
        onDisconnect?()
    }

    private func setupTerminalView() {

        keyboardToolbar = KeyboardToolbar()
        keyboardToolbar.onKeyPressed = { [weak self] sequence in
            self?.sendString(sequence)
        }
        keyboardToolbar.applicationCursorKeys = { [weak self] in
            self?.terminalView.getTerminal().applicationCursor ?? false
        }
        keyboardToolbar.onTmuxPanelToggle = { [weak self] _ in
            self?.showTmuxPanel()
        }

        keyboardProxy = TerminalKeyboardProxy()
        keyboardProxy.frame = .zero
        keyboardProxy.isHidden = true
        keyboardProxy.onText = { [weak self] text in
            self?.sendString(text)
        }
        keyboardProxy.onBackspace = { [weak self] in
            self?.sendString("\u{7f}")
        }
        // Physical keyboard arrow keys and F-keys also need DECCKM awareness.
        keyboardProxy.applicationCursorKeys = { [weak self] in
            self?.terminalView.getTerminal().applicationCursor ?? false
        }
        keyboardProxy.setInputAccessoryView(keyboardToolbar)

        terminalView = SSHTerminalView(frame: .zero)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.terminalDelegate = self
        // Opaque + solid background: prevents UIKit from compositing the terminal
        // layer against whatever is behind it, which can bleed through when the
        // dirty rect doesn't cover the full viewport (proposal issue #4).
        terminalView.isOpaque = true
        terminalView.backgroundColor = .black
        // Disable text prediction on the terminal view — TerminalKeyboardProxy is the
        // first responder, so UIKit's text-prediction engine should never need to query
        // TerminalView for surrounding text.  Without this, the system logs repeated
        // "Result accumulator timeout: 0.250000, exceeded" warnings as the prediction
        // pipeline tries (and stalls) to build a context window from the terminal's
        // UITextInput implementation.
        terminalView.autocorrectionType = .no
        terminalView.spellCheckingType = .no

        // 2 000-line scrollback.  changeHistorySize operates on the live buffer
        // and survives normal resizes (Buffer.resize preserves buffer.scrollback).
        terminalView.getTerminal().changeHistorySize(2000)

        view.addSubview(terminalView)
        view.addSubview(keyboardProxy)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            // 10pt horizontal insets — keeps text clear of rounded corners
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            terminalView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        setupScrollToBottomButton()
        observeScrollPosition()

        #if DEBUG
        setupDebugGesture()
        #endif
    }

    // MARK: - Scroll-to-Bottom Button

    private func setupScrollToBottomButton() {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "chevron.down")
        config.baseBackgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        config.baseForegroundColor = UIColor.secondaryLabel
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)

        scrollToBottomButton = UIButton(configuration: config)
        scrollToBottomButton.translatesAutoresizingMaskIntoConstraints = false
        scrollToBottomButton.alpha = 0
        scrollToBottomButton.layer.shadowColor = UIColor.black.cgColor
        scrollToBottomButton.layer.shadowOpacity = 0.25
        scrollToBottomButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        scrollToBottomButton.layer.shadowRadius = 4
        scrollToBottomButton.addTarget(self, action: #selector(scrollToBottomTapped), for: .touchUpInside)
        view.addSubview(scrollToBottomButton)

        NSLayoutConstraint.activate([
            scrollToBottomButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            scrollToBottomButton.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -10),
        ])
    }

    /// Watch contentOffset to show/hide the scroll-to-bottom button.
    /// Buffer-switch redraws are now handled natively by SSHTerminalView.bufferActivated.
    private func observeScrollPosition() {
        scrollObserver = terminalView.publisher(for: \.contentOffset)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateScrollButton()
            }
    }

    private func updateScrollButton() {
        guard let tv = terminalView, tv.bounds.height > 0 else { return }

        // Alternate screen (vim / tmux): contentSize == viewport (no scrollback).
        // Nothing to scroll to — hide the button.
        let inAlternateScreen = tv.contentSize.height <= tv.bounds.height + 2
        if inAlternateScreen {
            setScrollButtonVisible(false, animated: false)
            return
        }

        let bottomY = tv.contentSize.height - tv.bounds.height
        let atBottom = tv.contentOffset.y >= bottomY - 4
        setScrollButtonVisible(!atBottom, animated: true)
    }

    private func setScrollButtonVisible(_ visible: Bool, animated: Bool) {
        let targetAlpha: CGFloat = visible ? 1 : 0
        guard abs(scrollToBottomButton.alpha - targetAlpha) > 0.01 else { return }
        if animated {
            UIView.animate(withDuration: 0.18) { self.scrollToBottomButton.alpha = targetAlpha }
        } else {
            scrollToBottomButton.alpha = targetAlpha
        }
    }

    @objc private func scrollToBottomTapped() {
        let maxY = max(0, terminalView.contentSize.height - terminalView.bounds.height)
        terminalView.setContentOffset(CGPoint(x: 0, y: maxY), animated: true)
        keyboardProxy.becomeFirstResponder()
    }

    // MARK: - Status Overlay

    private func setupStatusOverlay() {
        statusOverlay = UIView()
        statusOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        statusOverlay.layer.cornerRadius = 10
        statusOverlay.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.isHidden = true
        view.addSubview(statusOverlay)

        statusLabel = UILabel()
        statusLabel.textColor = .white
        statusLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusOverlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusOverlay.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            statusOverlay.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),

            statusLabel.topAnchor.constraint(equalTo: statusOverlay.topAnchor, constant: 16),
            statusLabel.bottomAnchor.constraint(equalTo: statusOverlay.bottomAnchor, constant: -16),
            statusLabel.leadingAnchor.constraint(equalTo: statusOverlay.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: statusOverlay.trailingAnchor, constant: -20),
        ])
    }

    // MARK: - Session Management

    func startSession(_ channel: SSHTerminalChannel) {
        self.sshTerminalChannel = channel

        channel.onData = { [weak self] data in
            // SSHTerminalChannelHandler already dispatches to main.
            // Accumulate bytes and schedule a single flush rather than feeding
            // SwiftTerm once per packet (see flushFeed for rationale).
            guard let self else { return }
            self.pendingFeed.append(contentsOf: data)
            if !self.feedPending {
                self.feedPending = true
                DispatchQueue.main.async { [weak self] in self?.flushFeed() }
            }
        }

        channel.onClose = { [weak self] in
            self?.handleConnectionClosed()
        }

        // Once the shell is fully ready, send the exact SwiftTerm-computed dimensions.
        // This corrects any mismatch between the estimated size used for the PTY open
        // and the actual view layout, which would otherwise cause readline's cursor
        // arithmetic to land on the wrong rows (garbled backspace/redraw).
        channel.onReady = { [weak self] in
            self?.notifyTerminalSize()
            self?.sendInitialDirectory()
        }

        // Force layout so terminalView.bounds is accurate before forwarding size to SSH.
        view.layoutIfNeeded()
        notifyTerminalSize()

        showConnectionStatus("Connected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.hideStatusOverlay()
        }
    }

    private func flushFeed() {
        feedPending = false
        guard !pendingFeed.isEmpty else { return }
        // Swap out the buffer before feeding so any data that arrives during the
        // (synchronous) feed call starts a fresh accumulation cycle.
        let bytes = pendingFeed
        pendingFeed.removeAll(keepingCapacity: true)
        terminalView.feedBytes(bytes[...])
    }

    private func handleConnectionClosed() {
        showConnectionStatus("Connection closed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.onConnectionClosed?()
        }
    }

    private func sendInitialDirectory() {
        guard let dir = defaultDirectory, !dir.isEmpty else { return }
        sendString("cd \(dir)\n")
    }

    // MARK: - Status Overlay Helpers

    func showConnectionStatus(_ message: String) {
        statusLabel.text = message
        statusOverlay.isHidden = false
        view.bringSubviewToFront(statusOverlay)
    }

    func hideStatusOverlay() {
        UIView.animate(withDuration: 0.3) {
            self.statusOverlay.alpha = 0
        } completion: { _ in
            self.statusOverlay.isHidden = true
            self.statusOverlay.alpha = 1
        }
    }

    // MARK: - Terminal Sizing

    /// Sends a resize to the SSH server only when the dimensions have actually changed.
    /// Multiple callers (viewDidLayoutSubviews, onReady, sizeChanged delegate) all funnel
    /// through here; the guard prevents spamming the server with duplicate SIGWINCH signals
    /// that can cause garbled vim/tmux redraws.
    private func notifyTerminalSize() {
        guard let t = terminalView,
              t.bounds.width > 0, t.bounds.height > 0 else { return }
        let cols = t.getTerminal().cols
        let rows = t.getTerminal().rows
        guard cols > 0, rows > 0 else { return }
        guard cols != lastReportedSize.cols || rows != lastReportedSize.rows else { return }
        lastReportedSize = (cols, rows)
        sshTerminalChannel?.resize(cols: cols, rows: rows)
    }

    // MARK: - File Upload

    @objc private func uploadTapped() {
        let sheet = UIAlertController(title: "Upload File", message: "Choose a file to upload to \(uploadPath)/", preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "Photos & Videos", style: .default) { [weak self] _ in
            self?.showPhotoPicker()
        })
        sheet.addAction(UIAlertAction(title: "Files", style: .default) { [weak self] _ in
            self?.showDocumentPicker()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = sheet.popoverPresentationController {
            popover.sourceView = headerBar
            popover.sourceRect = CGRect(x: 30, y: headerBar.bounds.maxY, width: 0, height: 0)
            popover.permittedArrowDirections = .up
        }
        present(sheet, animated: true)
    }

    private func showPhotoPicker() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func showDocumentPicker() {
        let types: [UTType] = [.item]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    private func uploadFiles(_ urls: [URL]) {
        guard let conn = sshConnection, !urls.isEmpty else { return }

        uploadProgressView?.isHidden = false
        uploadProgressView?.setProgress(0, animated: false)
        uploadStatusLabel?.isHidden = false

        Task {
            do {
                let sftp = try await conn.openSFTP()

                // Ensure upload directory exists
                try await sftp.mkdir(uploadPath)

                for (i, url) in urls.enumerated() {
                    let fileName = url.lastPathComponent
                    let remotePath = uploadPath.hasSuffix("/")
                        ? "\(uploadPath)\(fileName)"
                        : "\(uploadPath)/\(fileName)"

                    await MainActor.run {
                        uploadStatusLabel?.text = "\(i + 1)/\(urls.count): \(fileName)"
                    }

                    try await sftp.upload(localURL: url, remotePath: remotePath) { [weak self] fraction in
                        let overall = (Double(i) + fraction) / Double(urls.count)
                        self?.uploadProgressView?.setProgress(Float(overall), animated: true)
                    }
                }

                await sftp.close()

                await MainActor.run {
                    uploadProgressView?.setProgress(1.0, animated: true)
                    uploadStatusLabel?.text = "\(urls.count) file\(urls.count == 1 ? "" : "s") uploaded"
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }

                // Auto-hide after delay
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await MainActor.run {
                    UIView.animate(withDuration: 0.3) {
                        self.uploadProgressView?.alpha = 0
                        self.uploadStatusLabel?.alpha = 0
                    } completion: { _ in
                        self.uploadProgressView?.isHidden = true
                        self.uploadProgressView?.alpha = 1
                        self.uploadProgressView?.setProgress(0, animated: false)
                        self.uploadStatusLabel?.isHidden = true
                        self.uploadStatusLabel?.alpha = 1
                        self.uploadStatusLabel?.text = nil
                    }
                }
            } catch {
                await MainActor.run {
                    uploadProgressView?.isHidden = true
                    uploadStatusLabel?.isHidden = true
                    showUploadError(error)
                }
            }

            // Clean up temporary files from document picker (asCopy: true)
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func showUploadError(_ error: Error) {
        let alert = UIAlertController(
            title: "Upload Failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    // MARK: - Tmux Panel

    private func showTmuxPanel() {
        if tmuxPanel == nil {
            let panel = TmuxPanelInputView()
            panel.onKeyPressed = { [weak self] sequence in
                self?.sendString(sequence)
            }
            panel.applicationCursorKeys = { [weak self] in
                self?.terminalView.getTerminal().applicationCursor ?? false
            }
            panel.onClose = { [weak self] in
                self?.hideTmuxPanel()
            }
            tmuxPanel = panel
        }
        // Swap inputView: keyboard disappears, tmux panel fills that space.
        keyboardProxy.setInputView(tmuxPanel)
        keyboardProxy.reloadInputViews()
    }

    private func hideTmuxPanel() {
        keyboardProxy.setInputView(nil)
        keyboardProxy.reloadInputViews()
    }

    // MARK: - Input Helpers

    private func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        Task {
            try? await sshTerminalChannel?.send(data)
        }
    }
}

// MARK: - TerminalViewDelegate

extension TerminalViewController: TerminalViewDelegate {

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        Task {
            try? await sshTerminalChannel?.send(Data(data))
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Route through the deduplicating helper — SwiftTerm fires sizeChanged even
        // when the new dimensions are identical to the previous ones (e.g. on every
        // redraw in some builds), so guard against redundant SIGWINCH signals.
        guard newCols != lastReportedSize.cols || newRows != lastReportedSize.rows else { return }
        lastReportedSize = (newCols, newRows)
        sshTerminalChannel?.resize(cols: newCols, rows: newRows)
        // Note: do NOT call changeHistorySize here — it triggers terminal.refresh()
        // re-entrantly while SwiftTerm is mid-setup, corrupting the display buffer.
        // The 2000-line capacity set at init survives all normal resizes because
        // Buffer.resize() preserves buffer.scrollback.
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        DispatchQueue.main.async {
            self.headerTitleLabel?.text = title.isEmpty ? self.hostTitle : title
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    func scrolled(source: TerminalView, position: Double) {
        updateScrollButton()
    }

    func bell(source: TerminalView) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let string = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = string
        }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

// MARK: - Debug Testing (DEBUG builds only)

#if DEBUG
extension TerminalViewController {

    func setupDebugGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(showDebugMenu))
        tap.numberOfTapsRequired = 3
        terminalView.addGestureRecognizer(tap)
    }

    @objc private func showDebugMenu() {
        let alert = UIAlertController(title: "Debug Terminal", message: "Feed test sequences directly to the terminal view (no SSH needed)", preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "Test: Backspace Display", style: .default) { [weak self] _ in
            self?.debugTestBackspace()
        })
        alert.addAction(UIAlertAction(title: "Test: Alternate Screen (vim/tmux)", style: .default) { [weak self] _ in
            self?.debugTestAlternateScreen()
        })
        alert.addAction(UIAlertAction(title: "Test: In-Place Cursor Edit", style: .default) { [weak self] _ in
            self?.debugTestCursorEdit()
        })
        alert.addAction(UIAlertAction(title: "Test: Rapid Feed", style: .default) { [weak self] _ in
            self?.debugTestRapidFeed()
        })
        alert.addAction(UIAlertAction(title: "Clear Screen", style: .destructive) { [weak self] _ in
            self?.debugFeed("\u{1b}[2J\u{1b}[H")
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = terminalView
            popover.sourceRect = CGRect(x: terminalView.bounds.midX, y: terminalView.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
    }

    private func debugFeed(_ string: String) {
        let bytes = Array(string.utf8)
        terminalView.feedBytes(bytes[...])
    }

    /// Simulates: type "hello", server echoes "hello", user backspaces twice,
    /// server responds with BS-SP-BS twice. Display must show "hel" with no ghost chars.
    private func debugTestBackspace() {
        debugFeed("\u{1b}[2J\u{1b}[H")   // clear screen, home
        debugFeed("=== Backspace Display Test ===\r\n")
        debugFeed("Feeding: hello + 2x (BS SP BS)\r\n")
        debugFeed("Expected: cursor at 'o', display shows 'hel__'\r\n\r\n")
        debugFeed("$ hello")
        // Simulate server backspace echo: ESC[K would erase to EOL,
        // but most shells send the classic BS-SPACE-BS sequence per character
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.debugFeed("\u{08} \u{08}")   // erase 'o'
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.debugFeed("\u{08} \u{08}")   // erase second 'l'
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.debugFeed("\r\n\r\nPASS if 'hel' is visible and 'lo' is erased.\r\n")
        }
    }

    /// Simulates entering/exiting the alternate screen buffer (like vim/tmux).
    /// The normal screen content must reappear cleanly after exit.
    private func debugTestAlternateScreen() {
        debugFeed("\u{1b}[2J\u{1b}[H")
        debugFeed("=== Alternate Screen Test ===\r\n")
        debugFeed("Normal screen line 1\r\nNormal screen line 2\r\n")
        debugFeed("Switching to alternate buffer in 1s...\r\n")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            // smcup: switch to alternate screen
            self?.debugFeed("\u{1b}[?1049h\u{1b}[2J\u{1b}[H")
            self?.debugFeed("*** ALTERNATE SCREEN ***\r\n")
            self?.debugFeed("Previous output should NOT be visible here.\r\n")
            self?.debugFeed("Restoring normal screen in 2s...\r\n")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            // rmcup: restore normal screen
            self?.debugFeed("\u{1b}[?1049l")
            self?.debugFeed("\r\nPASS if normal screen text is visible again.\r\n")
        }
    }

    /// Types "AAAAA", moves cursor 3 left, overwrites with "BBB".
    /// Display must show "AABBB" with no leftover 'A' characters.
    private func debugTestCursorEdit() {
        debugFeed("\u{1b}[2J\u{1b}[H")
        debugFeed("=== Cursor Edit Test ===\r\n")
        debugFeed("Feed 'AAAAA', cursor left 3, feed 'BBB'\r\n")
        debugFeed("Expected: AABBB\r\n\r\n")
        debugFeed("$ AAAAA")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.debugFeed("\u{1b}[3D")   // cursor left 3
            self?.debugFeed("BBB")          // overwrite positions 3,4,5
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.debugFeed("\r\n\r\nPASS if line shows '$ AABBB' (no stray A's).\r\n")
        }
    }

    /// Fires 50 rapid feed calls to stress-test the display update pipeline.
    private func debugTestRapidFeed() {
        debugFeed("\u{1b}[2J\u{1b}[H")
        debugFeed("=== Rapid Feed Test ===\r\n")
        for i in 1...50 {
            let delay = Double(i) * 0.02
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.debugFeed("Line \(i): " + String(repeating: "x", count: 40) + "\r\n")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.debugFeed("\r\nPASS if all 50 lines are visible without gaps.\r\n")
        }
    }
}
#endif

// MARK: - PHPickerViewControllerDelegate

extension TerminalViewController: PHPickerViewControllerDelegate {

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        guard !results.isEmpty else { return }

        Task {
            var urls: [URL] = []
            for result in results {
                let provider = result.itemProvider

                // Try loading as a file representation (works for photos and videos)
                if let url = await loadFileRepresentation(from: provider) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                uploadFiles(urls)
            }
        }
    }

    /// Load a PHPickerResult's item as a temporary file URL.
    private func loadFileRepresentation(from provider: NSItemProvider) async -> URL? {
        // Prefer movie, then image
        let types: [UTType] = [.movie, .image]
        for type in types {
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                return await withCheckedContinuation { cont in
                    provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                        guard let url else {
                            cont.resume(returning: nil)
                            return
                        }
                        // Copy to a temporary location (the provided URL is deleted after this callback)
                        let tmp = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension(url.pathExtension)
                        do {
                            try FileManager.default.copyItem(at: url, to: tmp)
                            cont.resume(returning: tmp)
                        } catch {
                            cont.resume(returning: nil)
                        }
                    }
                }
            }
        }
        return nil
    }
}

// MARK: - UIDocumentPickerDelegate

extension TerminalViewController: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        uploadFiles(urls)
    }
}
