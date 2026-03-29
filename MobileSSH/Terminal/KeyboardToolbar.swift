import UIKit

// MARK: - Shared color constants (explicit, non-adaptive — avoids trait-env issues in UIInputView)

private let kToolbarBg  = UIColor(white: 0.12, alpha: 1)
private let kKeyBg      = UIColor(white: 0.27, alpha: 1)
private let kKeyFg      = UIColor.white
private let kDividerBg  = UIColor(white: 0.35, alpha: 1)
private let kGreenFg    = UIColor(red: 0.2, green: 0.85, blue: 0.4, alpha: 1)

// MARK: - Tmux groups

private struct TmuxGroup {
    let title: String
    let keys: [(label: String, sequence: String)]
}

private let tmuxGroups: [TmuxGroup] = [
    TmuxGroup(title: "Panes", keys: [
        ("VSpl", "%"),          // vertical split
        ("HSpl", "\""),         // horizontal split
        ("Zoom", "z"),          // zoom pane
        ("Kill", "x"),          // kill pane
        ("↑",    "\u{1B}[A"),  // navigate up
        ("↓",    "\u{1B}[B"),  // navigate down
        ("←",    "\u{1B}[D"),  // navigate left
        ("→",    "\u{1B}[C"),  // navigate right
    ]),
    TmuxGroup(title: "Win", keys: [
        ("New",  "c"),   // new window
        ("Next", "n"),   // next window
        ("Prev", "p"),   // prev window
        ("Ren",  ","),   // rename window
        ("Kill", "&"),   // kill window
    ]),
    TmuxGroup(title: "Sess", keys: [
        ("Det",  "d"),   // detach session
        ("List", "s"),   // list sessions
        ("Ren",  "$"),   // rename session
    ]),
    TmuxGroup(title: "Copy", keys: [
        ("Mode", "["),   // enter copy mode
        ("Pste", "]"),   // paste buffer
        ("Cmd",  ":"),   // command prompt
        ("Keys", "?"),   // list key bindings
    ]),
]

// MARK: - TmuxPanelInputView
//
// A UIInputView that replaces the software keyboard when the tmux button is tapped.
// Set as TerminalKeyboardProxy.inputView — the normal keyboard disappears and this
// panel takes its place, so it's never covered by the keyboard.

final class TmuxPanelInputView: UIInputView {

    var onKeyPressed: ((String) -> Void)?
    /// Returns true when the terminal is in Application Cursor Keys mode (DECCKM).
    var applicationCursorKeys: (() -> Bool)?
    var onClose: (() -> Void)?

    // Geometry
    private let rowH:   CGFloat = 36
    private let rowGap: CGFloat = 6
    private let padH:   CGFloat = 12
    private let padV:   CGFloat = 10
    private let labelW: CGFloat = 38
    private let closeH: CGFloat = 40

    static func preferredHeight() -> CGFloat {
        let rowH: CGFloat = 36, rowGap: CGFloat = 6, padV: CGFloat = 10, closeH: CGFloat = 40
        return closeH + 0.5 + padV
             + CGFloat(tmuxGroups.count) * rowH
             + CGFloat(max(0, tmuxGroups.count - 1)) * rowGap
             + padV
    }

    init() {
        let h = TmuxPanelInputView.preferredHeight()
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: h), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        overrideUserInterfaceStyle = .dark
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = kToolbarBg

