import AppKit
import UniformTypeIdentifiers

// ============================================================================
// Plonker Blocker manager: admin-gated config UI for the window-lock approach.
// It records which apps to protect (by bundle identifier) and turns the
// background guard agent on/off. It never moves or modifies any app bundle.
// Security-relevant settings live in a root-owned policy (PolicyStore); only
// cosmetic prefs are user-writable (PrefsStore).
// ============================================================================

// MARK: - CLI

func runCLI(_ args: [String]) -> Int32 {
    func err(_ s: String) { FileHandle.standardError.write(Data("\(s)\n".utf8)) }
    func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        return v.hasPrefix("--") ? nil : v
    }
    func requireAdmin() -> Bool {
        if userIsAdmin() { return true }
        err("Error: administrator privileges are required."); return false
    }

    if args.contains("--status") {
        print("Protection: \(GuardAgent.isEnabled() ? "ENABLED" : "disabled")"
            + " (guard \(GuardAgent.isRunning() ? "running" : "not running"))")
        return 0
    }
    if args.contains("--list") {
        let apps = PolicyStore.load().apps
        if apps.isEmpty { print("No protected apps.") }
        for a in apps { print("• \(a.name)  [\(a.bundleID)]\n    \(a.path)") }
        return 0
    }
    if args.contains("--log") {
        let rows = AttemptLog.recent(50)
        if rows.isEmpty { print("No recorded attempts.") }
        for a in rows { print("\(a.at)  \(a.event)\(a.method.map { " (\($0))" } ?? "")  \(a.app)") }
        return 0
    }
    if args.contains("--add") {
        guard let path = value(after: "--add") else { err("Error: --add requires an app path."); return 2 }
        guard requireAdmin() else { return 1 }
        do {
            try PolicyStore.addApp(at: URL(fileURLWithPath: path).standardizedFileURL)
            print("Protected “\(path)”.")
            return 0
        } catch { err("Error: \(error.localizedDescription)"); return 1 }
    }
    if args.contains("--remove") {
        guard let key = value(after: "--remove") else { err("Error: --remove requires a bundle id or path."); return 2 }
        guard requireAdmin() else { return 1 }
        let k = key.hasSuffix(".app") ? URL(fileURLWithPath: key).standardizedFileURL.path : key
        do {
            if try PolicyStore.removeApp(matching: k) { print("Unprotected “\(key)”."); return 0 }
            err("Error: \(AppError.notFound(key).localizedDescription)"); return 1
        } catch { err("Error: \(error.localizedDescription)"); return 1 }
    }
    if args.contains("--enable") {
        guard requireAdmin() else { return 1 }
        do { try GuardAgent.enable(); print("Protection enabled."); return 0 }
        catch { err("Error: \(error.localizedDescription)"); return 1 }
    }
    if args.contains("--disable") {
        guard requireAdmin() else { return 1 }
        GuardAgent.disable(); print("Protection disabled."); return 0
    }
    if args.contains("--set-passcode") {
        guard requireAdmin() else { return 1 }
        let pass: String
        if let v = value(after: "--set-passcode") {
            err("Warning: passing the passcode as an argument leaks it to your shell "
              + "history. Prefer the interactive prompt (omit the value) or the app.")
            pass = v
        } else {
            let p1 = String(cString: getpass("New passcode: "))
            let p2 = String(cString: getpass("Confirm passcode: "))
            guard p1 == p2 else { err("Error: passcodes don't match."); return 1 }
            pass = p1
        }
        guard let rec = Passcode.makeRecord(pass) else {
            err("Error: passcode must be at least \(Passcode.minLength) characters."); return 1
        }
        do { try PolicyStore.setPasscode(rec); print("Unlock passcode set."); return 0 }
        catch { err("Error: \(error.localizedDescription)"); return 1 }
    }
    if args.contains("--clear-passcode") {
        guard requireAdmin() else { return 1 }
        do { try PolicyStore.setPasscode(nil); print("Unlock passcode cleared (falls back to admin dialog)."); return 0 }
        catch { err("Error: \(error.localizedDescription)"); return 1 }
    }
    err("""
    Usage:
      PlonkerBlocker                          Launch the manager (admin-gated)
      PlonkerBlocker --status                 Show whether protection is on
      PlonkerBlocker --list                   List protected apps
      PlonkerBlocker --log                    Show recent unlock attempts
      PlonkerBlocker --add <app>              Protect an app
      PlonkerBlocker --remove <id|app>        Stop protecting an app
      PlonkerBlocker --enable | --disable     Turn the background guard on/off
      PlonkerBlocker --set-passcode           Set the unlock passcode (prompts securely)
      PlonkerBlocker --clear-passcode         Remove it (use the admin dialog)
    """)
    return 2
}

// MARK: - GUI

