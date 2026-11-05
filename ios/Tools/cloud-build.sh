#!/bin/bash
# macOS CI only. No certificate, Apple login, provisioning profile or secret.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$here"
artifacts="$here/build/artifacts"
derived="$here/build/DeviceData"
mkdir -p "$artifacts"
python3 Tools/gen-project.py --check
python3 Tools/validate-port.py
xcodebuild -project PocketFilm.xcodeproj -scheme PocketFilm -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build \
  2>&1 | tee "$artifacts/device-build.log"
app="$derived/Build/Products/Release-iphoneos/PocketFilm.app"
[[ -x "$app/PocketFilm" ]] || { echo "Device executable was not produced" >&2; exit 1; }
[[ -s "$app/engine/spektrafilm.metallib" ]] || { echo "iOS engine library is missing" >&2; exit 1; }
# Avoid ditto's AppleDouble ._PocketFilm.app entry: AltStore can mistake that
# metadata file for the actual app. zipfile preserves the app's Unix modes.
python3 Tools/package-ipa.py "$app" "$artifacts/PocketFilm-unsigned.ipa"
shasum -a 256 "$artifacts/PocketFilm-unsigned.ipa" > "$artifacts/PocketFilm-unsigned.sha256"
cat > "$artifacts/READ-ME-FIRST.txt" <<'EOF'
PocketFilm-unsigned.ipa is an unsigned iPhone device build, NOT an install-ready app.
Sign/install locally on Windows using your own Apple account and a compatible tool.
No Apple password, certificate or verification code is required by this cloud build.
Review the Actions job and simulator test results; an artifact can exist after tests fail.
On-device RAW capture, orientation, memory use and performance still need testing.
EOF
echo "Unsigned IPA produced: $artifacts/PocketFilm-unsigned.ipa"
