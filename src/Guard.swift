import AppKit
import LocalAuthentication

// PlonkerBlockerGuard: a background agent. It watches which app is frontmost and, when
// a *protected* app comes forward, drops an opaque lock window over every screen
// and demands administrator authentication. It NEVER touches the target app —
// "unlock" simply removes our own overlay. Requires no special permissions.

// Borderless windows can't become key by default, so keystrokes (and the
// Unlock button's Return equivalent) would be ignored. This subclass fixes that
// and lets the cover capture keyboard input away from the app behind it.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Lock overlay
// The lock-screen backdrop is the shared themed BackgroundView (Shared.swift),
// so it matches whatever background the user picked in the manager.

final class CoverController {
    private var windows: [NSWindow] = []
    private var nameLabels: [NSTextField] = []
    private var iconViews: [NSImageView] = []
    private var nedryNativeViews: [NSView] = []    // native "Ah ah ah!" labels + finger
    private var nedryHideViews: [NSView] = []      // card elements hidden while it shows
    private var nedryGifViews: [NSImageView] = []  // shown instead when a custom animation is set
    private var fingerViews: [NSTextField] = []    // native wagging finger
    private var bgViews: [BackgroundView] = []
    private var builtFrames: [CGRect] = []
    private(set) var visible = false

    // Primary-card controls.
    private weak var passcodeField: NSSecureTextField?
    private weak var subtitleLabel: NSTextField?
    private weak var adminHintLabel: NSTextField?   // shown under "…magic word" in admin mode
    private weak var unlockButton: NSButton?
    private weak var touchIDButton: NSButton?
    private var passcodeMode = false

    // Callbacks the guard wires up.
    var onSubmitPasscode: ((String) -> Void)?
    var onTouchID: (() -> Void)?
    var onSystemUnlock: (() -> Void)?

    // Custom animation resolution (cached by path). A configured animationPath
    // (or a legacy ahahah.gif drop-in) replaces the native wagging finger.
    private var animCachePath = "\u{1}"   // sentinel ≠ any real path so first call computes
    private var animCacheImage: NSImage?
    private func currentAnimation(_ prefs: Prefs) -> NSImage? {
        var path = prefs.animationPath ?? ""
        if path.isEmpty {
            let legacy = Paths.userSupport.appendingPathComponent("ahahah.gif").path
            if FileManager.default.fileExists(atPath: legacy) { path = legacy }
        }
        if path != animCachePath {
            animCachePath = path
            animCacheImage = path.isEmpty ? nil : NSImage(contentsOfFile: path)
        }
        return animCacheImage
    }

