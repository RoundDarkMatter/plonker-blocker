import AppKit
import CryptoKit
import Security
import UserNotifications

// Shared model + stores, compiled into BOTH the manager and the guard.

// MARK: - Model

struct ProtectedApp: Codable, Equatable {
    var name: String
    var bundleID: String
    var path: String        // last-known location, for display / re-pick
    var addedAt: String
}

struct PasscodeRecord: Codable, Equatable { var salt: String; var hash: String; var iterations: Int }

// A weekly time window during which locking is enforced.
struct ScheduleWindow: Codable, Equatable {
    var days: [Int]      // Calendar weekday 1(Sun)…7(Sat)
    var start: Int       // minutes since midnight
    var end: Int         // minutes since midnight (may wrap past midnight)
}

struct Schedule: Codable, Equatable {
    var enabled: Bool                 // false = always locked (24/7)
    var windows: [ScheduleWindow]     // when locking is ENFORCED
    static let always = Schedule(enabled: false, windows: [])

    /// Is locking in effect at `date`?
    func locks(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return true }
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let wd = c.weekday, let h = c.hour, let m = c.minute else { return true }
        let now = h * 60 + m
        for w in windows where w.days.contains(wd) {
            if w.start <= w.end {
                if now >= w.start && now < w.end { return true }
            } else if now >= w.start || now < w.end {   // wraps midnight
                return true
            }
        }
        return false
    }

    init(enabled: Bool, windows: [ScheduleWindow]) { self.enabled = enabled; self.windows = windows }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        windows = try c.decodeIfPresent([ScheduleWindow].self, forKey: .windows) ?? []
    }
}

// Everything security-relevant. Root-owned (see PolicyStore).
struct Policy: Codable {
    var apps: [ProtectedApp]
    var passcode: PasscodeRecord?
    var relockMinutes: Int
    var schedule: Schedule
    static let empty = Policy(apps: [], passcode: nil, relockMinutes: 5, schedule: .always)

    init(apps: [ProtectedApp], passcode: PasscodeRecord?, relockMinutes: Int, schedule: Schedule) {
        self.apps = apps; self.passcode = passcode; self.relockMinutes = relockMinutes; self.schedule = schedule
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        apps = try c.decodeIfPresent([ProtectedApp].self, forKey: .apps) ?? []
        passcode = try c.decodeIfPresent(PasscodeRecord.self, forKey: .passcode)
        relockMinutes = try c.decodeIfPresent(Int.self, forKey: .relockMinutes) ?? 5
        schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule) ?? .always
    }
}

// Cosmetic + convenience preferences (NOT security). User-owned.
// All properties have defaults, so the compiler-synthesized Codable fills any
// missing key with its default — old prefs.json files decode forward-compatibly.
struct Prefs: Codable {
    var backgroundTheme: String? = nil
    var backgroundImagePath: String? = nil
    var ahahahEnabled: Bool = true
    var soundEnabled: Bool = false
    var animationPath: String? = nil     // custom lock-screen animation (gif/image); nil = built-in
    var soundPath: String? = nil         // custom wrong-attempt sound; nil = system "Funk"

    // External alerts (Telegram / generic webhook). Off by default.
    var notifyEnabled: Bool = false
    var telegramBotToken: String? = nil
    var telegramChatID: String? = nil
    var webhookURL: String? = nil
    var notifyOnLocked: Bool = false
    var notifyOnUnlocked: Bool = true
    var notifyOnFailed: Bool = true
    var notifyOnProtectionOff: Bool = true

    static let `default` = Prefs()
}

// Lenient decoder in an extension (keeps the synthesized memberwise init): any key
// missing from an older prefs.json falls back to the property's default.
extension Prefs {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        func s(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        func b(_ k: CodingKeys, _ dflt: Bool) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? dflt }
        backgroundTheme = s(.backgroundTheme)
        backgroundImagePath = s(.backgroundImagePath)
        ahahahEnabled = b(.ahahahEnabled, true)
        soundEnabled = b(.soundEnabled, false)
        animationPath = s(.animationPath)
        soundPath = s(.soundPath)
        notifyEnabled = b(.notifyEnabled, false)
        telegramBotToken = s(.telegramBotToken)
        telegramChatID = s(.telegramChatID)
        webhookURL = s(.webhookURL)
        notifyOnLocked = b(.notifyOnLocked, false)
        notifyOnUnlocked = b(.notifyOnUnlocked, true)
        notifyOnFailed = b(.notifyOnFailed, true)
        notifyOnProtectionOff = b(.notifyOnProtectionOff, true)
    }
}