        // ── Header row ────────────────────────────────────────────────────
        let titleLbl = UILabel()
        titleLbl.text = "tmux shortcuts  (Prefix: Ctrl-B)"
        titleLbl.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        titleLbl.textColor = UIColor(white: 0.65, alpha: 1)
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        let doneBtn = UIButton(type: .system)
        doneBtn.setTitle("Done", for: .normal)
        doneBtn.setTitleColor(UIColor.systemBlue, for: .normal)
        doneBtn.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        doneBtn.translatesAutoresizingMaskIntoConstraints = false
        doneBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLbl)
        header.addSubview(doneBtn)
        addSubview(header)

        let headerSep = UIView()
        headerSep.backgroundColor = kDividerBg
        headerSep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerSep)

        // ── Groups ────────────────────────────────────────────────────────
        let vStack = UIStackView()
        vStack.axis = .vertical
        vStack.spacing = rowGap
        vStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vStack)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: closeH),

            titleLbl.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLbl.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            doneBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            doneBtn.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),

            headerSep.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerSep.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSep.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerSep.heightAnchor.constraint(equalToConstant: 0.5),

            vStack.topAnchor.constraint(equalTo: headerSep.bottomAnchor, constant: padV),
            vStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padH),
            vStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padH),
        ])

        for group in tmuxGroups {
            vStack.addArrangedSubview(makeGroupRow(group))
        }
    }

    private func makeGroupRow(_ group: TmuxGroup) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        row.heightAnchor.constraint(equalToConstant: rowH).isActive = true

        // Group label
        let lbl = UILabel()
        lbl.text = group.title
        lbl.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        lbl.textColor = UIColor(white: 0.55, alpha: 1)
        lbl.textAlignment = .right
        lbl.widthAnchor.constraint(equalToConstant: labelW).isActive = true
        row.addArrangedSubview(lbl)

        // Key buttons
        for (label, seq) in group.keys {
            row.addArrangedSubview(makeTmuxButton(label: label, sequence: seq))
        }

        // Trailing spacer
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        return row
    }

    private func makeTmuxButton(label: String, sequence: String) -> UIButton {
        let btn = UIButton(type: .custom)
        btn.setTitle(label, for: .normal)
        btn.setTitleColor(kGreenFg, for: .normal)
        btn.backgroundColor = UIColor(white: 0.22, alpha: 1)
        btn.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        btn.layer.cornerRadius = 6
        btn.contentEdgeInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setContentCompressionResistancePriority(.required, for: .horizontal)
        btn.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Apply DECCKM: remap CSI arrows → SS3 in application cursor mode
            var seq = sequence
            if self?.applicationCursorKeys?() == true {
                switch seq {
                case "\u{1B}[A": seq = "\u{1B}OA"
                case "\u{1B}[B": seq = "\u{1B}OB"
                case "\u{1B}[C": seq = "\u{1B}OC"
                case "\u{1B}[D": seq = "\u{1B}OD"
                default: break
                }
            }
            // Send prefix (Ctrl-B) and command as separate writes so tmux
            // cleanly sees the prefix boundary before the command key.
            self?.onKeyPressed?("\u{02}")
            self?.onKeyPressed?(seq)
            self?.onClose?()
        }, for: .touchUpInside)
        return btn
    }

    @objc private func closeTapped() {
        onClose?()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric,
               height: Self.preferredHeight() + safeAreaInsets.bottom)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
    }
}

// MARK: - KeyboardToolbar
//
// The persistent accessory bar shown above the software keyboard (inputAccessoryView).
// Uses UIButton(type: .custom) with explicit non-adaptive colors to guarantee
// correct rendering regardless of the UIInputView trait environment.

final class KeyboardToolbar: UIInputView {

    // MARK: - Public

    /// Called when a key produces output (sequence to send to the terminal).
    var onKeyPressed: ((String) -> Void)?

    /// Returns true when the terminal is in Application Cursor Keys mode (DECCKM).
    var applicationCursorKeys: (() -> Bool)?

    /// Called when the user taps the tmux button; argument is always true (open panel).
    var onTmuxPanelToggle: ((Bool) -> Void)?

    // MARK: - Private state

    private var ctrlActive = false
    private var altActive  = false

    private weak var ctrlButton: UIButton?
    private weak var altButton:  UIButton?

    // MARK: - Init

    init() {
        // Non-zero initial frame ensures safeAreaLayoutGuide resolves correctly
        // on the very first layout pass before the system reads intrinsicContentSize.
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 50), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        overrideUserInterfaceStyle = .dark
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setup() {
        backgroundColor = kToolbarBg

        let topBorder = UIView()
        topBorder.backgroundColor = kDividerBg
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            // Top decorative border
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 0.5),

            // Scroll view: fixed 50pt, pinned to all sides except bottom
            scroll.topAnchor.constraint(equalTo: topBorder.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 50),

