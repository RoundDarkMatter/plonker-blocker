#!/bin/bash
# Build distributables for Plonker Blocker:
#   dist/PlonkerBlocker-<version>.pkg   — installer that puts the app in /Applications
#   dist/PlonkerBlocker-<version>.dmg   — drag-to-Applications disk image
#
# Ships ONLY the freshly built app bundle. No configuration ever rides along:
# the security policy lives in /Library/Application Support/PlonkerBlocker and
# prefs/logs in ~/Library/Application Support/PlonkerBlocker — both are created
# on first run, never packaged. A guard below fails the build if any config-like
# file sneaks into the bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Plonker Blocker.app"

echo "==> Building the app fresh"
./build.sh

VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")

echo "==> Verifying the bundle carries no configuration"
BAD=$(find "$APP" \( -name "policy.json" -o -name "prefs.json" -o -name "attempts.jsonl" \
                   -o -name "registry.json" -o -name "settings.json" -o -name "passcode.json" \) 2>/dev/null || true)
if [ -n "$BAD" ]; then
    echo "error: config files found inside the bundle:"; echo "$BAD"; exit 1
fi
echo "    clean."

rm -rf dist build/pkgroot build/dmgroot
mkdir -p dist build/pkgroot/Applications build/dmgroot

# ── .pkg ─────────────────────────────────────────────────────────
echo "==> Building pkg"
cp -R "$APP" "build/pkgroot/Applications/"
# Component plist with relocation off, so it always installs to /Applications.
pkgbuild --analyze --root build/pkgroot build/components.plist >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO build/components.plist
pkgbuild --root build/pkgroot \
         --component-plist build/components.plist \
         --identifier com.plonkerblocker.pkg \
         --version "$VERSION" \
         --install-location / \
         "dist/PlonkerBlocker-$VERSION.pkg" >/dev/null
echo "    dist/PlonkerBlocker-$VERSION.pkg"

# ── .dmg ─────────────────────────────────────────────────────────
echo "==> Building dmg"
cp -R "$APP" build/dmgroot/
ln -s /Applications build/dmgroot/Applications
hdiutil create -volname "Plonker Blocker" -srcfolder build/dmgroot \
       -format UDZO -ov "dist/PlonkerBlocker-$VERSION.dmg" >/dev/null
echo "    dist/PlonkerBlocker-$VERSION.dmg"

rm -rf build/pkgroot build/dmgroot build/components.plist
echo "==> Done. Note: ad-hoc signed — Gatekeeper will warn on other Macs"
echo "    (right-click → Open, or sign/notarize with a Developer ID for release)."