// One line in the attempt log.
struct Attempt: Codable {
    var at: String        // ISO-8601
    var app: String
    var bundleID: String
    var event: String     // locked | unlocked | failed | cancelled | protection_off
    var method: String?   // passcode | touchid | admin
}

enum AppError: LocalizedError {
    case noBundleID(String)
    case alreadyProtected(String)
    case notFound(String)
    case notProtectable(String)
    case installFailed(String)
    case policyWriteFailed
    var errorDescription: String? {
        switch self {
        case .noBundleID(let n): return "“\(n)” has no bundle identifier and can't be protected."
        case .alreadyProtected(let n): return "“\(n)” is already protected."
        case .notFound(let k): return "“\(k)” is not in the protected list."
        case .notProtectable(let n):
            return "“\(n)” can't be locked — it's a system app (locking it could trap the screen)."
        case .installFailed(let m): return "Couldn't set up the background guard: \(m)"
        case .policyWriteFailed:
            return "Couldn't save — administrator approval is required to change protection."
        }
    }
}

// MARK: - Paths

enum Paths {
    /// User-owned data: prefs, attempt log, the installed guard, the ahahah override.
    static let userSupport: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PlonkerBlocker", isDirectory: true)
    /// Root-owned security policy (apps, passcode, re-lock, schedule).
    static let systemDir = URL(fileURLWithPath: "/Library/Application Support/PlonkerBlocker", isDirectory: true)

    static var policy: URL { systemDir.appendingPathComponent("policy.json") }
    static var prefs: URL { userSupport.appendingPathComponent("prefs.json") }
    static var attempts: URL { userSupport.appendingPathComponent("attempts.jsonl") }

    /// Pre-rename location, for one-time migration.
    static let legacy: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AdminGate", isDirectory: true)

    static func ensureUserDir() throws {
        try FileManager.default.createDirectory(at: userSupport, withIntermediateDirectories: true)
    }
}

// MARK: - Shell / privilege helpers

@discardableResult
func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do {
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()  // read before wait (no deadlock)
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    } catch { return (-1, "\(error)") }
}

func userIsAdmin() -> Bool {
    if getuid() == 0 { return true }
    var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
    let n = getgroups(Int32(groups.count), &groups)
    if n >= 0 { for i in 0..<Int(n) where groups[i] == 80 { return true } }
    return false
}

func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Alias for `run` usable inside types whose own `run` member would shadow it
/// (e.g. `Migration.run`).
@discardableResult
func sh(_ path: String, _ args: [String]) -> (code: Int32, out: String) { run(path, args) }

/// Run a shell script as root. If already root, runs directly; otherwise via the
/// native admin prompt. Returns success.
func runPrivileged(_ script: String) -> Bool {
    if getuid() == 0 { return run("/bin/sh", ["-c", script]).code == 0 }
    let escaped = script
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"]).code == 0
}

// MARK: - PolicyStore (root-owned; writes require admin)

enum PolicyStore {
    static func load() -> Policy { (try? loadStrict()) ?? .empty }

    /// Throws on a present-but-unreadable file so the guard can fail closed.
    static func loadStrict() throws -> Policy {
        guard FileManager.default.fileExists(atPath: Paths.policy.path) else { return .empty }
        return try JSONDecoder().decode(Policy.self, from: Data(contentsOf: Paths.policy))
    }

