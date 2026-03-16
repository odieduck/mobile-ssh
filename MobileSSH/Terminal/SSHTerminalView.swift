import SwiftTerm
import UIKit

// MARK: - SSHTerminalView

/// TerminalView subclass with two targeted display fixes:
///
/// 1. **Buffer-switch overlay** (vim/tmux): SwiftTerm's default `bufferActivated()` updates
///    the UIScrollView geometry but never invalidates the display, so old pixels from the
///    previous buffer bleed through until an unrelated redraw. Overriding `bufferActivated`
///    and calling `setNeedsDisplay(bounds)` guarantees a clean repaint on every buffer switch.
///
/// 2. **Backspace/in-place edit display**: `draw()` and `feed()` are not `open` in SwiftTerm
///    and cannot be overridden from outside the module. Instead, callers use `feedBytes(_:)`
///    which feeds data and immediately marks the viewport dirty via `setNeedsDisplay(bounds)`.
///    `bounds.origin == contentOffset` on a UIScrollView, so the dirty rect carries the correct
///    scroll offset into SwiftTerm's `drawTerminalContents`, ensuring
///    `firstRow = Int(dirtyRect.minY / cellHeight)` indexes the actual visible rows.
final class SSHTerminalView: TerminalView {

    // MARK: - Buffer switch fix

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        setNeedsDisplay(bounds)
    }

    // MARK: - Feed

    /// Feed a coalesced batch of bytes to the terminal.
    ///
    /// Do NOT call setNeedsDisplay here. SwiftTerm's internal queuePendingDisplay()
    /// schedules the draw after all model state (contentSize, contentOffset, cell data)
    /// is fully updated. Calling setNeedsDisplay(bounds) prematurely — with a stale
    /// contentOffset captured mid-scroll — queues a draw at the wrong position and
    /// causes new output to visually overlap old output during long streaming writes.
    ///
    /// Callers are expected to coalesce multiple chunks into one feedBytes call per
    /// run-loop turn (see TerminalViewController.flushFeed) so SwiftTerm sees a single
    /// consistent state update rather than dozens of incremental ones.
    func feedBytes(_ bytes: ArraySlice<UInt8>) {
        feed(byteArray: bytes)
    }
}

// MARK: - TerminalKeyboardProxy

/// A tiny invisible view that becomes first responder instead of TerminalView.
///
/// SwiftTerm's UITextInput implementation accumulates typed characters in an internal
/// `textInputStorage` buffer. When that buffer empties, iOS's input system sees
/// `hasText == false` and may stop delivering `deleteBackward()` calls — making
/// repeated backspace presses silently fail.
///
/// By making this lightweight UIKeyInput view the keyboard owner we bypass that
/// machinery entirely. Every keystroke (including backspace) is forwarded directly
/// to the SSH channel with no local buffering. The TerminalView is kept purely as
/// a display surface.
final class TerminalKeyboardProxy: UIView, UIKeyInput {

    // MARK: - Callbacks

    /// Called with the raw text for every printable key (Enter included).
    var onText: ((String) -> Void)?

    /// Called on every backspace press.
    var onBackspace: (() -> Void)?

    /// Returns true when the terminal is in Application Cursor Keys mode (DECCKM).
    /// Used by pressesBegan to send SS3 vs CSI arrow sequences.
    var applicationCursorKeys: (() -> Bool)?

    // MARK: - UIKeyInput

