#!/bin/bash
# Build signed split APKs with the installed native JDK. This avoids Flutter's
# eager Android Studio probe, which fails with an Intel-only Studio installation.
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-$HOME/flutter/bin/flutter}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
cd "$PROJECT_DIR"
"$FLUTTER_BIN" pub get
python3 - <<'PY'
from pathlib import Path
import re
version = re.search(r'^version:\s*([^\s+]+)\+(\d+)\s*$', Path('pubspec.yaml').read_text(), re.M)
if not version:
    raise SystemExit('Expected version: name+number in pubspec.yaml')
p = Path('android/local.properties')
lines = [line for line in (p.read_text().splitlines() if p.exists() else []) if not line.startswith(('flutter.versionName=', 'flutter.versionCode=', 'flutter.buildMode='))]
lines.extend([f'flutter.versionName={version[1]}', f'flutter.versionCode={version[2]}', 'flutter.buildMode=release'])
p.write_text('\n'.join(lines) + '\n')
PY
cd android
./gradlew -Ptarget-platform=android-arm,android-arm64,android-x64 \
  -Ptarget=lib/main.dart -Psplit-per-abi=true -Ptree-shake-icons=true assembleRelease
cd "$PROJECT_DIR"
OUT_APK="${OUT_APK:-$PROJECT_DIR/build/HatchMap-arm64.apk}"
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "$OUT_APK"
echo "Updated $OUT_APK"
