// Plonker Blocker — Copyright 2026 RoundDarkMatter
// SPDX-License-Identifier: Apache-2.0

import Foundation

// Standalone test runner for Plonker Blocker's pure logic. Compiled together with
// src/Shared.swift (see tools/run_tests.sh). No XCTest dependency — a tiny
// assert harness that exits non-zero on any failure.

var passed = 0, failed = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { passed += 1 }
    else { failed += 1; print("  ✗ FAIL: \(msg)") }
}
func section(_ name: String) { print("• \(name)") }

// Fixed UTC calendar so schedule tests don't depend on the machine's timezone/DST.
let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

func testSchedule() {
    section("Schedule.locks")
    // Reference dates (2024): Jan 1 = Mon(2), Jan 3 = Wed(4), Jan 6 = Sat(7), Jan 7 = Sun(1).
    check(Schedule.always.locks(at: at(2024, 1, 7, 3, 0), calendar: utc), "always → locked on Sunday 03:00")
    check(Schedule.always.locks(at: at(2024, 1, 3, 14, 0), calendar: utc), "always → locked midweek")

    // Weekdays 09:00–17:00 (Mon–Fri).
    let workHours = Schedule(enabled: true,
        windows: [ScheduleWindow(days: [2, 3, 4, 5, 6], start: 9 * 60, end: 17 * 60)])
    check(workHours.locks(at: at(2024, 1, 3, 10, 0), calendar: utc), "Wed 10:00 inside window → locked")
    check(!workHours.locks(at: at(2024, 1, 3, 8, 59), calendar: utc), "Wed 08:59 before window → unlocked")
    check(!workHours.locks(at: at(2024, 1, 3, 17, 0), calendar: utc), "Wed 17:00 at window end (exclusive) → unlocked")
    check(!workHours.locks(at: at(2024, 1, 7, 10, 0), calendar: utc), "Sun 10:00 not an active day → unlocked")

    // Overnight window 20:00–06:00 that wraps past midnight, every day.
    let overnight = Schedule(enabled: true,
        windows: [ScheduleWindow(days: Array(1...7), start: 20 * 60, end: 6 * 60)])
    check(overnight.locks(at: at(2024, 1, 3, 23, 0), calendar: utc), "23:00 in overnight window → locked")
    check(overnight.locks(at: at(2024, 1, 3, 5, 0), calendar: utc), "05:00 in overnight window → locked")
    check(!overnight.locks(at: at(2024, 1, 3, 12, 0), calendar: utc), "12:00 outside overnight window → unlocked")
    check(overnight.locks(at: at(2024, 1, 3, 20, 0), calendar: utc), "20:00 at window start (inclusive) → locked")

    // Wrapping window on SELECTED days only — the after-midnight tail is attributed
    // to the day the window started (regression test for the weekday mis-attribution).
    // 2024: Jan 5 = Fri(6), Jan 6 = Sat(7), Jan 8 = Mon(2), Jan 9 = Tue(3).
    let friNight = Schedule(enabled: true,
        windows: [ScheduleWindow(days: [2, 3, 4, 5, 6], start: 20 * 60, end: 6 * 60)])  // Mon–Fri 20:00–06:00
    check(friNight.locks(at: at(2024, 1, 5, 22, 0), calendar: utc), "Fri 22:00 → locked (evening part)")
    check(friNight.locks(at: at(2024, 1, 6, 3, 0), calendar: utc), "Sat 03:00 → locked (Fri night wraps in)")
    check(!friNight.locks(at: at(2024, 1, 6, 7, 0), calendar: utc), "Sat 07:00 → unlocked (past window end)")
    check(!friNight.locks(at: at(2024, 1, 8, 3, 0), calendar: utc), "Mon 03:00 → unlocked (Sun night not selected)")
    check(friNight.locks(at: at(2024, 1, 9, 3, 0), calendar: utc), "Tue 03:00 → locked (Mon night wraps in)")

    // Enabled but no windows → never locks.
    check(!Schedule(enabled: true, windows: []).locks(at: at(2024, 1, 3, 12, 0), calendar: utc),
          "enabled with no windows → never locked")
}

func testPasscode() {
    section("Passcode")
    check(Passcode.makeRecord("abc") == nil, "3-char passcode rejected (min \(Passcode.minLength))")
    guard let rec = Passcode.makeRecord("1234") else { check(false, "makeRecord(\"1234\") returned nil"); return }
    check(Passcode.verify("1234", against: rec), "correct passcode verifies")
    check(!Passcode.verify("12345", against: rec), "wrong passcode rejected")
    check(!Passcode.verify("1234", against: nil), "no stored record → always rejects")
    check(rec.iterations == 150_000, "record uses 150k iterations")

    let rec2 = Passcode.makeRecord("1234")!
    check(rec.salt != rec2.salt, "each record has a distinct random salt")
    check(rec.hash != rec2.hash, "same passcode → different hash (salted)")
    check(Passcode.verify("1234", against: rec2), "second record also verifies")
}

