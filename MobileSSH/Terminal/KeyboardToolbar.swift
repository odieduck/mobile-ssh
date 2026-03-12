import UIKit

// MARK: - Key Definition

struct ToolbarKey {
    let label: String
    let sequence: String
    var isSpecial: Bool = false  // e.g. Ctrl toggle
}

// MARK: - KeyboardToolbar

final class KeyboardToolbar: UIView {

    var onKeyPressed: ((String) -> Void)?

    /// Returns true when the terminal is in Application Cursor Keys mode (DECCKM).
    /// Queried at tap time so the correct SS3 vs CSI sequence is sent for arrow keys.
    var applicationCursorKeys: (() -> Bool)?

    private var ctrlActive = false
    private var altActive = false
    private var ctrlButton: UIButton?
    private var altButton: UIButton?
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()

    private let keys: [ToolbarKey] = [
        ToolbarKey(label: "Esc",  sequence: "\u{1B}"),
        ToolbarKey(label: "Tab",  sequence: "\t"),
        ToolbarKey(label: "Ctrl", sequence: "", isSpecial: true),
        ToolbarKey(label: "Alt",  sequence: "\u{1B}", isSpecial: true),  // sticky: ESC-prefix next key
        ToolbarKey(label: "↑",    sequence: "\u{1B}[A"),
        ToolbarKey(label: "↓",    sequence: "\u{1B}[B"),
        ToolbarKey(label: "←",    sequence: "\u{1B}[D"),
        ToolbarKey(label: "→",    sequence: "\u{1B}[C"),
        ToolbarKey(label: "|",    sequence: "|"),
        ToolbarKey(label: "~",    sequence: "~"),
        ToolbarKey(label: "`",    sequence: "`"),
        ToolbarKey(label: "-",    sequence: "-"),
        ToolbarKey(label: "_",    sequence: "_"),
        ToolbarKey(label: "/",    sequence: "/"),
        ToolbarKey(label: "\\",   sequence: "\\"),
        ToolbarKey(label: "{",    sequence: "{"),
        ToolbarKey(label: "}",    sequence: "}"),
        ToolbarKey(label: "[",    sequence: "["),
        ToolbarKey(label: "]",    sequence: "]"),
        ToolbarKey(label: "(",    sequence: "("),
        ToolbarKey(label: ")",    sequence: ")"),
        ToolbarKey(label: "F1",   sequence: "\u{1B}OP"),
        ToolbarKey(label: "F2",   sequence: "\u{1B}OQ"),
        ToolbarKey(label: "F3",   sequence: "\u{1B}OR"),
        ToolbarKey(label: "F4",   sequence: "\u{1B}OS"),
        ToolbarKey(label: "F5",   sequence: "\u{1B}[15~"),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor.systemGroupedBackground

        // Top separator
        let separator = UIView()
        separator.backgroundColor = UIColor.separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.spacing = 6
        stackView.alignment = .center
        stackView.distribution = .fillProportionally
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 6),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -8),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -6),
            stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor, constant: -12),
        ])

        buildButtons()
    }

    private func buildButtons() {
        for (index, key) in keys.enumerated() {
            let button = makeButton(for: key, tag: index)
            stackView.addArrangedSubview(button)

            if key.isSpecial && key.label == "Ctrl" {
                ctrlButton = button
            }
            if key.isSpecial && key.label == "Alt" {
                altButton = button
            }
        }
    }

    private func makeButton(for key: ToolbarKey, tag: Int) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = key.label
        config.baseForegroundColor = .label
        config.baseBackgroundColor = UIColor.secondarySystemBackground
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        config.cornerStyle = .medium

        let button = UIButton(configuration: config)
        button.tag = tag
        button.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)

        // Minimum width
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true

        return button
    }

    @objc private func keyTapped(_ sender: UIButton) {
        guard sender.tag >= 0 && sender.tag < keys.count else { return }
        let key = keys[sender.tag]

        if key.isSpecial && key.label == "Ctrl" {
            ctrlActive.toggle()
            if ctrlActive { altActive = false; updateAltButtonAppearance() }
            updateCtrlButtonAppearance()
            return
        }

        if key.isSpecial && key.label == "Alt" {
            altActive.toggle()
            if altActive { ctrlActive = false; updateCtrlButtonAppearance() }
            updateAltButtonAppearance()
            return
        }

        var sequence: String
        if ctrlActive {
            sequence = ctrlSequence(for: key.sequence)
            ctrlActive = false
            updateCtrlButtonAppearance()
        } else if altActive {
            // Alt = ESC prefix before the key's sequence
            sequence = "\u{1B}" + key.sequence
            altActive = false
            updateAltButtonAppearance()
        } else {
            sequence = key.sequence
        }

        // DECCKM: when the terminal is in Application Cursor Keys mode, arrow keys
        // must use SS3 sequences (\x1bOA) instead of CSI sequences (\x1b[A).
        // This is critical for vim, htop, and any ncurses app that enables DECCKM.
        if applicationCursorKeys?() == true {
            switch sequence {
            case "\u{1B}[A": sequence = "\u{1B}OA"
            case "\u{1B}[B": sequence = "\u{1B}OB"
            case "\u{1B}[C": sequence = "\u{1B}OC"
            case "\u{1B}[D": sequence = "\u{1B}OD"
            default: break
            }
        }

        if !sequence.isEmpty {
            onKeyPressed?(sequence)
        }

        // Haptic feedback
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred()
    }

    private func ctrlSequence(for sequence: String) -> String {
        // For arrow keys and special sequences, Ctrl doesn't modify them in the usual sense
        // For regular printable keys: Ctrl+key = key - 64 (A=1, B=2, etc.)
        guard let firstChar = sequence.unicodeScalars.first else { return sequence }
        let value = firstChar.value

        // Handle common letter keys
        if value >= 65 && value <= 90 { // A-Z
            return String(UnicodeScalar(value - 64)!)
        }
        if value >= 97 && value <= 122 { // a-z
            return String(UnicodeScalar(value - 96)!)
        }

        // Common symbols
        switch sequence {
        case "[": return "\u{1B}"   // Ctrl+[ = ESC
        case "]": return "\u{1D}"   // Ctrl+]
        case "\\": return "\u{1C}"  // Ctrl+\
        case "/": return "\u{1F}"   // Ctrl+/
        default: return sequence
        }
    }

    private func updateCtrlButtonAppearance() {
        guard let button = ctrlButton else { return }
        var config = button.configuration
        if ctrlActive {
            config?.baseBackgroundColor = UIColor.systemBlue
            config?.baseForegroundColor = .white
        } else {
            config?.baseBackgroundColor = UIColor.secondarySystemBackground
            config?.baseForegroundColor = .label
        }
        button.configuration = config
    }

    private func updateAltButtonAppearance() {
        guard let button = altButton else { return }
        var config = button.configuration
        if altActive {
            config?.baseBackgroundColor = UIColor.systemOrange
            config?.baseForegroundColor = .white
        } else {
            config?.baseBackgroundColor = UIColor.secondarySystemBackground
            config?.baseForegroundColor = .label
        }
        button.configuration = config
    }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: UIView.noIntrinsicMetric, height: 50)
    }
}