            // Stack inside scroll: contentLayoutGuide drives content size (horizontal scroll)
            // Fixed 36pt height, 7pt top/bottom margin to center in 50pt scroll row.
            stack.heightAnchor.constraint(equalToConstant: 36),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -7),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
        ])

        buildKeys(in: stack)
    }

    private func buildKeys(in stack: UIStackView) {
        // ── Group 1: Modifiers ───────────────────────────────────────────
        addKey("Esc",  seq: "\u{1B}", to: stack)
        addKey("Tab",  seq: "\t",     to: stack)
        ctrlButton = addKey("Ctrl", seq: "", to: stack)
        altButton  = addKey("Alt",  seq: "", to: stack)

        // ── Group 2: Arrow keys ──────────────────────────────────────────
        addDivider(to: stack)
        addKey("↑", seq: "\u{1B}[A", to: stack)
        addKey("↓", seq: "\u{1B}[B", to: stack)
        addKey("←", seq: "\u{1B}[D", to: stack)
        addKey("→", seq: "\u{1B}[C", to: stack)

        // ── Group 3: Common symbols ──────────────────────────────────────
        addDivider(to: stack)
        for (lbl, seq) in [("|","|"), ("~","~"), ("`","`"), ("-","-"),
                           ("_","_"), ("/","/"), ("\\","\\"),
                           ("{","{"), ("}","}"), ("[","["), ("]","]")] {
            addKey(lbl, seq: seq, to: stack)
        }

        // ── Group 4: Function keys ───────────────────────────────────────
        addDivider(to: stack)
        addKey("F1", seq: "\u{1B}OP",   to: stack)
        addKey("F2", seq: "\u{1B}OQ",   to: stack)
        addKey("F3", seq: "\u{1B}OR",   to: stack)
        addKey("F4", seq: "\u{1B}OS",   to: stack)
        addKey("F5", seq: "\u{1B}[15~", to: stack)

        // ── tmux toggle ──────────────────────────────────────────────────
        addDivider(to: stack)
        let tmuxBtn = makeKey("tmux ▾", fg: kGreenFg)
        tmuxBtn.addTarget(self, action: #selector(tmuxTapped), for: .touchUpInside)
        stack.addArrangedSubview(tmuxBtn)

        // Trailing spacer keeps all buttons left-aligned in .fill distribution.
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
    }

    // MARK: - Button factory

    @discardableResult
    private func addKey(_ label: String, seq: String, to stack: UIStackView) -> UIButton {
        let btn = makeKey(label)
        btn.addAction(UIAction { [weak self, weak btn] _ in
            guard let self, let btn else { return }
            self.handle(label: label, seq: seq, button: btn)
        }, for: .touchUpInside)
        stack.addArrangedSubview(btn)
        return btn
    }

    private func makeKey(_ title: String, fg: UIColor = kKeyFg) -> UIButton {
        let btn = UIButton(type: .custom)
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(fg, for: .normal)
        btn.backgroundColor = kKeyBg
        btn.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        btn.layer.cornerRadius = 6
        // contentEdgeInsets is deprecated in iOS 15 but still works; fine for internal use.
        btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setContentCompressionResistancePriority(.required, for: .horizontal)
        return btn
    }

    private func addDivider(to stack: UIStackView) {
        let v = UIView()
        v.backgroundColor = kDividerBg
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: 22),
        ])
        stack.addArrangedSubview(v)
    }

    // MARK: - Modifier state for software keyboard

    /// Consumes the active modifier (Ctrl or Alt) and returns the transformed
    /// sequence.  If no modifier is active the input is returned unchanged.
    /// This allows the software keyboard path (TerminalKeyboardProxy) to
    /// participate in the toolbar's Ctrl / Alt toggle.
    func applyModifier(to text: String) -> String {
        if ctrlActive {
            let out = ctrlSeq(text)
            ctrlActive = false
            refreshCtrl()
            return out
        }
        if altActive {
            altActive = false
            refreshAlt()
            return "\u{1B}" + text
        }
        return text
    }

    /// True when Ctrl or Alt is currently toggled on.
    var hasActiveModifier: Bool { ctrlActive || altActive }

    // MARK: - Actions

    @objc private func tmuxTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onTmuxPanelToggle?(true)
    }

    private func handle(label: String, seq: String, button: UIButton) {
        // Toggle modifiers
        if label == "Ctrl" {
            ctrlActive.toggle()
            if ctrlActive { altActive = false; refreshAlt() }
            refreshCtrl()
            return
        }
        if label == "Alt" {
            altActive.toggle()
            if altActive { ctrlActive = false; refreshCtrl() }
            refreshAlt()
            return
        }

        // Apply modifier and build output sequence
        var out = seq
        if ctrlActive {
            out = ctrlSeq(seq)
            ctrlActive = false
            refreshCtrl()
        } else if altActive {
            out = "\u{1B}" + seq
            altActive = false
            refreshAlt()
        }

        // DECCKM: remap arrow CSI → SS3 in application cursor mode
        if applicationCursorKeys?() == true {
            switch out {
            case "\u{1B}[A": out = "\u{1B}OA"
            case "\u{1B}[B": out = "\u{1B}OB"
            case "\u{1B}[C": out = "\u{1B}OC"
            case "\u{1B}[D": out = "\u{1B}OD"
            default: break
            }
        }

        if !out.isEmpty { onKeyPressed?(out) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func ctrlSeq(_ seq: String) -> String {
        guard let c = seq.unicodeScalars.first else { return seq }
        let v = c.value
        if v >= 65 && v <= 90  { return String(UnicodeScalar(v - 64)!) }  // A–Z
        if v >= 97 && v <= 122 { return String(UnicodeScalar(v - 96)!) }  // a–z
        switch seq {
        case "[":  return "\u{1B}"
        case "]":  return "\u{1D}"
        case "\\": return "\u{1C}"
        case "/":  return "\u{1F}"
        default:   return seq
        }
    }

    // MARK: - Modifier button appearance

    private func refreshCtrl() {
        ctrlButton?.backgroundColor = ctrlActive ? .systemBlue : kKeyBg
    }

    private func refreshAlt() {
        altButton?.backgroundColor = altActive ? .systemOrange : kKeyBg
    }

    // MARK: - Intrinsic size

    override var intrinsicContentSize: CGSize {
        // 50pt row + safe area bottom (covers home indicator when hardware keyboard is attached)
        CGSize(width: UIView.noIntrinsicMetric, height: 50 + safeAreaInsets.bottom)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
    }
}