    /// Modification time (used by the guard to cache reads).
    static func modTime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Paths.policy.path)[.modificationDate]) as? Date
    }

    private static func encoded(_ p: Policy) -> Data? {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(p)
    }

    /// Persist policy. Writes directly when the process can already write the
    /// (admin-group) directory; otherwise elevates once to create it root:admin,
    /// setgid, group-writable. Standard users without admin credentials fail.
    @discardableResult
    static func write(_ p: Policy) -> Bool {
        guard let data = encoded(p) else { return false }
        let fm = FileManager.default

        if fm.isWritableFile(atPath: Paths.systemDir.path) || getuid() == 0 {
            do {
                if !fm.fileExists(atPath: Paths.systemDir.path) {
                    try fm.createDirectory(at: Paths.systemDir, withIntermediateDirectories: true)
                }
                try data.write(to: Paths.policy, options: .atomic)
                run("/bin/chmod", ["664", Paths.policy.path])
                run("/usr/bin/chgrp", ["admin", Paths.policy.path])
                return true
            } catch { /* fall through to privileged path */ }
        }

        let tmp = NSTemporaryDirectory() + "pb-policy-\(getpid()).json"
        guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return false }
        defer { try? fm.removeItem(atPath: tmp) }
        let d = shq(Paths.systemDir.path), f = shq(Paths.policy.path), t = shq(tmp)
        // 2775 = setgid so files inherit the admin group; admins then write with no prompt.
        let script = "/bin/mkdir -p \(d) && /usr/sbin/chown root:admin \(d) && /bin/chmod 2775 \(d) "
                   + "&& /bin/cp \(t) \(f) && /usr/bin/chgrp admin \(f) && /bin/chmod 664 \(f)"
        return runPrivileged(script)
    }

    // Convenience mutators (manager side).
    static func addApp(at url: URL) throws {
        guard let bid = AppInfo.bundleID(of: url) else { throw AppError.noBundleID(url.lastPathComponent) }
        guard AppPolicy.isProtectable(bid) else { throw AppError.notProtectable(AppInfo.displayName(of: url)) }
        var p = load()
        guard !p.apps.contains(where: { $0.bundleID == bid }) else {
            throw AppError.alreadyProtected(AppInfo.displayName(of: url))
        }
        p.apps.append(ProtectedApp(name: AppInfo.displayName(of: url), bundleID: bid,
                                   path: url.path, addedAt: ISO8601DateFormatter().string(from: Date())))
        guard write(p) else { throw AppError.policyWriteFailed }
    }

    @discardableResult
    static func removeApp(matching key: String) throws -> Bool {
        var p = load()
        let before = p.apps.count
        p.apps.removeAll { $0.bundleID == key || $0.path == key }
        guard p.apps.count != before else { return false }
        guard write(p) else { throw AppError.policyWriteFailed }
        return true
    }

    static func reorder(_ apps: [ProtectedApp]) {
        var p = load(); p.apps = apps; write(p)
    }
    static func setRelock(_ minutes: Int) throws { var p = load(); p.relockMinutes = minutes; guard write(p) else { throw AppError.policyWriteFailed } }
    static func setSchedule(_ s: Schedule) throws { var p = load(); p.schedule = s; guard write(p) else { throw AppError.policyWriteFailed } }
    static func setPasscode(_ rec: PasscodeRecord?) throws { var p = load(); p.passcode = rec; guard write(p) else { throw AppError.policyWriteFailed } }
}

// MARK: - PrefsStore (user-owned; cosmetic)

enum PrefsStore {
    static func load() -> Prefs {
        guard let d = try? Data(contentsOf: Paths.prefs),
              let p = try? JSONDecoder().decode(Prefs.self, from: d) else { return .default }
        return p
    }
    static func save(_ p: Prefs) {
        try? Paths.ensureUserDir()
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted]
        if let d = try? e.encode(p) { try? d.write(to: Paths.prefs, options: .atomic) }
    }
    static func update(_ mutate: (inout Prefs) -> Void) { var p = load(); mutate(&p); save(p) }
}

// MARK: - Attempt log (user-owned, append-only JSONL)

