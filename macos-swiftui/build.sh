#!/bin/bash
# Builds the native HatchMap macOS app (homelab map + network intelligence + remote control)
# from every Swift source in macos-swiftui/HatchMap/. No Xcode project: plain `xcrun swiftc`.
#
#   bash macos-swiftui/build.sh            # build → build/HatchMap.app, then launch it
#   bash macos-swiftui/build.sh --no-open  # build + install only
#
# Override the output bundle with HATCHMAP_APP, e.g.
#   HATCHMAP_APP="$HOME/Applications/HatchMap.app" bash macos-swiftui/build.sh
#
# Warnings are errors: the build is either clean or it fails. Swift 5 language mode (the network
# engine predates strict concurrency), macOS 14 deployment target, ad-hoc signed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/macos-swiftui/HatchMap"
APP="${HATCHMAP_APP:-$ROOT/build/HatchMap.app}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/hatchmap-build.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
OPEN=1; [ "${1:-}" = "--no-open" ] && OPEN=0

# SDK probe: the macOS 27.0 SDK that Command Line Tools switched to on 2026-09-26 implements
# SwiftUI's @State as a compiler macro whose plugin (SwiftUIMacros) only ships with Xcode, so
# every @State fails to compile against it. Use the newest SDK that can still build a @State.
pick_sdk() {
  local probe; probe="$(mktemp -d)"; printf 'import SwiftUI\nstruct P: View { @State var s = ""; var body: some View { Text(s) } }\n' > "$probe/p.swift"
  for sdk in "$(xcrun --show-sdk-path)" /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
    [ -d "$sdk" ] || continue
    if xcrun swiftc -swift-version 5 -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -typecheck "$probe/p.swift" >/dev/null 2>&1; then echo "$sdk"; rm -rf "$probe"; return; fi
  done
  rm -rf "$probe"; echo "$(xcrun --show-sdk-path)"
}
SDK="$(pick_sdk)"

echo "Compiling $(ls "$SRC"/*.swift | wc -l | tr -d ' ') Swift files against $(basename "$SDK")…"
xcrun swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" -O -warnings-as-errors \
  -o "$OUT/HatchMap" "$SRC"/*.swift \
  -framework AppKit -framework SwiftUI -framework Network -framework UserNotifications \
  -framework UniformTypeIdentifiers -framework Combine

echo "Assembling bundle…"
# Quit a running instance first — `open` would otherwise just refocus the old binary.
# (pkill rather than AppleScript: an Automation prompt could stall an unattended build.)
pkill -x HatchMap >/dev/null 2>&1 || true
sleep 0.5
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/HatchMap" "$APP/Contents/MacOS/HatchMap"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
[ -f "$SRC/../AppIcon.icns" ] && cp "$SRC/../AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP" >/dev/null

echo "Done: $APP  ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist"))"
[ "$OPEN" = 1 ] && open "$APP"
exit 0