    /// `passcode` = show the inline passcode field; otherwise a button that
    /// triggers the system admin dialog. `biometrics` toggles the Touch ID button.
    func show(appName: String, icon: NSImage?, passcode: Bool, biometrics: Bool, prefs: Prefs) {
        rebuildIfGeometryChanged()
        if windows.isEmpty { build() }
        passcodeMode = passcode
        for v in bgViews { v.apply(prefs) }   // match the user's chosen theme
        for label in nameLabels { label.stringValue = appName }
        for iv in iconViews { iv.image = icon }
        // Clear any leftover "Ah ah ah!" / lockout state from a previous app.
        hideNedry()
        passcodeField?.isEnabled = true
        unlockButton?.isEnabled = true

        subtitleLabel?.stringValue = passcode
            ? "Enter your Plonker Blocker passcode to open it."
            : "Administrator approval is required to open it."
        passcodeField?.isHidden = !passcode
        passcodeField?.stringValue = ""
        touchIDButton?.isHidden = !biometrics       // fingerprint offered on any lock
        unlockButton?.title = passcode ? "Unlock" : "Unlock…"

        // Show the cover unconditionally (security), then take activation. On
        // macOS 14+ forcible activation was replaced by a cooperative model: name
        // the app we're stealing focus from so the guard's borderless window can
        // become key and receive passcode keystrokes without a first click.
        for w in windows { w.orderFrontRegardless() }
        if #available(macOS 14.0, *) {
            if let front = NSWorkspace.shared.frontmostApplication, front != .current {
                NSRunningApplication.current.activate(from: front, options: [])
            } else {
                NSApp.activate()
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)   // 11–13: original behavior
        }
        windows.first?.makeKeyAndOrderFront(nil)
        if passcode, let f = passcodeField { f.window?.makeFirstResponder(f) }
        visible = true
    }

    // On a wrong attempt — "Ah ah ah! You didn't say the magic word!"
    // The native animation draws on the card's own surface (no separate panel →
    // no seam). If the user configured a custom animation it replaces the native
    // finger/text instead.
    func showNedry(_ prefs: Prefs) {
        for v in nedryHideViews { v.isHidden = true }
        let anim = currentAnimation(prefs)
        let useGif = anim != nil
        for g in nedryGifViews { g.image = anim; g.isHidden = !useGif; g.animates = useGif }
        for v in nedryNativeViews { v.isHidden = useGif }
        adminHintLabel?.isHidden = passcodeMode   // admin-password hint only in admin mode
        if useGif { for f in fingerViews { f.layer?.removeAnimation(forKey: "wag") } }
        else { startWag() }
    }

    private func hideNedry() {
        for v in nedryNativeViews { v.isHidden = true }
        for g in nedryGifViews { g.animates = false; g.isHidden = true }
        for f in fingerViews { f.layer?.removeAnimation(forKey: "wag") }
        adminHintLabel?.isHidden = true
        for v in nedryHideViews { v.isHidden = false }
    }

    // Native finger wag (±20° about a low pivot, like a scolding wrist).
    private func startWag() {
        for f in fingerViews {
            guard let l = f.layer else { continue }
            l.anchorPoint = CGPoint(x: 0.5, y: 0.3)
            l.position = CGPoint(x: f.frame.midX, y: f.frame.minY + f.frame.height * 0.3)
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = -0.35; a.toValue = 0.35
            a.duration = 0.4; a.autoreverses = true; a.repeatCount = .infinity
            l.add(a, forKey: "wag")
        }
    }

    // Disable the passcode field/Unlock during a lockout (Touch ID stays usable).
    func setLockout(_ locked: Bool, message: String?) {
        passcodeField?.isEnabled = !locked
        unlockButton?.isEnabled = !locked
        subtitleLabel?.stringValue = message
            ?? "Enter your Plonker Blocker passcode to open it."
    }

    // Wrong passcode: clear + shake, keep focus.
    func rejectPasscode() {
        guard let f = passcodeField else { return }
        f.stringValue = ""
        f.window?.makeFirstResponder(f)
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -6, 6, -3, 3, 0]
        shake.duration = 0.35
        f.wantsLayer = true
        f.layer?.add(shake, forKey: "shake")
    }

    func hide() {
        hideNedry()
        passcodeField?.stringValue = ""
        for w in windows { w.orderOut(nil) }
        visible = false
    }

    /// Pre-create the (hidden) cover windows so the very first lock has zero build
    /// latency. Windows stay ordered-out until `show(…)` brings them forward.
    func prebuild() {
        rebuildIfGeometryChanged()
        if windows.isEmpty { build() }
    }

    /// Re-lay the cover to the current screens if a display was added/removed OR
    /// any display's frame changed (resolution, rotation, rearrangement).
    func rebuildIfGeometryChanged() {
        let current = NSScreen.screens.map { $0.frame }
        if current != builtFrames {
            for w in windows { w.orderOut(nil) }
            windows.removeAll(); nameLabels.removeAll(); iconViews.removeAll()
            nedryNativeViews.removeAll(); nedryHideViews.removeAll()
            nedryGifViews.removeAll(); fingerViews.removeAll()
            bgViews.removeAll()
        }
    }

    private func build() {
        builtFrames = NSScreen.screens.map { $0.frame }
        for (i, screen) in NSScreen.screens.enumerated() {
            let w = KeyableWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: 500)  // above apps, below system panels
            w.isOpaque = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.hasShadow = false
            w.ignoresMouseEvents = false
            // Only the primary screen gets the interactive card; others just dim.
            w.contentView = makeContent(size: screen.frame.size, showCard: i == 0)
            windows.append(w)
        }
    }

    private func makeContent(size: CGSize, showCard: Bool) -> NSView {
        let bg = BackgroundView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.apply(PrefsStore.load())
        bgViews.append(bg)
        guard showCard else { return bg }

        // Brand wordmark, low on the screen.
        let wordmark = NSTextField(labelWithString: "🔒  Plonker Blocker")
        wordmark.font = .systemFont(ofSize: 13, weight: .medium)
        wordmark.textColor = NSColor(white: 1, alpha: 0.35)
        wordmark.alignment = .center
        wordmark.frame = NSRect(x: (size.width - 300)/2, y: 44, width: 300, height: 20)
        bg.addSubview(wordmark)

        let cardW: CGFloat = 380, cardH: CGFloat = 420
        let card = NSView(frame: NSRect(x: (size.width - cardW)/2, y: (size.height - cardH)/2,
                                        width: cardW, height: cardH))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(srgbRed: 0.13, green: 0.14, blue: 0.18, alpha: 0.96).cgColor
        card.layer?.cornerRadius = 24
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(white: 1, alpha: 0.09).cgColor
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.5)
        shadow.shadowBlurRadius = 40; shadow.shadowOffset = NSSize(width: 0, height: -8)
        card.shadow = shadow
        card.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]

        // App icon + lock badge.
        let iconSize: CGFloat = 88
        let iconView = NSImageView(frame: NSRect(x: (cardW - iconSize)/2, y: cardH - 32 - iconSize,
                                                 width: iconSize, height: iconSize))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        card.addSubview(iconView); iconViews.append(iconView); nedryHideViews.append(iconView)

        let badgeCfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        let badge = NSImageView(frame: NSRect(x: iconView.frame.maxX - 24, y: iconView.frame.minY - 2,
                                              width: 30, height: 30))
        badge.image = NSImage(systemSymbolName: "lock.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(badgeCfg)
        badge.contentTintColor = NSColor(srgbRed: 0.55, green: 0.5, blue: 0.98, alpha: 1)
        card.addSubview(badge); nedryHideViews.append(badge)

        func label(_ s: String, _ font: NSFont, _ color: NSColor, _ y: CGFloat, _ h: CGFloat) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.font = font; t.textColor = color; t.alignment = .center
            t.lineBreakMode = .byTruncatingTail
            t.frame = NSRect(x: 20, y: y, width: cardW - 40, height: h)
            card.addSubview(t)
            return t
        }
        let name = label("App", .boldSystemFont(ofSize: 22), .white, cardH - 158, 28)
        nameLabels.append(name); nedryHideViews.append(name)
        let lockedLbl = label("is locked", .systemFont(ofSize: 15), NSColor(white: 0.7, alpha: 1), cardH - 184, 20)
        nedryHideViews.append(lockedLbl)
        subtitleLabel = label("Administrator approval is required to open it.",
                              .systemFont(ofSize: 13), NSColor(white: 0.55, alpha: 1), cardH - 220, 18)
        if let s = subtitleLabel { nedryHideViews.append(s) }

        // Inline passcode field.
        let field = NSSecureTextField(frame: NSRect(x: (cardW - 240)/2, y: 172, width: 240, height: 30))
        field.alignment = .center
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = "Passcode"
        field.focusRingType = .none
        field.target = self; field.action = #selector(unlockTapped)  // submit on Return
        field.isHidden = true
        card.addSubview(field); passcodeField = field

        // Accent Unlock button.
        let unlock = NSButton(title: "Unlock", target: self, action: #selector(unlockTapped))
        unlock.bezelStyle = .rounded; unlock.controlSize = .large; unlock.keyEquivalent = "\r"
        unlock.bezelColor = NSColor(srgbRed: 0.45, green: 0.4, blue: 0.95, alpha: 1)
        unlock.frame = NSRect(x: (cardW - 200)/2, y: 120, width: 200, height: 38)
        card.addSubview(unlock); unlockButton = unlock

        // Touch ID button.
        let touch = NSButton(title: "  Unlock with Touch ID", target: self, action: #selector(touchIDTapped))
        touch.bezelStyle = .rounded
        touch.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)
        touch.imagePosition = .imageLeading
        touch.contentTintColor = NSColor(srgbRed: 0.6, green: 0.55, blue: 1, alpha: 1)
        touch.frame = NSRect(x: (cardW - 200)/2, y: 76, width: 200, height: 30)
        touch.isHidden = true
        card.addSubview(touch); touchIDButton = touch

        _ = label("or press ⌘⇥ to switch to another app",
                  .systemFont(ofSize: 11), NSColor(white: 0.42, alpha: 1), 36, 16)

        // "Ah ah ah!" animation. The native version draws directly on the card (no
        // separate panel → no seam over the glow), replacing the hidden icon/name/
        // subtitle. A configured custom animation replaces it (built at show time).
        let ahLbl = label("Ah ah ah!", .boldSystemFont(ofSize: 30), .white, cardH - 68, 36)
        ahLbl.isHidden = true; nedryNativeViews.append(ahLbl)
        let finger = NSTextField(labelWithString: "☝️")
        finger.font = .systemFont(ofSize: 84)
        finger.alignment = .center
        finger.frame = NSRect(x: (cardW - 120)/2, y: 250, width: 120, height: 96)
        finger.wantsLayer = true
        finger.isHidden = true
        card.addSubview(finger)
        fingerViews.append(finger); nedryNativeViews.append(finger)
        let wordLbl = label("You didn't say the magic word", .systemFont(ofSize: 14),
                            NSColor(white: 0.7, alpha: 1), 210, 20)
        wordLbl.isHidden = true; nedryNativeViews.append(wordLbl)

        // Custom-animation image view (populated + revealed only when configured).
        let gif = NSImageView(frame: NSRect(x: 20, y: 206, width: cardW - 40, height: cardH - 222))
        gif.imageScaling = .scaleProportionallyDown
        gif.animates = false
        gif.isHidden = true
        gif.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        card.addSubview(gif); nedryGifViews.append(gif)

        // Smaller admin instruction, under the magic-word line (admin mode only —
        // in passcode mode the field occupies this space).
        let hint = NSTextField(wrappingLabelWithString:
            "Please put the computer administrator password or contact your network administrator.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = NSColor(white: 0.5, alpha: 1)
        hint.alignment = .center; hint.isSelectable = false; hint.drawsBackground = false
        hint.isBezeled = false; hint.maximumNumberOfLines = 2
        hint.frame = NSRect(x: 30, y: 168, width: cardW - 60, height: 34)
        hint.isHidden = true
        card.addSubview(hint); adminHintLabel = hint

        bg.addSubview(card)
        return bg
    }

    @objc private func unlockTapped() {
        if passcodeMode { onSubmitPasscode?(passcodeField?.stringValue ?? "") }
        else { onSystemUnlock?() }
    }

    @objc private func touchIDTapped() { onTouchID?() }
}

