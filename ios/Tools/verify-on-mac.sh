#!/bin/bash
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$here"
python3 Tools/gen-project.py --check
python3 Tools/validate-port.py
destination=${1:-generic/platform=iOS}
if [[ "$destination" == "generic/platform=iOS" ]]; then
  xcodebuild -project PocketFilm.xcodeproj -scheme PocketFilm -configuration Debug \
    -destination "$destination" -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
  echo 'Device SDK compilation finished. Select a signing team in Xcode to install.'
else
  xcodebuild -project PocketFilm.xcodeproj -scheme PocketFilm -configuration Debug \
    -destination "$destination" -derivedDataPath build/DerivedData test
fi