enum AttemptLog {
    static func append(app: String, bundleID: String, event: String, method: String? = nil) {
        try? Paths.ensureUserDir()
        let a = Attempt(at: ISO8601DateFormatter().string(from: Date()),
                        app: app, bundleID: bundleID, event: event, method: method)
        guard let line = try? JSONEncoder().encode(a) else { return }
        let data = line + Data("\n".utf8)
        if let h = try? FileHandle(forWritingTo: Paths.attempts) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: Paths.attempts, options: .atomic)
        }
    }
    static func recent(_ limit: Int = 200) -> [Attempt] {
        guard let text = try? String(contentsOf: Paths.attempts, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").suffix(limit)
        let dec = JSONDecoder()
        return lines.compactMap { try? dec.decode(Attempt.self, from: Data($0.utf8)) }.reversed()
    }
    static func clear() { try? FileManager.default.removeItem(at: Paths.attempts) }
}

// MARK: - Passcode (hash helpers; storage lives in Policy)

enum Passcode {
    static let minLength = 4

    private static func derive(_ value: String, salt: Data, iterations: Int) -> Data {
        var acc = Data(SHA256.hash(data: salt + Data(value.utf8)))
        for _ in 1..<max(1, iterations) { acc = Data(SHA256.hash(data: salt + acc)) }
        return acc
    }

    /// nil if too short or the RNG fails — never derive from a non-random salt.
    static func makeRecord(_ passcode: String) -> PasscodeRecord? {
        guard passcode.count >= minLength else { return nil }
        var salt = Data(count: 16)
        let rc = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard rc == errSecSuccess else { return nil }
        let iterations = 150_000
        return PasscodeRecord(salt: salt.base64EncodedString(),
                              hash: derive(passcode, salt: salt, iterations: iterations).base64EncodedString(),
                              iterations: iterations)
    }

    static func verify(_ attempt: String, against rec: PasscodeRecord?) -> Bool {
        guard let rec, let salt = Data(base64Encoded: rec.salt),
              let expected = Data(base64Encoded: rec.hash) else { return false }
        let got = derive(attempt, salt: salt, iterations: rec.iterations)
        guard got.count == expected.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<got.count { diff |= got[i] ^ expected[i] }   // constant-time-ish
        return diff == 0
    }
}

// MARK: - Local notifications

enum Notifier {
    static func requestAuth() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - External alerts (Telegram / webhook) — user-configured, off by default

enum RemoteEvent: String {
    case locked, unlocked, failed, protectionOff = "protection_off"
    // Whether the user has opted this event in.
    func enabled(in p: Prefs) -> Bool {
        switch self {
        case .locked: return p.notifyOnLocked
        case .unlocked: return p.notifyOnUnlocked
        case .failed: return p.notifyOnFailed
        case .protectionOff: return p.notifyOnProtectionOff
        }
    }
}

enum RemoteNotify {
    private static func clean(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    private static func telegramRequest(_ text: String, _ p: Prefs) -> URLRequest? {
        guard let token = clean(p.telegramBotToken), let chat = clean(p.telegramChatID),
              let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["chat_id": chat, "text": text])
        return req
    }

    private static func webhookRequest(_ payload: [String: Any], _ p: Prefs) -> URLRequest? {
        guard let s = clean(p.webhookURL), let url = URL(string: s),
              (url.scheme == "http" || url.scheme == "https") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return req
    }

    /// Fire-and-forget. Cheap to call on the hot path: the enabled-check + prefs
    /// read and the POSTs all happen on a background queue, so a disabled
    /// configuration (the default) adds no work to the lock path at all.
    static func send(_ event: RemoteEvent, title: String, body: String, prefs: Prefs? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let p = prefs ?? PrefsStore.load()
            guard p.notifyEnabled, event.enabled(in: p) else { return }
            let text = "🔒 Plonker Blocker\n\(title)\n\(body)"
            if let r = telegramRequest(text, p) { URLSession.shared.dataTask(with: r).resume() }
            if let r = webhookRequest(["app": "Plonker Blocker", "event": event.rawValue,
                                       "title": title, "body": body,
                                       "at": ISO8601DateFormatter().string(from: Date())], p) {
                URLSession.shared.dataTask(with: r).resume()
            }
        }
    }

