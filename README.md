# Plonker Blocker

Keeps unauthorised users out of the apps you choose by locking
the window behind a passcode, Touch ID, or an administrator password, without
modifying the apps themselves. Open a protected app and a full-screen lock covers
it until someone authenticates.

Runs on macOS 11 Big Sur through macOS 26 Tahoe (universal arm64 + x86_64).

## How it works

- **Plonker Blocker.app**, an admin-gated window to pick which apps to
  protect, turn protection on/off, set the re-lock timeout,
  define a locking schedule, and review the activity log. It never moves or
  modifies an app bundle.
- **Guard**, a background agent (a per-user LaunchAgent). It watches the frontmost
  app; when a protected one comes forward *and the schedule is active*, it drops an
  opaque lock over the screen and offers unlock by passcode, Touch ID, or the macOS
  admin dialog. Unlock just removes the overlay, the target app is never touched.
  No Accessibility / App Management / root needed for the guard itself.

Behavior:

- Open a protected app → lock screen (its icon + a lock badge) with a passcode
  field and Touch ID.
- Authenticate → unlocks for the **"Unlock for"** duration set in the app
  (default **5 min**; options 1 / 5 / 15 / 30 / 60 min or **Never**).
- Cancel → lock stays; retry or **⌘⇥** to switch away.
- **Wrong passcode → "Ah ah ah!"** and an immediate lockout, one try at a time,
  with escalating backoff (5s→60s), while Touch ID keeps working.

## Security model

- **Policy is root-owned.** Apps, passcode, re-lock timeout, and schedule live in
  `/Library/Application Support/PlonkerBlocker/policy.json`, created root:admin,
  setgid, group-writable. A standard user without admin credentials can't tamper
  with the protected list. The first write elevates once via the admin dialog.
- **Passcode** is stored only as a salted 150k-iteration SHA-256 hash (min 4 chars,
  RNG-checked); verification is constant-time-ish. It is separate from your macOS
  password.
- **Cosmetic prefs** (background theme/image, "Ah ah ah!" animation on/off, wrong-
  passcode sound on/off) live per-user in `~/Library/Application Support/PlonkerBlocker/prefs.json`.
- The guard **caches** the policy and re-reads it only when the file's mtime
  changes, and **fails closed** (keeps the last-known policy) on a transient read error.

## Schedule

By default protected apps are locked around the clock. In **Schedule…** you can
instead enforce locking only during chosen days + an hours window (e.g. Mon–Fri
09:00–17:00, or a wrapping 20:00–06:00 overnight window). Outside the window,
protected apps open normally.

## Activity log & notifications

Every lock, unlock (with method), failed attempt, and protection-off event is
appended to `~/Library/Application Support/PlonkerBlocker/attempts.jsonl`. View it
in **Activity…** (or `--log`). The guard also posts local (Notification Center)
alerts when an app is locked and after a failed attempt.

### External alerts (Telegram / webhook), off by default

In **Notifications…** you can forward events to your phone. Configure a **Telegram**
bot (token from @BotFather + your chat ID) and/or a generic **webhook URL** (receives
a JSON `POST`), then choose which events fire an alert: app locked, app unlocked, a
wrong password, or protection turned off. A **Send Test** button verifies the setup.
Everything is off until you enable it; messages go directly to Telegram / your
webhook, nowhere else. The credentials (bot token, chat id, webhook URL) are kept
out of `prefs.json` in an **owner-only** `secrets.json` (`chmod 600`), so they are
not world-readable and not co-mingled with config. (Encryption-at-rest via the
Keychain would need Developer-ID signing to share the item between the manager and
the background guard, so owner-only file permissions are the robust, prompt-free
choice for an ad-hoc-signed build.)

## Startup & priority

The guard is a per user LaunchAgent (`RunAtLoad`, `KeepAlive`, `ProcessType:
Interactive`) that runs at interactive QoS. At launch it warms the policy cache and
**pre-builds** the (hidden) lock windows, so the first lock appears with no build
latency and a protected app that is already frontmost is covered immediately.

