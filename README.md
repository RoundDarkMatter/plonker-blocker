# Plonker Blocker

Keeps careless (or unauthorized) users out of the apps you choose — by locking
the **window** behind a passcode, Touch ID, or an administrator password, without
modifying the apps themselves. Open a protected app and a full-screen lock covers
it until someone authenticates. Guess wrong and it plays an "Ah ah ah! You didn't
say the magic word!" animation.

> The project *folder* is still named `AdminGate/` for git history's sake, but
> every binary, bundle, and support path now uses the **PlonkerBlocker** name, and
> everything you see — Dock, menu bar, windows — says **Plonker Blocker**.

## How it works

- **Plonker Blocker.app (manager)** — an admin-gated window to pick which apps to
  protect (stored by bundle id), turn protection on/off, set the re-lock timeout,
  define a locking schedule, and review the activity log. It never moves or
  modifies an app bundle.
- **Guard** — a background agent (a per-user LaunchAgent). It watches the frontmost
  app; when a protected one comes forward *and the schedule is active*, it drops an
  opaque lock over the screen and offers unlock by passcode, Touch ID, or the macOS
  admin dialog. Unlock just removes our overlay — the target app is never touched.
  No Accessibility / App Management / root needed for the guard itself.

Behavior:
- Open a protected app → lock screen (its icon + a lock badge) with a passcode
  field and Touch ID.
- Authenticate → unlocks for the **"Unlock for"** duration set in the app
  (default **5 min**; options 1 / 5 / 15 / 30 / 60 min or **Never**).
- Cancel → lock stays; retry or **⌘⇥** to switch away.
- **Wrong passcode → "Ah ah ah!"** immediately; 3 in a row start an escalating
  lockout (5s→60s) while Touch ID keeps working.

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
in **Activity…** (or `--log`). The guard also posts local notifications when an
app is locked and after repeated failed attempts.

## Menu-bar item, background & login

When protection is on, Plonker Blocker runs **persistently in the background**, shows
a 🔒 in the menu bar, and **starts at login** (LaunchAgent, relaunches if killed).
The menu-bar item lets you **Lock All Now**, open the manager, or **Turn Off
Protection** (admin required).

## The "Ah ah ah!" animation & sound

A built-in wagging-finger animation ships with the app; a system sound plays on a
wrong passcode. Both can be toggled independently under **Lock Screen** in the app
menu (both on by default). To use your own animation, drop a GIF at:

```
~/Library/Application Support/PlonkerBlocker/ahahah.gif
```

## Use it

1. Open `Plonker Blocker.app` (authenticate as admin).
2. **Protect App…** → pick an open app or **Browse…**. (System apps that would trap
   the screen — Finder, Dock, etc. — are refused.) Filter the list with the search
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
tools/make_gif.swift           # regenerate the built-in ahahah.gif
```

Artwork: `src/AppIcon.svg` (color mark) is the app icon; `src/TrayIcon.svg`
(monochrome, template-tinted) is the menu-bar icon — swap either SVG and rebuild
(`make_icon` first for the app icon) to re-skin.

## Installer

```bash
tools/make_installer.sh        # -> dist/PlonkerBlocker-<v>.pkg + .dmg
```

Builds the app fresh, then packages it two ways: a `.pkg` that installs to
`/Applications` (relocation disabled) and a drag-to-Applications `.dmg`. The
payload is **only the app bundle** — no policy, prefs, or logs are ever packaged
(the script fails the build if any config-like file is found inside the bundle);
a clean install starts unconfigured. Both are ad-hoc signed, so other Macs will
show a Gatekeeper warning until the app is Developer-ID signed and notarized.

The copyright string (shown in **About Plonker Blocker** and Finder's Get Info)
is a **placeholder** in `src/Info.plist` / `src/GuardInfo.plist`
(`NSHumanReadableCopyright`) — replace it before release.

## Limits (honest boundary)

A strong **UI deterrent**, not kernel-enforced access control. A determined user
with a terminal could kill the guard (it relaunches, but that's a race) or drive a
scriptable protected app out-of-band (e.g. `osascript`) without ever bringing its
window forward — the cover only reacts to the frontmost window. The protected list
itself is now root-owned, so it can't be edited without admin rights. Truly
unbypassable per-app blocking needs an Apple Endpoint Security extension, Screen
Time, or MDM.