    /// Blocking variant for the "protection turned off" path, where the process
    /// terminates immediately after — a fire-and-forget POST would be killed before
    /// it left the machine. Waits (bounded) for every configured channel. Safe to
    /// call on the main thread: URLSession delivers completions on its own queue.
    static func sendBlocking(_ event: RemoteEvent, title: String, body: String, timeout: TimeInterval = 5) {
        let p = PrefsStore.load()
        guard p.notifyEnabled, event.enabled(in: p) else { return }
        let text = "🔒 Plonker Blocker\n\(title)\n\(body)"
        let group = DispatchGroup()
        for req in [telegramRequest(text, p),
                    webhookRequest(["app": "Plonker Blocker", "event": event.rawValue,
                                    "title": title, "body": body], p)].compactMap({ $0 }) {
            group.enter()
            URLSession.shared.dataTask(with: req) { _, _, _ in group.leave() }.resume()
        }
        _ = group.wait(timeout: .now() + timeout)
    }

    /// Used by the manager's "Send Test" button. Reports the first channel result.
    static func test(_ p: Prefs, completion: @escaping (Bool, String) -> Void) {
        let text = "🔒 Plonker Blocker\nTest alert\nIf you can read this, alerts are configured correctly."
        if let req = telegramRequest(text, p) {
            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err { return completion(false, "Telegram: \(err.localizedDescription)") }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 { completion(true, "Telegram test message sent.") }
                else {
                    let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    completion(false, "Telegram returned HTTP \(code). \(detail)")
                }
            }.resume()
            return
        }
        if let req = webhookRequest(["app": "Plonker Blocker", "event": "test"], p) {
            URLSession.shared.dataTask(with: req) { _, resp, err in
                if let err = err { return completion(false, "Webhook: \(err.localizedDescription)") }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                completion((200...299).contains(code), "Webhook returned HTTP \(code).")
            }.resume()
            return
        }
        completion(false, "No Telegram bot or webhook URL is configured.")
    }
}

// Apps that must never be locked (locking them would trap the screen).
enum AppPolicy {
    static let neverProtect: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.Spotlight", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.WindowManager", "com.plonkerblocker.app", "com.plonkerblocker.guard",
    ]
    static func isProtectable(_ bundleID: String) -> Bool { !neverProtect.contains(bundleID) }
}

// MARK: - App bundle helpers

enum AppInfo {
    static func info(of appURL: URL) -> NSDictionary? {
        NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
    }
    static func bundleID(of appURL: URL) -> String? {
        if let b = Bundle(url: appURL)?.bundleIdentifier { return b }
        return info(of: appURL)?["CFBundleIdentifier"] as? String
    }
    static func displayName(of appURL: URL) -> String {
        if let d = info(of: appURL) {
            if let n = d["CFBundleName"] as? String, !n.isEmpty { return n }
            if let n = d["CFBundleDisplayName"] as? String, !n.isEmpty { return n }
        }
        return appURL.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Background themes + view (shared by manager and lock screen)

struct BgTheme {
    let id: String, name: String
    let top: NSColor, bottom: NSColor, glow: NSColor?
}

let bgThemes: [BgTheme] = [
    BgTheme(id: "indigo",   name: "Indigo",
            top: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.26, alpha: 1),
            bottom: NSColor(srgbRed: 0.06, green: 0.06, blue: 0.10, alpha: 1),
            glow: NSColor(srgbRed: 0.42, green: 0.36, blue: 0.85, alpha: 0.22)),
    BgTheme(id: "midnight", name: "Midnight",
            top: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1),
            bottom: NSColor(srgbRed: 0.03, green: 0.03, blue: 0.05, alpha: 1), glow: nil),
    BgTheme(id: "graphite", name: "Graphite",
            top: NSColor(srgbRed: 0.22, green: 0.23, blue: 0.25, alpha: 1),
            bottom: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1),
            glow: NSColor(white: 1, alpha: 0.10)),
    BgTheme(id: "ocean",    name: "Ocean",
            top: NSColor(srgbRed: 0.09, green: 0.20, blue: 0.30, alpha: 1),
            bottom: NSColor(srgbRed: 0.03, green: 0.06, blue: 0.12, alpha: 1),
            glow: NSColor(srgbRed: 0.20, green: 0.60, blue: 0.75, alpha: 0.22)),
    BgTheme(id: "sunset",   name: "Sunset",
            top: NSColor(srgbRed: 0.28, green: 0.14, blue: 0.26, alpha: 1),
            bottom: NSColor(srgbRed: 0.08, green: 0.05, blue: 0.12, alpha: 1),
            glow: NSColor(srgbRed: 0.95, green: 0.45, blue: 0.35, alpha: 0.22)),
    BgTheme(id: "forest",   name: "Forest",
            top: NSColor(srgbRed: 0.10, green: 0.22, blue: 0.17, alpha: 1),
            bottom: NSColor(srgbRed: 0.03, green: 0.07, blue: 0.06, alpha: 1),
            glow: NSColor(srgbRed: 0.30, green: 0.70, blue: 0.45, alpha: 0.20)),
]