final class ManagerDelegate: NSObject, NSApplicationDelegate,
                             NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var window: NSWindow!
    private var tableView: NSTableView!
    private var searchField: NSSearchField!
    private var statusLabel: NSTextField!
    private var statusPill: NSView!
    private var toggleButton: NSButton!
    private var relockPopup: NSPopUpButton!
    private var emptyLabel: NSTextField!
    private var gradientView: BackgroundView!

    private var apps: [ProtectedApp] = []        // full list, in policy order
    private var filtered: [ProtectedApp] = []    // what the table shows

    private let relockChoices: [(String, Int)] = [
        ("1 minute", 1), ("5 minutes", 5), ("15 minutes", 15),
        ("30 minutes", 30), ("1 hour", 60), ("Never", 0),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        let granted = Gate.requestAdminAuthorization(
            prompt: "Plonker Blocker — manage locked apps.\n\n"
                  + "Enter an administrator name and password to continue.")
        guard granted else { Gate.showDenied(appName: "Plonker Blocker"); NSApp.terminate(nil); return }
        Migration.run()                 // one-time move from the old AdminGate layout
        Notifier.requestAuth()          // ask once so lock/unlock alerts can show
        setupAppMenu()
        buildWindow()
        reload()
        if PolicyStore.load().passcode == nil {
            let a = NSAlert()
            a.messageText = "Set an unlock passcode?"
            a.informativeText =
                "Protected apps can unlock with a Plonker Blocker passcode (and Touch ID) "
              + "right on the lock screen. Without one, they fall back to the macOS admin "
              + "password dialog."
            a.addButton(withTitle: "Set Passcode…")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn { setPasscode() }
        }
    }

    private func buildWindow() {
        let W: CGFloat = 760, H: CGFloat = 520
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Plonker Blocker"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.center(); window.isReleasedWhenClosed = false

        let content = BackgroundView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        content.apply(PrefsStore.load())
        gradientView = content

        // ── Header ────────────────────────────────────────────────
        let iconView = NSImageView(frame: NSRect(x: 28, y: 450, width: 48, height: 48))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(iconView)

        let header = NSTextField(labelWithString: "Plonker Blocker")
        header.font = .boldSystemFont(ofSize: 22); header.textColor = .white
        header.frame = NSRect(x: 88, y: 470, width: 360, height: 30)
        content.addSubview(header)

        let tagline = NSTextField(labelWithString: "Lock apps behind a passcode or Touch ID")
        tagline.font = .systemFont(ofSize: 12.5); tagline.textColor = NSColor(white: 1, alpha: 0.55)
        tagline.frame = NSRect(x: 88, y: 451, width: 380, height: 18)
        content.addSubview(tagline)

        // Status pill + toggle share a row baseline so they align.
        let rowY: CGFloat = 459, rowH: CGFloat = 30, pillW: CGFloat = 128
        statusPill = NSView(frame: NSRect(x: 458, y: rowY, width: pillW, height: rowH))
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = rowH / 2
        statusPill.layer?.masksToBounds = true
        content.addSubview(statusPill)

        let lineH: CGFloat = 16
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.alignment = .center
        statusLabel.isBezeled = false; statusLabel.isEditable = false; statusLabel.drawsBackground = false
        statusLabel.frame = NSRect(x: 0, y: (rowH - lineH) / 2, width: pillW, height: lineH)
        statusPill.addSubview(statusLabel)

        toggleButton = NSButton(title: "Turn Protection On",
                                target: self, action: #selector(toggleProtection))
        toggleButton.bezelStyle = .rounded
        toggleButton.controlSize = .large
        toggleButton.frame = NSRect(x: 596, y: rowY, width: 140, height: rowH)
        content.addSubview(toggleButton)

        // ── Search + section actions ──────────────────────────────
        searchField = NSSearchField(frame: NSRect(x: 28, y: 418, width: 420, height: 26))
        searchField.placeholderString = "Filter locked apps"
        searchField.delegate = self
        searchField.focusRingType = .none
        content.addSubview(searchField)

        func topButton(_ title: String, _ x: CGFloat, _ w: CGFloat, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded; b.frame = NSRect(x: x, y: 416, width: w, height: 30)
            return b
        }
        content.addSubview(topButton("Schedule…", 456, 132, #selector(editSchedule)))
        content.addSubview(topButton("Activity…", 596, 140, #selector(showLog)))

        // ── Table card ────────────────────────────────────────────
        let scroll = NSScrollView(frame: NSRect(x: 28, y: 76, width: 704, height: 330))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(srgbRed: 0.15, green: 0.16, blue: 0.21, alpha: 1)
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 14
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        scroll.layer?.masksToBounds = true

        tableView = NSTableView()
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 46
        tableView.headerView = nil
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.doubleAction = #selector(unprotectSelected)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        col.width = 700
        tableView.addTableColumn(col)
        tableView.dataSource = self; tableView.delegate = self
        tableView.registerForDraggedTypes([.string])        // drag to reorder
        tableView.draggingDestinationFeedbackStyle = .gap
        scroll.documentView = tableView
        content.addSubview(scroll)

        emptyLabel = NSTextField(labelWithString:
            "No apps locked yet.\nClick “Protect App…” to choose one.")
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = NSColor(white: 1, alpha: 0.4)
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.frame = NSRect(x: 28, y: 218, width: 704, height: 44)
        content.addSubview(emptyLabel)

        // ── Bottom toolbar ────────────────────────────────────────
        func button(_ title: String, _ x: CGFloat, _ w: CGFloat, _ sel: Selector, key: Bool = false) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded; b.frame = NSRect(x: x, y: 24, width: w, height: 32)
            if key { b.keyEquivalent = "\r" }
            return b
        }
        content.addSubview(button("Protect App…", 28, 130, #selector(protectApp), key: true))
        content.addSubview(button("Unprotect", 166, 96, #selector(unprotectSelected)))

        let relockLabel = NSTextField(labelWithString: "Unlock for:")
        relockLabel.font = .systemFont(ofSize: 12); relockLabel.textColor = NSColor(white: 1, alpha: 0.6)
        relockLabel.alignment = .right
        relockLabel.frame = NSRect(x: 356, y: 30, width: 76, height: 18)
        content.addSubview(relockLabel)

        relockPopup = NSPopUpButton(frame: NSRect(x: 438, y: 24, width: 120, height: 30))
        for (title, tag) in relockChoices {
            relockPopup.addItem(withTitle: title); relockPopup.lastItem?.tag = tag
        }
        relockPopup.target = self; relockPopup.action = #selector(relockChanged)
        content.addSubview(relockPopup)

        content.addSubview(button("Quit", 650, 86, #selector(quitApp)))

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func relockChanged() {
        do { try PolicyStore.setRelock(relockPopup.selectedTag()) }
        catch { presentError(error); reload() }
    }

    // MARK: Background prefs

    @objc private func pickBgTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        PrefsStore.update { $0.backgroundTheme = id; $0.backgroundImagePath = nil }
        gradientView.apply(PrefsStore.load()); setupAppMenu()
    }

    @objc private func pickBgImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a background image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            PrefsStore.update { $0.backgroundImagePath = url.path }
            self.gradientView.apply(PrefsStore.load()); self.setupAppMenu()
        }
    }

    @objc private func resetBackground() {
        PrefsStore.update { $0.backgroundTheme = nil; $0.backgroundImagePath = nil }
        gradientView.apply(PrefsStore.load()); setupAppMenu()
    }

    @objc private func toggleAhahah() {
        PrefsStore.update { $0.ahahahEnabled.toggle() }; setupAppMenu()
    }
    @objc private func toggleSound() {
        PrefsStore.update { $0.soundEnabled.toggle() }; setupAppMenu()
    }

    // Custom lock-screen animation + sound. The running guard resolves these from
    // prefs on the next lock (cached by path), so no restart is needed.
    @objc private func chooseAnimation() {
        let panel = NSOpenPanel()
        panel.title = "Choose a lock-screen animation"
        panel.allowedContentTypes = [.gif, .image]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            PrefsStore.update { $0.animationPath = url.path; $0.ahahahEnabled = true }
            self.setupAppMenu()
        }
    }
    @objc private func chooseSound() {
        let panel = NSOpenPanel()
        panel.title = "Choose a wrong-passcode sound"
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            PrefsStore.update { $0.soundPath = url.path; $0.soundEnabled = true }
            self.setupAppMenu()
        }
    }
    @objc private func resetMedia() {
        PrefsStore.update { $0.animationPath = nil; $0.soundPath = nil }
        setupAppMenu()
    }

    @objc private func editNotifications() { NotificationsEditor().runModal() }

    // MARK: Reload / status

    private func applyFilter() {
        let q = (searchField?.stringValue ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        filtered = q.isEmpty ? apps
            : apps.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
        tableView?.reloadData()
        emptyLabel?.isHidden = !filtered.isEmpty
        emptyLabel?.stringValue = q.isEmpty
            ? "No apps locked yet.\nClick “Protect App…” to choose one."
            : "No locked apps match “\(searchField.stringValue)”."
    }

    private func reload() {
        let policy = PolicyStore.load()
        apps = policy.apps
        applyFilter()
        relockPopup?.selectItem(withTag: policy.relockMinutes)

        let on = GuardAgent.isEnabled()
        func pill(_ text: String, _ bg: NSColor, _ fg: NSColor) {
            statusLabel.stringValue = text
            statusLabel.textColor = fg
            statusPill.layer?.backgroundColor = bg.cgColor
        }
        if on && !GuardAgent.isRunning() {
            pill("● Guard stopped", NSColor.systemOrange.withAlphaComponent(0.18), .systemOrange)
        } else if on {
            pill("● Protection On", NSColor.systemGreen.withAlphaComponent(0.18), .systemGreen)
        } else {
            pill("○ Protection Off", NSColor.tertiaryLabelColor.withAlphaComponent(0.18), .secondaryLabelColor)
        }
        toggleButton.title = on ? "Turn Protection Off" : "Turn Protection On"
    }

    // A minimal main menu so ⌘W / ⌘Q work (the app has no nib).
    private func setupAppMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "About Plonker Blocker",
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())

        // ── Protection ───────────────────────────────────────
        let hasPass = PolicyStore.load().passcode != nil
        let setPass = NSMenuItem(
            title: hasPass ? "Change Unlock Passcode…" : "Set Unlock Passcode (Optional)…",
            action: #selector(setPasscode), keyEquivalent: "")
        setPass.target = self
        appMenu.addItem(setPass)
        if hasPass {
            let rm = NSMenuItem(title: "Remove Unlock Passcode",
                                action: #selector(removePasscode), keyEquivalent: "")
            rm.target = self
            appMenu.addItem(rm)
        }
        let sched = NSMenuItem(title: "Locking Schedule…", action: #selector(editSchedule), keyEquivalent: "")
        sched.target = self; appMenu.addItem(sched)
        let notif = NSMenuItem(title: "Notifications…", action: #selector(editNotifications), keyEquivalent: "")
        notif.target = self; appMenu.addItem(notif)

        appMenu.addItem(.separator())

        // ── Appearance ───────────────────────────────────────
        let prefs = PrefsStore.load()
        // Lock-screen submenu (toggles + custom animation/sound).
        let lockItem = NSMenuItem(title: "Lock Screen", action: nil, keyEquivalent: "")
        let lockMenu = NSMenu()
        let ah = NSMenuItem(title: "Play “Ah ah ah!” animation", action: #selector(toggleAhahah), keyEquivalent: "")
        ah.target = self; ah.state = prefs.ahahahEnabled ? .on : .off
        lockMenu.addItem(ah)
        let snd = NSMenuItem(title: "Play sound on wrong passcode", action: #selector(toggleSound), keyEquivalent: "")
        snd.target = self; snd.state = prefs.soundEnabled ? .on : .off
        lockMenu.addItem(snd)
        lockMenu.addItem(.separator())
        let chAnim = NSMenuItem(title: prefs.animationPath == nil ? "Choose Animation…" : "Change Animation…",
                                action: #selector(chooseAnimation), keyEquivalent: "")
        chAnim.target = self; lockMenu.addItem(chAnim)
        let chSnd = NSMenuItem(title: prefs.soundPath == nil ? "Choose Sound…" : "Change Sound…",
                               action: #selector(chooseSound), keyEquivalent: "")
        chSnd.target = self; lockMenu.addItem(chSnd)
        if prefs.animationPath != nil || prefs.soundPath != nil {
            let resetM = NSMenuItem(title: "Reset to Built-in Animation & Sound",
                                    action: #selector(resetMedia), keyEquivalent: "")
            resetM.target = self; lockMenu.addItem(resetM)
        }
        lockItem.submenu = lockMenu
        appMenu.addItem(lockItem)

        // Background submenu (preset themes + custom image).
        let bgItem = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
        let bgMenu = NSMenu()
        let usingImage = prefs.backgroundImagePath != nil
        for t in bgThemes {
            let it = NSMenuItem(title: t.name, action: #selector(pickBgTheme(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = t.id
            it.state = (!usingImage && (prefs.backgroundTheme ?? "indigo") == t.id) ? .on : .off
            bgMenu.addItem(it)
        }
        bgMenu.addItem(.separator())
        let img = NSMenuItem(title: "Custom Image…", action: #selector(pickBgImage), keyEquivalent: "")
        img.target = self; img.state = usingImage ? .on : .off
        bgMenu.addItem(img)
        let reset = NSMenuItem(title: "Reset to Default", action: #selector(resetBackground), keyEquivalent: "")
        reset.target = self
        bgMenu.addItem(reset)
        bgItem.submenu = bgMenu
        appMenu.addItem(bgItem)

        appMenu.addItem(.separator())

        // ── Activity ─────────────────────────────────────────
        let log = NSMenuItem(title: "Activity Log…", action: #selector(showLog), keyEquivalent: "")
        log.target = self; appMenu.addItem(log)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window",
                        action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Plonker Blocker",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func setPasscode() {
        let alert = NSAlert()
        alert.messageText = PolicyStore.load().passcode != nil ? "Change Unlock Passcode" : "Set Unlock Passcode"
        alert.informativeText =
            "This passcode unlocks protected apps on the lock screen. It's separate "
          + "from your macOS admin password."
        let new = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        new.placeholderString = "New passcode"
        let confirm = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        confirm.placeholderString = "Confirm passcode"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 58))
        box.addSubview(new); box.addSubview(confirm)
        alert.accessoryView = box
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = new
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !new.stringValue.isEmpty else {
            presentError(AppError.installFailed("passcode can't be empty")); return
        }
        guard new.stringValue == confirm.stringValue else {
            let a = NSAlert(); a.messageText = "Passcodes don't match"
            a.addButton(withTitle: "OK"); a.runModal(); return
        }
        guard let rec = Passcode.makeRecord(new.stringValue) else {
            let a = NSAlert(); a.messageText = "Passcode too short"
            a.informativeText = "Use at least \(Passcode.minLength) characters."
            a.addButton(withTitle: "OK"); a.runModal(); return
        }
        do { try PolicyStore.setPasscode(rec) } catch { presentError(error); return }
        let ok = NSAlert(); ok.messageText = "Unlock passcode set."
        ok.informativeText = "Protected apps now unlock with this passcode or Touch ID."
        ok.addButton(withTitle: "OK"); ok.runModal()
        setupAppMenu()   // reflect Change/Remove state
    }

    @objc private func removePasscode() {
        let a = NSAlert()
        a.messageText = "Remove unlock passcode?"
        a.informativeText =
            "The passcode is optional. Without it, protected apps fall back to the "
          + "macOS administrator password dialog (Touch ID still works)."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try PolicyStore.setPasscode(nil) } catch { presentError(error); return }
        setupAppMenu()
    }

    // MARK: About / Schedule / log

    @objc private func showAbout() { AboutPanel().runModal() }

    @objc private func editSchedule() {
        let current = PolicyStore.load().schedule
        guard let updated = ScheduleEditor(current: current).runModal() else { return }
        do { try PolicyStore.setSchedule(updated) } catch { presentError(error) }
    }

    @objc private func showLog() { LogViewer().runModal() }

    // MARK: Actions

    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func toggleProtection() {
        if GuardAgent.isEnabled() {
            GuardAgent.disable()
        } else {
            do { try GuardAgent.enable() }
            catch { presentError(error) }
            if PolicyStore.load().apps.isEmpty {
                let a = NSAlert()
                a.messageText = "Protection is on, but no apps are locked yet"
                a.informativeText = "Click “Protect App…” to choose which apps require admin approval."
                a.addButton(withTitle: "OK"); a.runModal()
            }
        }
        reload()
    }

    // Currently running, user-facing apps the user can pick from directly,
    // deduped by bundle id and excluding Plonker Blocker itself (no self-lock).
    private func runningAppChoices() -> [NSRunningApplication] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != nil && $0.bundleURL != nil }
            .filter { !($0.bundleIdentifier ?? "").hasPrefix("com.plonkerblocker") }
            .sorted { ($0.localizedName ?? "") .localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
            .filter { seen.insert($0.bundleIdentifier!).inserted }
    }

    @objc private func protectApp() {
        let choices = runningAppChoices()

        let alert = NSAlert()
        alert.messageText = "Add an app to lock"
        alert.informativeText = choices.isEmpty
            ? "Browse for the app you want to lock."
            : "Pick one of your open apps, or browse for any other app."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Browse…")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        if choices.isEmpty {
            popup.addItem(withTitle: "No open apps")
            popup.isEnabled = false
            alert.buttons.first?.isEnabled = false
        } else {
            for a in choices { popup.addItem(withTitle: a.localizedName ?? a.bundleIdentifier ?? "?") }
        }
        alert.accessoryView = popup
        alert.window.initialFirstResponder = popup

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard !choices.isEmpty, let url = choices[popup.indexOfSelectedItem].bundleURL else { return }
            addApp(at: url)
        case .alertSecondButtonReturn:
            browseForApp()
        default:
            return
        }
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to lock"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            self.addApp(at: url)
        }
    }

    private func addApp(at url: URL) {
        do { try PolicyStore.addApp(at: url); reload() }
        catch { presentError(error) }
    }

    @objc private func unprotectSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        do { try PolicyStore.removeApp(matching: filtered[row].bundleID) }
        catch { presentError(error) }
        reload()
    }

    private func presentError(_ error: Error) {
        let a = NSAlert(); a.alertStyle = .warning; a.messageText = "Plonker Blocker"
        a.informativeText = error.localizedDescription
        a.addButton(withTitle: "OK"); a.runModal()
    }

    // MARK: Table (data + drag-to-reorder)

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as AnyObject) === searchField { applyFilter() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let a = filtered[row]
        let width = col?.width ?? 700
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 46))

        let icon = NSImageView(frame: NSRect(x: 12, y: 7, width: 32, height: 32))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = NSWorkspace.shared.icon(forFile: a.path)
        cell.addSubview(icon)

        let name = NSTextField(labelWithString: a.name)
        name.font = .systemFont(ofSize: 14, weight: .medium); name.textColor = .white
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 54, y: 23, width: width - 70, height: 18)
        cell.addSubview(name)

        let bundle = NSTextField(labelWithString: a.bundleID)
        bundle.font = .systemFont(ofSize: 11); bundle.textColor = NSColor(white: 1, alpha: 0.5)
        bundle.lineBreakMode = .byTruncatingMiddle
        bundle.frame = NSRect(x: 54, y: 5, width: width - 70, height: 15)
        cell.addSubview(bundle)

        return cell
    }

    // Reordering only makes sense on the unfiltered list.
    private var canReorder: Bool { searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }

    func tableView(_ tv: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard canReorder else { return nil }
        let item = NSPasteboardItem(); item.setString(String(row), forType: .string); return item
    }

    func tableView(_ tv: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard canReorder, op == .above else { return [] }
        return .move
    }

    func tableView(_ tv: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard canReorder,
              let str = info.draggingPasteboard.pasteboardItems?.first?.string(forType: .string),
              let src = Int(str), src >= 0, src < apps.count else { return false }
        var newApps = apps
        let moved = newApps.remove(at: src)
        var dest = row
        if src < dest { dest -= 1 }
        dest = max(0, min(dest, newApps.count))
        newApps.insert(moved, at: dest)
        apps = newApps
        PolicyStore.reorder(newApps)
        applyFilter()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - About panel (app-modal)

final class AboutPanel: NSObject {
    private let panel: NSWindow

    override init() {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 320),
                         styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "About Plonker Blocker"
        panel.appearance = NSAppearance(named: .darkAqua)
        super.init()

        let c = panel.contentView!
        let info = Bundle.main.infoDictionary ?? [:]

        let icon = NSImageView(frame: NSRect(x: (340 - 96)/2, y: 200, width: 96, height: 96))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        c.addSubview(icon)

        func label(_ s: String, _ font: NSFont, _ color: NSColor, _ y: CGFloat, _ h: CGFloat) {
            let t = NSTextField(labelWithString: s)
            t.font = font; t.textColor = color; t.alignment = .center
            t.frame = NSRect(x: 20, y: y, width: 300, height: h)
            c.addSubview(t)
        }
        label("Plonker Blocker", .boldSystemFont(ofSize: 18), .labelColor, 168, 24)

        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? version
        label("Version \(version) (\(build))", .systemFont(ofSize: 12), .secondaryLabelColor, 146, 16)

        label("Locks apps behind a passcode, Touch ID, or an admin password.",
              .systemFont(ofSize: 11), .secondaryLabelColor, 112, 28)

        let copyright = info["NSHumanReadableCopyright"] as? String
            ?? "© 2026 Plonker Blocker. All rights reserved."
        label(copyright, .systemFont(ofSize: 11), .tertiaryLabelColor, 84, 16)

        let close = NSButton(title: "OK", target: self, action: #selector(closeTapped))
        close.bezelStyle = .rounded; close.keyEquivalent = "\r"
        close.frame = NSRect(x: (340 - 90)/2, y: 20, width: 90, height: 32)
        c.addSubview(close)
    }

    func runModal() {
        panel.center()
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
    }

    @objc private func closeTapped() { NSApp.stopModal() }
}

// MARK: - Notifications editor (app-modal panel)

final class NotificationsEditor: NSObject {
    private let panel: NSWindow
    private let enableCheck: NSButton
    private let tokenField = NSTextField()
    private let chatField = NSTextField()
    private let webhookField = NSTextField()
    private let cbLocked: NSButton
    private let cbUnlocked: NSButton
    private let cbFailed: NSButton
    private let cbProtOff: NSButton
    private let statusLabel = NSTextField(labelWithString: "")

    override init() {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 466),
                         styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Notifications"
        panel.appearance = NSAppearance(named: .darkAqua)
        enableCheck = NSButton(checkboxWithTitle: "Send external alerts (off by default)", target: nil, action: nil)
        cbLocked = NSButton(checkboxWithTitle: "An app is locked", target: nil, action: nil)
        cbUnlocked = NSButton(checkboxWithTitle: "An app is unlocked", target: nil, action: nil)
        cbFailed = NSButton(checkboxWithTitle: "A wrong password is entered", target: nil, action: nil)
        cbProtOff = NSButton(checkboxWithTitle: "Protection is turned off", target: nil, action: nil)
        super.init()

        let p = PrefsStore.load()
        let c = panel.contentView!

        func title(_ s: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, bold: Bool = false) {
            let t = NSTextField(labelWithString: s)
            t.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 11)
            t.textColor = bold ? .labelColor : NSColor(white: 1, alpha: 0.7)
            t.frame = NSRect(x: x, y: y, width: w, height: 16); c.addSubview(t)
        }
        func field(_ f: NSTextField, _ y: CGFloat, _ placeholder: String, _ value: String?) {
            f.frame = NSRect(x: 24, y: y, width: 432, height: 22)
            f.placeholderString = placeholder; f.stringValue = value ?? ""
            f.font = .systemFont(ofSize: 12); f.lineBreakMode = .byTruncatingMiddle
            c.addSubview(f)
        }

        title("Get alerted on your phone when protected apps are used.", 24, 430, 432, bold: true)
        enableCheck.frame = NSRect(x: 24, y: 402, width: 432, height: 20)
        enableCheck.state = p.notifyEnabled ? .on : .off
        c.addSubview(enableCheck)

        title("Telegram bot token", 24, 374, 300)
        field(tokenField, 350, "123456:ABC-DEF… (from @BotFather)", p.telegramBotToken)
        title("Telegram chat ID", 24, 322, 300)
        field(chatField, 298, "e.g. 987654321 (from @userinfobot)", p.telegramChatID)
        title("Webhook URL (optional)", 24, 270, 300)
        field(webhookField, 246, "https://… receives a JSON POST", p.webhookURL)

        title("Send an alert when:", 24, 216, 300)
        cbLocked.frame = NSRect(x: 24, y: 190, width: 220, height: 20); cbLocked.state = p.notifyOnLocked ? .on : .off
        cbUnlocked.frame = NSRect(x: 250, y: 190, width: 210, height: 20); cbUnlocked.state = p.notifyOnUnlocked ? .on : .off
        cbFailed.frame = NSRect(x: 24, y: 166, width: 220, height: 20); cbFailed.state = p.notifyOnFailed ? .on : .off
        cbProtOff.frame = NSRect(x: 250, y: 166, width: 210, height: 20); cbProtOff.state = p.notifyOnProtectionOff ? .on : .off
        [cbLocked, cbUnlocked, cbFailed, cbProtOff].forEach { c.addSubview($0) }

        let test = NSButton(title: "Send Test", target: self, action: #selector(testTapped))
        test.bezelStyle = .rounded; test.frame = NSRect(x: 24, y: 108, width: 120, height: 30)
        c.addSubview(test)
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = NSColor(white: 1, alpha: 0.6)
        statusLabel.maximumNumberOfLines = 3; statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.frame = NSRect(x: 156, y: 98, width: 300, height: 44); c.addSubview(statusLabel)

        title("The bot token is stored on this Mac only. Alerts are sent directly to "
            + "Telegram / your webhook — nowhere else.", 24, 56, 432)

        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        save.frame = NSRect(x: 372, y: 16, width: 84, height: 32); c.addSubview(save)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 280, y: 16, width: 84, height: 32); c.addSubview(cancel)
    }

    func runModal() { panel.center(); NSApp.runModal(for: panel); panel.orderOut(nil) }

    private func nilIfEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
    }

    // Build a Prefs carrying just the notification fields for a test send.
    private func draftPrefs() -> Prefs {
        var p = PrefsStore.load()
        p.notifyEnabled = true
        p.telegramBotToken = nilIfEmpty(tokenField.stringValue)
        p.telegramChatID = nilIfEmpty(chatField.stringValue)
        p.webhookURL = nilIfEmpty(webhookField.stringValue)
        return p
    }

    @objc private func testTapped() {
        statusLabel.textColor = NSColor(white: 1, alpha: 0.6)
        statusLabel.stringValue = "Sending test…"
        RemoteNotify.test(draftPrefs()) { [weak self] ok, msg in
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusLabel.textColor = ok ? .systemGreen : .systemRed
                self.statusLabel.stringValue = msg
            }
        }
    }

    @objc private func saveTapped() {
        PrefsStore.update { p in
            p.notifyEnabled = enableCheck.state == .on
            p.telegramBotToken = nilIfEmpty(tokenField.stringValue)
            p.telegramChatID = nilIfEmpty(chatField.stringValue)
            p.webhookURL = nilIfEmpty(webhookField.stringValue)
            p.notifyOnLocked = cbLocked.state == .on
            p.notifyOnUnlocked = cbUnlocked.state == .on
            p.notifyOnFailed = cbFailed.state == .on
            p.notifyOnProtectionOff = cbProtOff.state == .on
        }
        NSApp.stopModal()
    }

    @objc private func cancelTapped() { NSApp.stopModal() }
}

// MARK: - Schedule editor (app-modal panel)

final class ScheduleEditor: NSObject {
    private let panel: NSWindow
    private let enabledCheck: NSButton
    private var dayChecks: [NSButton] = []
    private let startPicker: NSDatePicker
    private let endPicker: NSDatePicker
    private var result: Schedule?

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]  // weekday 1…7

    init(current: Schedule) {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 252),
                         styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Locking Schedule"
        panel.appearance = NSAppearance(named: .darkAqua)
        enabledCheck = NSButton(checkboxWithTitle: "Only enforce locking during the hours below",
                                target: nil, action: nil)
        startPicker = NSDatePicker(); endPicker = NSDatePicker()
        super.init()

        let c = panel.contentView!

        let title = NSTextField(labelWithString: "When should protected apps be locked?")
        title.font = .boldSystemFont(ofSize: 14)
        title.frame = NSRect(x: 24, y: 214, width: 432, height: 20); c.addSubview(title)

        enabledCheck.frame = NSRect(x: 24, y: 184, width: 432, height: 20)
        enabledCheck.target = self; enabledCheck.action = #selector(toggleEnabled)
        enabledCheck.state = current.enabled ? .on : .off
        c.addSubview(enabledCheck)

        let daysLabel = NSTextField(labelWithString: "Active days:")
        daysLabel.font = .systemFont(ofSize: 12); daysLabel.textColor = NSColor(white: 1, alpha: 0.7)
        daysLabel.frame = NSRect(x: 24, y: 152, width: 120, height: 18); c.addSubview(daysLabel)

        let win0 = current.windows.first
        let activeDays = Set(win0?.days ?? [2, 3, 4, 5, 6])   // default Mon–Fri
        for i in 0..<7 {
            let b = NSButton(checkboxWithTitle: Self.dayNames[i], target: nil, action: nil)
            b.frame = NSRect(x: 24 + CGFloat(i) * 62, y: 126, width: 60, height: 20)
            b.state = activeDays.contains(i + 1) ? .on : .off
            c.addSubview(b); dayChecks.append(b)
        }

        func configurePicker(_ p: NSDatePicker, minutes: Int, x: CGFloat) {
            p.datePickerStyle = .textFieldAndStepper
            p.datePickerElements = .hourMinute
            p.frame = NSRect(x: x, y: 84, width: 84, height: 24)
            var comps = DateComponents(); comps.year = 2001; comps.month = 1; comps.day = 1
            comps.hour = minutes / 60; comps.minute = minutes % 60
            p.dateValue = Calendar.current.date(from: comps) ?? Date()
        }
        let fromLabel = NSTextField(labelWithString: "From")
        fromLabel.font = .systemFont(ofSize: 12); fromLabel.textColor = NSColor(white: 1, alpha: 0.7)
        fromLabel.frame = NSRect(x: 24, y: 88, width: 40, height: 18); c.addSubview(fromLabel)
        configurePicker(startPicker, minutes: win0?.start ?? 540, x: 68); c.addSubview(startPicker)   // 09:00

        let toLabel = NSTextField(labelWithString: "to")
        toLabel.font = .systemFont(ofSize: 12); toLabel.textColor = NSColor(white: 1, alpha: 0.7)
        toLabel.frame = NSRect(x: 168, y: 88, width: 24, height: 18); c.addSubview(toLabel)
        configurePicker(endPicker, minutes: win0?.end ?? 1020, x: 196)  // 17:00
        c.addSubview(endPicker)

        let hint = NSTextField(wrappingLabelWithString:
            "Outside these hours, protected apps open normally. If “to” is earlier than "
          + "“from”, the window wraps past midnight (e.g. 20:00–06:00). When the schedule "
          + "is off, apps stay locked around the clock.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = NSColor(white: 1, alpha: 0.5)
        hint.frame = NSRect(x: 24, y: 42, width: 432, height: 36); c.addSubview(hint)

        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        save.frame = NSRect(x: 372, y: 12, width: 84, height: 32); c.addSubview(save)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 280, y: 12, width: 84, height: 32); c.addSubview(cancel)

        updateEnabledState()
    }

    func runModal() -> Schedule? {
        panel.center()
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return result
    }

    @objc private func toggleEnabled() { updateEnabledState() }

    private func updateEnabledState() {
        let on = enabledCheck.state == .on
        dayChecks.forEach { $0.isEnabled = on }
        startPicker.isEnabled = on; endPicker.isEnabled = on
    }

    private func minutes(from picker: NSDatePicker) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    @objc private func saveTapped() {
        if enabledCheck.state != .on {
            result = .always
        } else {
            let days = (0..<7).compactMap { dayChecks[$0].state == .on ? $0 + 1 : nil }
            let window = ScheduleWindow(days: days.isEmpty ? Array(1...7) : days,
                                        start: minutes(from: startPicker), end: minutes(from: endPicker))
            result = Schedule(enabled: true, windows: [window])
        }
        NSApp.stopModal()
    }

    @objc private func cancelTapped() { result = nil; NSApp.stopModal() }
}

// MARK: - Activity-log viewer (app-modal panel)

final class LogViewer: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSWindow
    private let table = NSTableView()
    private var rows: [Attempt] = AttemptLog.recent()

    private static let display: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d  HH:mm:ss"; return f
    }()
    private let iso = ISO8601DateFormatter()

    override init() {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                         styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Activity Log"
        panel.appearance = NSAppearance(named: .darkAqua)
        super.init()

        let c = panel.contentView!

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 60, width: 608, height: 364))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        func addCol(_ id: String, _ title: String, _ w: CGFloat) {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title; col.width = w; table.addTableColumn(col)
        }
        addCol("time", "When", 150)
        addCol("app", "App", 190)
        addCol("event", "Event", 130)
        addCol("method", "Via", 110)
        table.dataSource = self; table.delegate = self
        scroll.documentView = table
        c.addSubview(scroll)

        if rows.isEmpty {
            let empty = NSTextField(labelWithString: "No unlock attempts recorded yet.")
            empty.textColor = NSColor(white: 1, alpha: 0.5); empty.alignment = .center
            empty.frame = NSRect(x: 16, y: 230, width: 608, height: 20); c.addSubview(empty)
        }

        let clear = NSButton(title: "Clear Log", target: self, action: #selector(clearTapped))
        clear.bezelStyle = .rounded; clear.frame = NSRect(x: 16, y: 16, width: 110, height: 32)
        c.addSubview(clear)
        let close = NSButton(title: "Close", target: self, action: #selector(closeTapped))
        close.bezelStyle = .rounded; close.keyEquivalent = "\r"
        close.frame = NSRect(x: 534, y: 16, width: 90, height: 32); c.addSubview(close)
    }

    func runModal() {
        panel.center()
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
    }

    @objc private func clearTapped() { AttemptLog.clear(); rows = []; table.reloadData() }
    @objc private func closeTapped() { NSApp.stopModal() }

    private func pretty(_ event: String) -> String {
        event.replacingOccurrences(of: "_", with: " ").capitalized
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let id = col?.identifier.rawValue else { return nil }
        let a = rows[row]
        let text: String
        switch id {
        case "time":   text = iso.date(from: a.at).map { Self.display.string(from: $0) } ?? a.at
        case "app":    text = a.app
        case "event":  text = pretty(a.event)
        default:       text = a.method ?? "—"
        }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        if id == "event" {
            switch a.event {
            case "unlocked":       label.textColor = .systemGreen
            case "failed":         label.textColor = .systemRed
            case "protection_off": label.textColor = .systemOrange
            default:               label.textColor = .labelColor
            }
        }
        label.frame = NSRect(x: 4, y: 4, width: (col?.width ?? 100) - 8, height: 18)
        return label
    }
}

// MARK: - Entry point

@main
enum ManagerMain {
    static let delegate = ManagerDelegate()
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if !args.isEmpty { exit(runCLI(args)) }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
