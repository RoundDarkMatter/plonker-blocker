#!/bin/bash
# Build "Plonker Blocker.app": the manager (main executable) + background guard agent.
set -euo pipefail
cd "$(dirname "$0")"

APP="Plonker Blocker.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

compile_universal() {
    local out="$1"; shift
    local arm="$out.arm64" x86="$out.x86_64"
    local fw="-framework Cocoa -framework Security -framework LocalAuthentication -framework UserNotifications"
    swiftc -O -target arm64-apple-macos12.0 -o "$arm" "$@" $fw
    if swiftc -O -target x86_64-apple-macos12.0 -o "$x86" "$@" $fw 2>/dev/null; then
        lipo -create -output "$out" "$arm" "$x86"; rm -f "$arm" "$x86"
    else
        echo "    (x86_64 slice unavailable — $out is arm64-only)"; mv "$arm" "$out"
    fi
}

echo "==> Cleaning"
rm -rf "$APP" build
mkdir -p "$MACOS" build

echo "==> Compiling background guard agent"
compile_universal build/PlonkerBlockerGuard src/Gate.swift src/Shared.swift src/Guard.swift

echo "==> Compiling manager"
compile_universal build/PlonkerBlocker src/Gate.swift src/Shared.swift src/Manager.swift

echo "==> Assembling bundle"
cp build/PlonkerBlocker "$MACOS/PlonkerBlocker"
cp src/Info.plist "$CONTENTS/Info.plist"
mkdir -p "$CONTENTS/Resources"
[ -f src/AppIcon.icns ] && cp src/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
chmod +x "$MACOS/PlonkerBlocker"

# The guard ships as its own LSUIElement .app so launchd-launched instances can
# actually draw the lock overlay (a bare executable's windows won't composite).
GUARDAPP="$CONTENTS/Library/LoginItems/PlonkerBlockerGuard.app"
mkdir -p "$GUARDAPP/Contents/MacOS" "$GUARDAPP/Contents/Resources"
cp build/PlonkerBlockerGuard "$GUARDAPP/Contents/MacOS/PlonkerBlockerGuard"
cp src/GuardInfo.plist "$GUARDAPP/Contents/Info.plist"
[ -f src/ahahah.gif ] && cp src/ahahah.gif "$GUARDAPP/Contents/Resources/ahahah.gif"
[ -f src/TrayIcon.svg ] && cp src/TrayIcon.svg "$GUARDAPP/Contents/Resources/TrayIcon.svg"
chmod +x "$GUARDAPP/Contents/MacOS/PlonkerBlockerGuard"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

rm -rf build
echo "==> Done: $(pwd)/$APP"