func bgTheme(id: String?) -> BgTheme { bgThemes.first { $0.id == (id ?? "indigo") } ?? bgThemes[0] }

/// Smooth gradient (or user image) background; the glow is a CGContext radial that
/// fades fully to transparent, so there is never a visible seam.
final class BackgroundView: NSView {
    var top = bgThemes[0].top
    var bottom = bgThemes[0].bottom
    var glow: NSColor? = bgThemes[0].glow
    var image: NSImage?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if let image {
            NSColor.black.setFill(); bounds.fill()
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let w = image.size.width * scale, h = image.size.height * scale
            image.draw(in: NSRect(x: (bounds.width - w)/2, y: (bounds.height - h)/2, width: w, height: h),
                       from: .zero, operation: .copy, fraction: 1)
            NSColor(white: 0, alpha: 0.42).setFill()
            bounds.fill(using: .sourceOver)
            return
        }
        let mid = top.blended(withFraction: 0.5, of: bottom) ?? top
        NSGradient(colors: [top, mid, bottom], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
            .draw(in: bounds, angle: -90)
        if let glow, let ctx = NSGraphicsContext.current?.cgContext {
            let center = CGPoint(x: bounds.width * 0.22, y: bounds.height * 0.84)
            let radius = max(bounds.width, bounds.height) * 0.75
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [glow.cgColor, glow.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: radius, options: [])
            }
        }
    }

    func apply(_ p: Prefs) {
        if let path = p.backgroundImagePath, let img = NSImage(contentsOfFile: path) {
            image = img
        } else {
            image = nil
            let t = bgTheme(id: p.backgroundTheme)
            top = t.top; bottom = t.bottom; glow = t.glow
        }
        needsDisplay = true
    }
}

// MARK: - Background guard agent (per-user LaunchAgent = "start at login")

enum GuardAgent {
    static let label = "com.plonkerblocker.guard"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var sourceGuardApp: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/PlonkerBlockerGuard.app")
    }
    static var installedGuardApp: URL { Paths.userSupport.appendingPathComponent("PlonkerBlockerGuard.app") }
    static var installedBinaryURL: URL {
        installedGuardApp.appendingPathComponent("Contents/MacOS/PlonkerBlockerGuard")
    }

    static func isEnabled() -> Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    static func isRunning() -> Bool { run("/bin/ps", ["-axo", "comm"]).out.contains("PlonkerBlockerGuard") }
    static func isHealthy() -> Bool {
        isEnabled() && FileManager.default.fileExists(atPath: installedBinaryURL.path)
    }

    static func enable() throws {
        let fm = FileManager.default
        try Paths.ensureUserDir()
        if fm.fileExists(atPath: sourceGuardApp.path) {
            try? fm.removeItem(at: installedGuardApp)
            try fm.copyItem(at: sourceGuardApp, to: installedGuardApp)
            run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", installedGuardApp.path])
        }
        guard fm.fileExists(atPath: installedBinaryURL.path) else {
            throw AppError.installFailed("guard binary missing")
        }
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [installedBinaryURL.path],
            "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        let uid = getuid()
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        let r = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
        if r.code != 0 { run("/bin/launchctl", ["load", plistURL.path]) }
    }

    static func disable() {
        let uid = getuid()
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        run("/bin/launchctl", ["unload", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: installedGuardApp)
        run("/usr/bin/pkill", ["-x", "PlonkerBlockerGuard"])
    }

    static func disableFromGuard() {
        let uid = getuid()
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: installedGuardApp)
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    }
}