func testCodableBackCompat() {
    section("Codable back-compat")
    let dec = JSONDecoder()

    // Empty prefs → animation ON, sound OFF by default.
    let p = try! dec.decode(Prefs.self, from: Data("{}".utf8))
    check(p.ahahahEnabled && !p.soundEnabled, "empty prefs default ahahah ON, sound OFF")
    check(p.backgroundTheme == nil, "empty prefs default theme nil")

    // Partial prefs → only the named key changes.
    let p2 = try! dec.decode(Prefs.self, from: Data(#"{"soundEnabled":true}"#.utf8))
    check(p2.ahahahEnabled && p2.soundEnabled, "partial prefs keep ahahah ON, sound explicitly ON")

    // Legacy policy without a schedule → schedule = always.
    let legacy = #"{"apps":[],"relockMinutes":15}"#
    let pol = try! dec.decode(Policy.self, from: Data(legacy.utf8))
    check(pol.relockMinutes == 15, "legacy relockMinutes decoded")
    check(!pol.schedule.enabled, "missing schedule → .always (enabled=false)")
    check(pol.passcode == nil, "missing passcode decodes to nil")

    // Empty schedule object.
    let s = try! dec.decode(Schedule.self, from: Data("{}".utf8))
    check(!s.enabled && s.windows.isEmpty, "empty schedule object → disabled, no windows")

    // Round-trip a full policy.
    let full = Policy(apps: [ProtectedApp(name: "Foo", bundleID: "com.x.foo", path: "/A/Foo.app", addedAt: "t")],
                      passcode: Passcode.makeRecord("hunter2"),
                      relockMinutes: 30,
                      schedule: Schedule(enabled: true,
                          windows: [ScheduleWindow(days: [2, 3], start: 60, end: 120)]))
    let data = try! JSONEncoder().encode(full)
    let back = try! dec.decode(Policy.self, from: data)
    check(back.apps.count == 1 && back.apps[0].bundleID == "com.x.foo", "policy apps round-trip")
    check(back.relockMinutes == 30, "policy relockMinutes round-trip")
    check(back.schedule.windows.first?.days == [2, 3], "policy schedule window round-trip")
    check(Passcode.verify("hunter2", against: back.passcode), "policy passcode survives round-trip")
}

func testAppPolicy() {
    section("AppPolicy.isProtectable")
    check(!AppPolicy.isProtectable("com.apple.finder"), "Finder is never protectable")
    check(!AppPolicy.isProtectable("com.plonkerblocker.app"), "Plonker Blocker won't lock itself")
    check(!AppPolicy.isProtectable("com.plonkerblocker.guard"), "the guard won't lock itself")
    check(AppPolicy.isProtectable("com.google.Chrome"), "a normal third-party app is protectable")
}

func testAttemptCodable() {
    section("Attempt JSONL round-trip")
    let a = Attempt(at: "2024-01-01T00:00:00Z", app: "Foo", bundleID: "com.x.foo", event: "failed", method: "passcode")
    let line = try! JSONEncoder().encode(a)
    let back = try! JSONDecoder().decode(Attempt.self, from: line)
    check(back.event == "failed" && back.method == "passcode", "attempt event+method survive")
    check(back.app == "Foo" && back.bundleID == "com.x.foo", "attempt app+bundle survive")
}

func testNotifyPrefs() {
    section("Notification prefs + gating")
    let d = Prefs.default
    check(!d.notifyEnabled, "external alerts off by default")
    check(!d.notifyOnLocked, "locked alert off by default (noisy)")
    check(d.notifyOnUnlocked && d.notifyOnFailed && d.notifyOnProtectionOff,
          "unlocked/failed/protection-off alerts on by default")
    check(d.animationPath == nil && d.soundPath == nil, "no custom media by default")
    check(!d.passcodeNudgeSkipped, "passcode nudge not skipped by default")

    check(RemoteEvent.protectionOff.rawValue == "protection_off", "protectionOff maps to the log event name")

    var p = Prefs.default
    p.notifyOnLocked = true; p.notifyOnUnlocked = false
    check(RemoteEvent.locked.enabled(in: p), "locked event honors its flag when on")
    check(!RemoteEvent.unlocked.enabled(in: p), "unlocked event honors its flag when off")

    // Prefs (flags/media, NOT credentials) survive a JSON round-trip.
    var full = Prefs.default
    full.notifyEnabled = true
    full.animationPath = "/a.gif"; full.soundPath = "/s.mp3"
    let back = try! JSONDecoder().decode(Prefs.self, from: try! JSONEncoder().encode(full))
    check(back.notifyEnabled, "notify flag round-trips")
    check(back.animationPath == "/a.gif" && back.soundPath == "/s.mp3", "custom media paths round-trip")

    // A pre-notifications prefs.json (only the old keys) still decodes with new defaults.
    let old = #"{"backgroundTheme":"graphite","soundEnabled":true,"ahahahEnabled":true}"#
    let legacy = try! JSONDecoder().decode(Prefs.self, from: Data(old.utf8))
    check(legacy.backgroundTheme == "graphite" && legacy.soundEnabled && !legacy.notifyEnabled,
          "legacy prefs decode; new notify fields default off")

    section("NotifySecrets")
    check(NotifySecrets().isEmpty, "fresh secrets are empty")
    var sec = NotifySecrets(); sec.telegramBotToken = "123:ABC"; sec.telegramChatID = "42"
    check(!sec.isEmpty, "secrets with a token are non-empty")
    let secBack = try! JSONDecoder().decode(NotifySecrets.self, from: try! JSONEncoder().encode(sec))
    check(secBack.telegramBotToken == "123:ABC" && secBack.telegramChatID == "42", "secrets round-trip")
    // A secrets file that predates the webhook field still decodes.
    let partial = try! JSONDecoder().decode(NotifySecrets.self, from: Data(#"{"telegramBotToken":"t"}"#.utf8))
    check(partial.telegramBotToken == "t" && partial.webhookURL == nil, "partial secrets decode leniently")
}

@main
enum TestMain {
    static func main() {
        print("Plonker Blocker — logic tests\n")
        testSchedule()
        testPasscode()
        testCodableBackCompat()
        testAppPolicy()
        testAttemptCodable()
        testNotifyPrefs()
        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
