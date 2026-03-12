# MobileSSH: Product & Design Roadmap

As the UX Designer and PM for MobileSSH, I have evaluated the current prototype. While the foundation is solid—with support for Ed25519, Tailscale, and Jump Hosts—the app requires several key features to transition from a "working prototype" to a "professional tool" that users can rely on for production work.

---

## 0. Critical Bug Fixes & Stability (Immediate Priority)

Before adding new features, the core terminal engine must be reliable for power users.

-   **[Fix] Vim/Tmux Buffer & Rendering Issues:**
    -   *Problem:* Launching full-screen apps like `vim` or `tmux` often fails to clear the screen, leaving old command history visible and breaking cursor tracking.
    -   *Root Cause:* The current "heuristic" detection of alternate buffers in `TerminalViewController` (checking if content size matches bounds) is unreliable and prone to race conditions.
    -   *Strategy:* Move away from heuristics and leverage `SwiftTerm`'s native delegate methods for buffer changes. Ensure the initial `smcup` (alternate screen) sequence triggers a clean screen wipe.
-   **[Fix] PTY Resize Synchronization:**
    -   *Problem:* Redundant or out-of-order resize requests sent during SSH handshake often lead to the server using incorrect terminal dimensions (defaulting to 80x24).
    -   *Strategy:* Centralize the resize pipeline. Ensure the *very first* PTY request in `SSHTerminalChannel` uses the exact view dimensions to prevent a jarring initial draw.
-   **[Fix] Terminal Mode (DECCKM) Support:**
    -   *Strategy:* Explicitly handle Application Cursor Keys and scroll-margin sequences to ensure `vim`'s UI (status bar, line numbers) renders correctly on mobile screens.

---

## 1. Security & Identity (High Priority)

Professional SSH users prioritize security above all else. The current implementation lacks critical safeguards.

-   **[UX] Biometric Lock (FaceID/TouchID):**
    -   Option to lock the entire app or specific sensitive host configurations behind biometrics.
    -   *Why:* Prevents unauthorized access if the device is stolen or borrowed while unlocked.
-   **[Feature] Host Key Verification (Known Hosts):**
    -   Implement "Trust on First Use" (TOFU) properly. Alert the user when a host key changes to prevent Man-in-the-Middle (MITM) attacks.
    -   *Why:* Currently, the app accepts all host keys silently, which is a significant security risk.
-   **[Feature] Encrypted Private Keys:**
    -   Support for private keys protected by a passphrase.
    -   *Why:* Many users store keys with passphrases; the current Ed25519 parser only supports unencrypted keys.
-   **[Feature] Expanded Key Support:**
    -   Add support for RSA (2048/4096) and ECDSA keys.
    -   *Why:* Many legacy and enterprise systems still rely on RSA.

---

## 2. Terminal Experience & UX (High Priority)

The terminal is where users spend 90% of their time. It needs to feel "native" and powerful.

-   **[UX] Multi-Session Management (Tabs):**
    -   Allow users to have multiple active SSH connections and switch between them easily using a tab bar or a side drawer.
    -   *Why:* Users often need to tail logs on one server while running commands on another.
-   **[UX] Snippets & Macros:**
    -   A library of frequently used commands (e.g., `docker ps`, `tail -f /var/log/syslog`) that can be triggered with one tap.
    -   *Why:* Typing long commands on a mobile keyboard is error-prone and tedious.
-   **[UX] Terminal Customization:**
    -   Themes (Solarized, Monokai, Nord, etc.) and font selection/sizing.
    -   *Why:* Personalization is key for readability during long sessions.
-   **[UX] Advanced Keyboard Toolbar:**
    -   Make the toolbar customizable. Let users pick which "special keys" (Ctrl, Alt, Esc, Arrow Keys, Pipe) are most accessible.

---

## 3. Advanced Connectivity (Medium Priority)

-   **[Feature] Port Forwarding:**
    -   Support for Local, Remote, and Dynamic (SOCKS5) port forwarding.
    -   *Why:* Essential for accessing web UIs or databases behind firewalls without a VPN.
-   **[Feature] Persistence & Keep-Alive:**
    -   Configure SSH keep-alive intervals and automatic reconnection logic.
    -   *Why:* Mobile networks are unstable; the app should gracefully handle signal drops.
-   **[Feature] Agent Forwarding:**
    -   Support for `ForwardAgent` to allow using local keys on remote servers securely.

---

## 4. File Management & Sync (Lower Priority)

-   **[Feature] SFTP / File Browser:**
    -   A GUI for browsing remote files, uploading/downloading, and basic editing.
    -   *Why:* Often faster than using `scp` or `vim` for simple file tweaks.
-   **[Feature] iCloud Sync:**
    -   Sync host configurations (not sensitive credentials, or via encrypted iCloud Keychain) across devices.
    -   *Why:* Users expect their host list to be available on both iPhone and iPad.

---

## Roadmap & Implementation Phases

### Phase 0: Stability First
1.  Resolve Vim/Tmux rendering and cursor bugs.
2.  Clean up the PTY resize and terminal mode sync logic.

### Phase 1: Security Hardening (Quick Wins)
1.  Implement FaceID/TouchID app lock.
2.  Add Host Key Verification (Known Hosts) UI.
3.  Support RSA/ECDSA and Passphrase-protected keys.

### Phase 2: Power User UX
1.  Implement Multi-session (Tabbed interface).
2.  Add a Snippets/Macros system.
3.  Add Terminal Theming and Font settings.

### Phase 3: Advanced Networking
1.  Port Forwarding (Local/Remote/Dynamic).
2.  Session Persistence (Keep-alive/Auto-reconnect).

### Phase 4: Ecosystem Integration
1.  SFTP File Browser.
2.  iCloud Sync for host lists.
