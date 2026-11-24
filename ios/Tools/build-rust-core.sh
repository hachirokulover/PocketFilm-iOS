#!/bin/bash
set -euo pipefail

export PATH="$PATH:$HOME/.cargo/bin"
command -v cargo >/dev/null || { echo "Install Rust with rustup to build PocketFilm." >&2; exit 1; }

core="$SRCROOT/RustCore"
target_dir="$DERIVED_FILE_DIR/PocketFilmRust"
libraries=()
for arch in ${ARCHS:?Xcode must supply ARCHS}; do
  case "$PLATFORM_NAME:$arch" in
    iphoneos:arm64) target=aarch64-apple-ios ;;
    iphonesimulator:arm64) target=aarch64-apple-ios-sim ;;
    iphonesimulator:x86_64) target=x86_64-apple-ios ;;
    *) echo "Unsupported Rust target: $PLATFORM_NAME:$arch" >&2; exit 1 ;;
  esac
  cargo +stable build --manifest-path "$core/Cargo.toml" --locked --release \
    --target "$target" --target-dir "$target_dir"
  libraries+=("$target_dir/$target/release/libpocketfilm_core.a")
done

output="$DERIVED_FILE_DIR/libpocketfilm_core.a"
if (( ${#libraries[@]} == 1 )); then
  cp "${libraries[0]}" "$output"
else
  xcrun lipo -create "${libraries[@]}" -output "$output"
fi

license_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Licenses"
mkdir -p "$license_dir"
cargo +stable metadata --manifest-path "$core/Cargo.toml" --locked --format-version 1 |
  python3 -c '
import json, sys
from pathlib import Path

packages = json.load(sys.stdin)["packages"]
with Path(sys.argv[1]).open("w", encoding="utf-8") as out:
    for package in sorted(packages, key=lambda item: item["name"]):
        if package["source"] is None:
            continue
        print("{name} {version} ({license})".format(**package), file=out)
        folder = Path(package["manifest_path"]).parent
        for path in sorted(folder.glob("LICENSE*")) + sorted(folder.glob("NOTICE*")):
            if path.is_file():
                print(path.read_text(encoding="utf-8"), file=out)
' "$license_dir/Rust-dependencies.txt"