// MARK: - One-time migration from the pre-rename AdminGate layout

enum Migration {
    /// Moves legacy user files to the new location and seeds the root policy from
    /// the old registry/settings/passcode. Returns true if it wrote a new policy
    /// (so the caller can redeploy the guard). Best-effort; safe to call every launch.
    @discardableResult
    static func run() -> Bool {
        let fm = FileManager.default
        // Prefs: theme carried over from old settings.json (if new prefs absent).
        if !fm.fileExists(atPath: Paths.prefs.path) {
            let oldSettings = Paths.legacy.appendingPathComponent("settings.json")
            if let d = try? Data(contentsOf: oldSettings),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                try? Paths.ensureUserDir()
                var prefs = Prefs.default
                prefs.backgroundTheme = obj["backgroundTheme"] as? String
                prefs.backgroundImagePath = obj["backgroundImagePath"] as? String
                PrefsStore.save(prefs)
            }
        }
        // ahahah override.
        let oldGif = Paths.legacy.appendingPathComponent("ahahah.gif")
        let newGif = Paths.userSupport.appendingPathComponent("ahahah.gif")
        if fm.fileExists(atPath: oldGif.path), !fm.fileExists(atPath: newGif.path) {
            try? Paths.ensureUserDir(); try? fm.copyItem(at: oldGif, to: newGif)
        }
        // Pre-rename guard agents: boot out any old-label LaunchAgent and kill the
        // old binary so two guards never run side-by-side after the rename.
        let hadLegacyAgent = removeLegacyAgents()

        // Policy: only if there isn't one yet and legacy data exists.
        var wrotePolicy = false
        if !fm.fileExists(atPath: Paths.policy.path) {
            var apps: [ProtectedApp] = []
            let oldReg = Paths.legacy.appendingPathComponent("registry.json")
            if let d = try? Data(contentsOf: oldReg),
               let decoded = try? JSONDecoder().decode([ProtectedApp].self, from: d) { apps = decoded }
            var relock = 5
            let oldSettings = Paths.legacy.appendingPathComponent("settings.json")
            if let d = try? Data(contentsOf: oldSettings),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let r = obj["relockMinutes"] as? Int { relock = r }
            var pass: PasscodeRecord?
            let oldPass = Paths.legacy.appendingPathComponent("passcode.json")
            if let d = try? Data(contentsOf: oldPass) { pass = try? JSONDecoder().decode(PasscodeRecord.self, from: d) }
            if !apps.isEmpty || pass != nil {
                wrotePolicy = PolicyStore.write(
                    Policy(apps: apps, passcode: pass, relockMinutes: relock, schedule: .always))
            }
        }

        // If a legacy agent WAS protecting the machine, hand over seamlessly so
        // there is no unprotected gap between the rename and the user re-enabling.
        if hadLegacyAgent { try? GuardAgent.enable() }
        return wrotePolicy
    }

    /// Removes any pre-rename guard LaunchAgent + binary. Returns true if one existed.
    private static func removeLegacyAgents() -> Bool {
        let fm = FileManager.default
        let uid = getuid()
        var found = false
        for oldLabel in ["com.plonkerblocker.muppetblocker.guard", "com.plonkerblocker.admingate.guard",
                         "com.plonkerblocker.plonkerblocker.guard"] {
            let plist = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/\(oldLabel).plist")
            guard fm.fileExists(atPath: plist.path) else { continue }
            found = true
            sh("/bin/launchctl", ["bootout", "gui/\(uid)/\(oldLabel)"])
            sh("/bin/launchctl", ["unload", plist.path])
            try? fm.removeItem(at: plist)
        }
        if found {
            for oldBinary in ["AdminGateGuard", "MuppetBlockerGuard"] {
                sh("/usr/bin/pkill", ["-x", oldBinary])
            }
            let userSupportRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? fm.removeItem(at: Paths.legacy.appendingPathComponent("AdminGateGuard.app"))
            try? fm.removeItem(at: userSupportRoot.appendingPathComponent("MuppetBlocker/MuppetBlockerGuard.app"))
        }
        return found
    }
}