// MARK: - Guard

final class GuardDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let cover = CoverController()
    private var unlockUntil: [pid_t: Date] = [:]   // pid -> when its unlock expires
    private var failCounts: [pid_t: Int] = [:]     // system-dialog failures (per pid)
    private var passFailStreak = 0                 // global passcode failures (brute-force guard)
    private var lockoutUntil: Date?                // passcode entry disabled until this time
    private var coveredPID: pid_t?            // app the cover is currently over
    private var currentApp: NSRunningApplication?
    private var authInProgress = false
    private var pendingHide: DispatchWorkItem?
    private var statusItem: NSStatusItem?
    private var authWatchdog: DispatchWorkItem?

    // Wrong-attempt sound. Resolved from prefs.soundPath, then a legacy drop-in
    // (ahahah.mp3/m4a/aiff/wav), then the system "Funk" beep. Cached by path so a
    // changed setting is picked up without a restart.
    private var soundCachePath = "\u{1}"
    private var soundCache: NSSound?
    private func nedrySound(_ prefs: Prefs) -> NSSound? {
        var path = prefs.soundPath ?? ""
        if path.isEmpty {
            for ext in ["mp3", "m4a", "aiff", "wav"] {
                let p = Paths.userSupport.appendingPathComponent("ahahah.\(ext)").path
                if FileManager.default.fileExists(atPath: p) { path = p; break }
            }
        }
        if path != soundCachePath {
            soundCachePath = path
            soundCache = path.isEmpty ? NSSound(named: NSSound.Name("Funk"))
                                      : NSSound(contentsOfFile: path, byReference: true)
        }
        return soundCache
    }

    private func playNedrySound(_ prefs: Prefs) {
        let s = nedrySound(prefs)
        s?.stop()   // restart from the top on rapid retries
        s?.play()
    }

    // Cached policy (re-read only when the file's mtime changes) + fail-closed copy.
    private var cachedPolicy = Policy.empty
    private var policyMTime: Date?
    private var lastGoodPolicy = Policy.empty
    private func policy() -> Policy {
        let mt = PolicyStore.modTime()
        if mt != policyMTime {
            do { cachedPolicy = try PolicyStore.loadStrict(); lastGoodPolicy = cachedPolicy; policyMTime = mt }
            catch { return lastGoodPolicy }   // present but unreadable → keep last known
        }
        return cachedPolicy
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Scheduling priority comes from the LaunchAgent plist ("ProcessType":
        // "Interactive", see GuardAgent.enable), and the AppKit main thread already
        // runs at userInteractive QoS — so no code-side priority bump is needed.
        cover.onSubmitPasscode = { [weak self] pass in self?.tryPasscode(pass) }
        cover.onTouchID = { [weak self] in self?.tryTouchID() }
        cover.onSystemUnlock = { [weak self] in self?.retrySystemUnlock() }

        // Register the frontmost-app observer FIRST and check immediately, so a
        // protected app that is already up is covered with no perceptible gap.
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        _ = policy()                 // warm the policy cache off the first-lock path
        cover.prebuild()             // build the (hidden) cover windows now → instant first lock
        evaluate(NSWorkspace.shared.frontmostApplication)

        // Non-urgent startup work, deferred so it can't delay the first cover.
        DispatchQueue.main.async { [weak self] in
            self?.setupStatusItem()
            Notifier.requestAuth()
        }
    }

    // Unlocked and not yet expired?
    private func isFresh(_ pid: pid_t) -> Bool {
        guard let until = unlockUntil[pid] else { return false }
        return Date() < until
    }

    @objc private func appActivated(_ n: Notification) { evaluate(app(from: n)) }

    @objc private func appLaunched(_ n: Notification) {
        // Only react if the launched app is actually frontmost — a background
        // launch must not blank the screen or steal focus.
        guard let a = app(from: n),
              a == NSWorkspace.shared.frontmostApplication else { return }
        evaluate(a)
    }

    @objc private func appTerminated(_ n: Notification) {
        guard let a = app(from: n) else { return }
        unlockUntil.removeValue(forKey: a.processIdentifier)
        failCounts.removeValue(forKey: a.processIdentifier)
        // Only tear down if the EXACT covered instance died (matching by bundle id
        // would wrongly uncover a still-running sibling). Then re-check the real
        // frontmost so another locked app is immediately re-covered.
        if a.processIdentifier == coveredPID {
            hideCover()
            evaluate(NSWorkspace.shared.frontmostApplication)
        }
    }

    @objc private func screensChanged() {
        cover.rebuildIfGeometryChanged()
        if coveredPID != nil, let app = currentApp {
            let hasPass = policy().passcode != nil
            cover.show(appName: app.localizedName ?? "This app", icon: app.icon,
                       passcode: hasPass, biometrics: biometricsAvailable(), prefs: PrefsStore.load())
            // Re-showing re-enables the field, so re-assert an active lockout.
            if hasPass, lockedOut() {
                cover.setLockout(true, message: "Wrong passcode — wait a moment. Touch ID still works.")
            }
        }
    }

    private func app(from n: Notification) -> NSRunningApplication? {
        n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private func evaluate(_ app: NSRunningApplication?) {
        guard let app else { return }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        // Only ever cover normal, user-facing apps.
        if app.activationPolicy != .regular { return }
        guard let bid = app.bundleIdentifier else { return }
        if bid == "com.apple.SecurityAgent" { return }
        if authInProgress { return }

        let p = policy()
        let locked = AppPolicy.isProtectable(bid)
            && p.apps.contains { $0.bundleID == bid }
            && p.schedule.locks(at: Date())      // only enforce during scheduled windows
            && !isFresh(app.processIdentifier)

        if locked {
            pendingHide?.cancel(); pendingHide = nil
            if coveredPID == app.processIdentifier { return } // already covering; don't re-prompt
            if let old = coveredPID { failCounts[old] = nil } // drop stale system-mode count
            coveredPID = app.processIdentifier
            currentApp = app
            let appName = app.localizedName ?? bid
            let hasPass = p.passcode != nil

            // Paint the cover FIRST — logging (disk) and notifications must never
            // gate the user-visible lock. Load prefs once and reuse it.
            let prefs = PrefsStore.load()
            cover.show(appName: appName, icon: app.icon,
                       passcode: hasPass, biometrics: biometricsAvailable(), prefs: prefs)
            if hasPass {
                // Passcode field is focused; the user can type or tap Touch ID.
                // Re-assert any active brute-force lockout across cover re-shows.
                if lockedOut() { cover.setLockout(true, message: "Wrong passcode — wait a moment. Touch ID still works.") }
            }
            // No passcode set → don't auto-prompt; the user clicks "Unlock…" to
            // bring up the system admin dialog (via onSystemUnlock → attemptUnlock).

            AttemptLog.append(app: appName, bundleID: bid, event: "locked")
            Notifier.notify(title: "🔒 \(appName) is locked", body: "Plonker Blocker is protecting it.")
            RemoteNotify.send(.locked, title: "\(appName) is locked",
                              body: "Someone brought a protected app forward.", prefs: prefs)
        } else {
            scheduleHide()
        }
    }

    // Cached (short TTL) so rapid re-shows / screen changes don't each pay the
    // canEvaluatePolicy hardware query. Invalidated after a biometric failure,
    // which can flip availability (e.g. biometry lockout).
    private var bioCache: (value: Bool, at: Date)?
    private func biometricsAvailable() -> Bool {
        if let c = bioCache, Date().timeIntervalSince(c.at) < 3 { return c.value }
        var err: NSError?
        let v = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        bioCache = (v, Date())
        return v
    }

    private func succeedUnlock(method: String) {
        passFailStreak = 0; lockoutUntil = nil
        guard let app = currentApp else { return }
        let pid = app.processIdentifier
        failCounts[pid] = 0
        // Duration comes from the app's "Unlock for" setting. 0 = never re-lock.
        let minutes = policy().relockMinutes
        unlockUntil[pid] = minutes <= 0 ? .distantFuture : Date().addingTimeInterval(Double(minutes) * 60)
        let name = app.localizedName ?? (app.bundleIdentifier ?? "app")
        AttemptLog.append(app: name, bundleID: app.bundleIdentifier ?? "", event: "unlocked", method: method)
        RemoteNotify.send(.unlocked, title: "\(name) unlocked", body: "Unlocked via \(method).")
        hideCover()
        app.activate()
    }

    // In a passcode lockout window? (Global, survives cover hide / app-switching.)
    private func lockedOut() -> Bool {
        if let until = lockoutUntil {
            if Date() < until { return true }
            lockoutUntil = nil
        }
        return false
    }

    private func tryPasscode(_ entered: String) {
        guard !authInProgress, !lockedOut(), !entered.isEmpty else { return }
        if Passcode.verify(entered, against: policy().passcode) { succeedUnlock(method: "passcode"); return }

        // Wrong passcode: one try at a time. "Ah ah ah!" fires immediately and the
        // field locks with an escalating backoff (5s, 10s, 20s, 40s, 60s cap) —
        // blocks online brute force outright. Touch ID stays available.
        passFailStreak += 1
        let prefs = PrefsStore.load()
        let appName = currentApp?.localizedName ?? "a locked app"
        AttemptLog.append(app: currentApp?.localizedName ?? "app",
                          bundleID: currentApp?.bundleIdentifier ?? "", event: "failed", method: "passcode")
        cover.rejectPasscode()
        if prefs.ahahahEnabled { cover.showNedry(prefs) }
        if prefs.soundEnabled { playNedrySound(prefs) }
        if passFailStreak == 1 {
            Notifier.notify(title: "⚠️ Failed unlock attempt",
                            body: "Someone is trying to open “\(appName)”.")
            RemoteNotify.send(.failed, title: "Failed unlock attempt",
                              body: "Wrong passcode entered for “\(appName)”.", prefs: prefs)
        }
        let backoff = min(60.0, 5.0 * pow(2.0, Double(passFailStreak - 1)))
        lockoutUntil = Date().addingTimeInterval(backoff)
        cover.setLockout(true, message: "Wrong passcode — wait \(Int(backoff))s. Touch ID still works.")
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in
            guard let self, !self.lockedOut() else { return }  // a newer lockout may be active
            self.cover.setLockout(false, message: nil)
        }
    }

    private func tryTouchID() {
        guard let app = currentApp, !authInProgress else { return }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Use Passcode"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else { return }
        let pid = app.processIdentifier
        authInProgress = true
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "unlock “\(app.localizedName ?? "this app")”") { ok, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.authInProgress = false
                if ok, self.coveredPID == pid, !app.isTerminated {
                    self.succeedUnlock(method: "touchid")
                } else {
                    // Cancel/failed biometric → keep the cover; the passcode field
                    // is available. A failure can flip biometry availability, so
                    // drop the cache. Re-check frontmost for stranded-cover safety.
                    self.bioCache = nil
                    self.evaluate(NSWorkspace.shared.frontmostApplication)
                }
            }
        }
    }

    private func scheduleHide() {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideCover() }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func hideCover() {
        pendingHide?.cancel(); pendingHide = nil
        if let p = coveredPID { failCounts[p] = nil }   // fresh count next session
        coveredPID = nil
        currentApp = nil
        cover.hide()
    }

    private func attemptUnlock(_ app: NSRunningApplication) {
        guard !authInProgress else { return }
        authInProgress = true
        // Watchdog: never let a wedged auth call leave the cover permanently stuck.
        let dog = DispatchWorkItem { [weak self] in
            guard let self, self.authInProgress else { return }
            self.authInProgress = false
            self.evaluate(NSWorkspace.shared.frontmostApplication)
        }
        authWatchdog = dog
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: dog)

        let name = app.localizedName ?? app.bundleIdentifier ?? "This app"
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Gate.authorize(
                prompt: "“\(name)” is locked by Plonker Blocker.\n\n"
                      + "Enter an administrator name and password to use it."
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.authWatchdog?.cancel(); self.authWatchdog = nil
                self.authInProgress = false
                // Only unlock if the app we prompted for is still the covered,
                // live app — a kill during the prompt must not record a stale pid.
                if outcome == .authorized, self.coveredPID == pid, !app.isTerminated {
                    self.succeedUnlock(method: "admin")
                } else {
                    if self.coveredPID == pid, !app.isTerminated {
                        self.failCounts[pid, default: 0] += 1
                        if outcome == .failed {
                            AttemptLog.append(app: name, bundleID: app.bundleIdentifier ?? "",
                                              event: "failed", method: "admin")
                            RemoteNotify.send(.failed, title: "Failed unlock attempt",
                                              body: "Wrong administrator password entered for “\(name)”.")
                        }
                        // A wrong password (the dialog enforced its own 3 tries) fires
                        // "Ah ah ah!" immediately; repeated cancels fire it after 3.
                        let prefs = PrefsStore.load()
                        if prefs.ahahahEnabled, outcome == .failed || (self.failCounts[pid] ?? 0) >= 3 {
                            self.cover.showNedry(prefs)
                            if prefs.soundEnabled { self.playNedrySound(prefs) }
                        }
                    }
                    // Re-check the real frontmost so a stranded cover is lowered.
                    self.evaluate(NSWorkspace.shared.frontmostApplication)
                }
            }
        }
    }

    private func retrySystemUnlock() {
        if let app = currentApp { attemptUnlock(app) }
    }

    // MARK: - Menu-bar (tray) item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Custom tray mark (the derpy prohibition face) as a vector PDF template
            // — NSImage loads PDF on every macOS 11–26 (standalone SVG only decodes
            // on 14+). template = auto light/dark menu-bar tint.
            if let url = Bundle.main.url(forResource: "TrayIcon", withExtension: "pdf"),
               let img = NSImage(contentsOf: url) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                button.image = img
            } else if let img = NSImage(systemSymbolName: "lock.fill",
                                        accessibilityDescription: "Plonker Blocker") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "🔒"
            }
        }
        let menu = NSMenu()
        menu.delegate = self          // rebuilt on open so it always reflects state
        item.menu = menu
        statusItem = item
    }

    // Rebuild the menu each time it opens so counts/checkmarks stay current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let count = policy().apps.count
        let header = NSMenuItem(title: "Plonker Blocker — Protection On", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let sub = NSMenuItem(
            title: count == 0 ? "No apps locked yet" : "\(count) app\(count == 1 ? "" : "s") locked",
            action: nil, keyEquivalent: "")
        sub.isEnabled = false
        menu.addItem(sub)

        menu.addItem(.separator())

        let lockNow = NSMenuItem(title: "Lock All Now", action: #selector(lockAllNow), keyEquivalent: "")
        lockNow.target = self
        menu.addItem(lockNow)

        menu.addItem(.separator())

        let options = NSMenuItem(title: "Options…", action: #selector(openManager), keyEquivalent: "")
        options.target = self
        menu.addItem(options)

        let off = NSMenuItem(title: "Turn Off Protection…", action: #selector(turnOff), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
    }

    @objc private func lockAllNow() {
        unlockUntil.removeAll()                 // everything must re-authenticate
        evaluate(NSWorkspace.shared.frontmostApplication)
    }

    @objc private func openManager() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.plonkerblocker.app") {
            NSWorkspace.shared.open(url)
        }
    }

    // Turning protection off is a weakening action → require admin, then remove
    // the login item and quit (disableFromGuard terminates this process).
    @objc private func turnOff() {
        guard Gate.requestAdminAuthorization(
            prompt: "Turn off Plonker Blocker protection?\n\n"
                  + "Enter an administrator name and password to continue.") else { return }
        AttemptLog.append(app: "Plonker Blocker", bundleID: "", event: "protection_off")
        // Blocking: we terminate right after, so a fire-and-forget POST wouldn't
        // leave the machine. Bounded wait so a dead network can't hang the quit.
        RemoteNotify.sendBlocking(.protectionOff, title: "Protection turned off",
                                  body: "Plonker Blocker protection was disabled on this Mac.")
        GuardAgent.disableFromGuard()
        NSApp.terminate(nil)
    }
}

@main
enum GuardMain {
    static let delegate = GuardDelegate()
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