## Menu-bar item, background & login

When protection is on, Plonker Blocker runs **persistently in the background**, shows
a 🔒 in the menu bar, and **starts at login** (LaunchAgent, relaunches if killed).
The menu-bar item lets you **Lock All Now**, open the manager, or **Turn Off
Protection** (admin required).

## The "Ah ah ah!" animation & sound

The built-in wagging-finger animation is drawn natively (crisp on any display; no
GIF compression artifacts). The animation is **on** by default; the wrong-passcode
sound is **off** by default. Toggle each under **Lock Screen** in the app menu.

Pick your own via **Lock Screen → Choose Animation… / Choose Sound…** (the running
guard swaps them on the next lock, no restart). Or drop files directly at:

```
~/Library/Application Support/PlonkerBlocker/ahahah.gif
~/Library/Application Support/PlonkerBlocker/ahahah.mp3   (or .m4a/.aiff/.wav)
```

Without a custom sound it falls back to the system "Ah ah ah!" sound effect. Custom media is
loaded from your machine only. It is never bundled into the app, the repo, or the
installers (keep any borrowed audio for personal use).

## Use it

1. Open `Plonker Blocker.app` (authenticate as admin).
2. **Protect App…** → pick an open app or **Browse…**. (System apps that would trap
   the screen, like Finder or Dock, are refused.) Filter the list with the search
   field; drag rows to reorder.
3. **Turn Protection On.**

## CLI

```bash
PlonkerBlocker --status | --list | --log
PlonkerBlocker --add "/Applications/Foo.app"
PlonkerBlocker --remove com.example.foo
PlonkerBlocker --enable | --disable
PlonkerBlocker --set-passcode        # prompts securely
```

(The binary is `Plonker Blocker.app/Contents/MacOS/PlonkerBlocker`; management
commands require an admin account.)

## Build & test

```bash
./build.sh                     # -> "Plonker Blocker.app"
tools/run_tests.sh             # compile + run the logic tests (schedule, passcode, codable…)
swift tools/make_icon.swift    # re-rasterize src/AppIcon.svg -> src/AppIcon.icns
swift tools/make_tray.swift    # regenerate src/TrayIcon.pdf (menu-bar glyph) from its vector spec
```

Artwork: `src/AppIcon.svg` (color mark) is the app icon; `src/TrayIcon.pdf`
(vector, template-tinted) is the menu-bar icon. The tray glyph ships as a **PDF**
because `NSImage` decodes standalone SVG files only on macOS 14+, whereas PDF
templates render across the whole 11–26 range; `src/TrayIcon.svg` remains the
design source and `tools/make_tray.swift` mirrors it into the PDF.

## Installer

```bash
tools/make_installer.sh        # -> dist/PlonkerBlocker-<v>.pkg + .dmg
```

Builds the app fresh, then packages it two ways: a `.pkg` that installs to
`/Applications` (relocation disabled) and a drag-to-Applications `.dmg`. The
payload is **only the app bundle**. No policy, prefs, or logs are ever packaged
(the script fails the build if any config-like file is found inside the bundle),
and a clean install starts unconfigured. Both are ad-hoc signed, so other Macs will
show a Gatekeeper warning until the app is Developer-ID signed and notarized.

## License

Licensed under the **Apache License, Version 2.0** (see `LICENSE` and `NOTICE`).
Copyright © 2026 RoundDarkMatter. The name "Plonker Blocker" and the app/tray
artwork are not covered by the Apache trademark grant.

## Limits (honest boundary)

A strong **UI deterrent**, not kernel-enforced access control. A determined user
with a terminal could kill the guard (it relaunches, but that's a race) or drive a
scriptable protected app out-of-band (e.g. `osascript`) without ever bringing its
window forward. The cover only reacts to the frontmost window. The protected list
itself is now root-owned, so it can't be edited without admin rights. Truly
unbypassable per-app blocking needs an Apple Endpoint Security extension, Screen
Time, or MDM.