    /// Always true — we never want iOS to disable the delete key.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" {
            // iOS sends "\n" for Return; SSH expects CR (0x0D).
            onText?("\r")
        } else {
            onText?(text)
        }
    }

    func deleteBackward() {
        onBackspace?()
    }

    // MARK: - Physical keyboard (pressesBegan)
    //
    // iOS does NOT deliver arrow keys, F-keys, Home, End, PgUp/Dn through insertText.
    // They arrive exclusively via UIResponder.pressesBegan. Without this override those
    // keys are silently dropped when using a Bluetooth/Smart Keyboard.

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, let seq = escapeSequence(for: key) {
                onText?(seq)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
    }

    // MARK: - Escape sequence table

    /// Maps a UIKey press to the correct xterm escape sequence.
    ///
    /// - Respects DECCKM (applicationCursorKeys) for arrow/home/end.
    /// - Encodes Shift/Alt/Ctrl using xterm modifier parameters (e.g. \x1b[1;5A for Ctrl+Up).
    /// - Returns nil for keys that arrive through insertText/deleteBackward so they
    ///   are not double-sent (regular letters, Return, Backspace, Tab, etc.).
    private func escapeSequence(for key: UIKey) -> String? {
        let appCursor = applicationCursorKeys?() ?? false
        let mods = key.modifierFlags
        let shift = mods.contains(.shift)
        let ctrl  = mods.contains(.control)
        let alt   = mods.contains(.alternate)

        // xterm modifier parameter: 1 = none, 2 = Shift, 3 = Alt, 4 = Alt+Shift,
        // 5 = Ctrl, 6 = Ctrl+Shift, 7 = Ctrl+Alt, 8 = Ctrl+Alt+Shift
        let modParam = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        let hasModifier = modParam > 1

        // Arrow keys: SS3 in application cursor mode (no modifier), CSI otherwise.
        func arrow(_ letter: String) -> String {
            if appCursor && !hasModifier { return "\u{1B}O\(letter)" }
            if hasModifier { return "\u{1B}[1;\(modParam)\(letter)" }
            return "\u{1B}[\(letter)"
        }

        switch key.keyCode {
        // Arrow keys
        case .keyboardUpArrow:       return arrow("A")
        case .keyboardDownArrow:     return arrow("B")
        case .keyboardRightArrow:    return arrow("C")
        case .keyboardLeftArrow:     return arrow("D")

        // Home / End
        case .keyboardHome:
            if hasModifier { return "\u{1B}[1;\(modParam)H" }
            return appCursor ? "\u{1B}OH" : "\u{1B}[H"
        case .keyboardEnd:
            if hasModifier { return "\u{1B}[1;\(modParam)F" }
            return appCursor ? "\u{1B}OF" : "\u{1B}[F"

        // Page keys
        case .keyboardPageUp:        return "\u{1B}[5~"
        case .keyboardPageDown:      return "\u{1B}[6~"

        // Forward delete
        case .keyboardDeleteForward: return "\u{1B}[3~"

        // Escape key (on an external keyboard, pressing Esc doesn't call insertText)
        case .keyboardEscape:        return "\u{1B}"

        // Shift+Tab = reverse tab (regular Tab arrives via insertText)
        case .keyboardTab:           return shift ? "\u{1B}[Z" : nil

        // Function keys (F1-F4 use SS3 without modifier, VT220 tilde form with modifier)
        case .keyboardF1:  return hasModifier ? "\u{1B}[11;\(modParam)~" : "\u{1B}OP"
        case .keyboardF2:  return hasModifier ? "\u{1B}[12;\(modParam)~" : "\u{1B}OQ"
        case .keyboardF3:  return hasModifier ? "\u{1B}[13;\(modParam)~" : "\u{1B}OR"
        case .keyboardF4:  return hasModifier ? "\u{1B}[14;\(modParam)~" : "\u{1B}OS"
        case .keyboardF5:  return "\u{1B}[15~"
        case .keyboardF6:  return "\u{1B}[17~"
        case .keyboardF7:  return "\u{1B}[18~"
        case .keyboardF8:  return "\u{1B}[19~"
        case .keyboardF9:  return "\u{1B}[20~"
        case .keyboardF10: return "\u{1B}[21~"
        case .keyboardF11: return "\u{1B}[23~"
        case .keyboardF12: return "\u{1B}[24~"

        default: return nil
        }
    }

    // MARK: - UIResponder

    override var canBecomeFirstResponder: Bool { true }
    override var canResignFirstResponder: Bool { true }

    private var _inputAccessoryView: UIView?
    override var inputAccessoryView: UIView? { _inputAccessoryView }
    func setInputAccessoryView(_ view: UIView?) { _inputAccessoryView = view }

    private var _inputView: UIView?
    override var inputView: UIView? { _inputView }
    func setInputView(_ view: UIView?) { _inputView = view }

    // MARK: - UITextInputTraits (keeps keyboard settings consistent with TerminalView)

    var keyboardType: UIKeyboardType {
        get { .asciiCapable }
        set {}
    }

    var autocorrectionType: UITextAutocorrectionType { .no }
    var autocapitalizationType: UITextAutocapitalizationType { .none }
    var spellCheckingType: UITextSpellCheckingType { .no }
    var smartQuotesType: UITextSmartQuotesType { .no }
    var smartDashesType: UITextSmartDashesType { .no }
}
