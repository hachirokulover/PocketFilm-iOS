#!/bin/bash
# Invoked by the iOS target before compilation. Never copy a macOS metallib.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
sdk=${PLATFORM_NAME:?Run this script through Xcode or xcodebuild}
minimum=${IPHONEOS_DEPLOYMENT_TARGET:-17.0}
case "$sdk" in
  iphoneos) min_flag="-mios-version-min=$minimum" ;;
  iphonesimulator) min_flag="-mios-simulator-version-min=$minimum" ;;
  *) echo "Unsupported iOS platform: $sdk" >&2; exit 1 ;;
esac
out="${DERIVED_FILE_DIR:?}/PocketFilmEngine-$sdk"
dest="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
mkdir -p "$out" "$dest/engine" "$dest/Licenses"
shader_dir="$repo/engine/src/shaders"
math_flags=(-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise)
# Fingerprint the toolchain as well as the sources: an Xcode upgrade must not
# reuse the previous compiler's AIR files, even on the same SDK name.
stamp="$out/compiler.txt"
compiler=$(xcrun -sdk "$sdk" --find metal)
identity="$compiler|$(xcrun -sdk "$sdk" --show-sdk-path)|$minimum|${math_flags[*]}"
rebuild=0
if [[ ! -f "$stamp" ]] || [[ "$(cat "$stamp")" != "$identity" ]]; then rebuild=1; fi
airs=()
for source in "$shader_dir"/*.metal; do
  air="$out/$(basename "$source" .metal).air"
  if [[ $rebuild == 1 || ! -f "$air" || "$source" -nt "$air" || "$shader_dir/spk_common.h" -nt "$air" ]]; then
    xcrun -sdk "$sdk" metal "${math_flags[@]}" "$min_flag" -Werror -c "$source" -o "$air"
  fi
  airs+=("$air")
done
[[ ${#airs[@]} -gt 0 ]] || { echo "No engine shaders found" >&2; exit 1; }
xcrun -sdk "$sdk" metallib "${airs[@]}" -o "$out/spektrafilm.metallib"
printf '%s\n' "$identity" > "$stamp"
[[ -s "$repo/engine/resources/spektrafilm_constants.bin" ]] || { echo "Missing baked constants" >&2; exit 1; }
# Engine data is copied intact; the platform-specific library is replaced last.
rsync -a --exclude='*.metallib' "$repo/engine/resources/" "$dest/engine/"
if [[ -d "$repo/engine/resources_product/profiles" ]]; then
  cp "$repo/engine/resources_product/profiles/"*.json "$dest/engine/profiles/"
  cp "$repo/engine/resources_product/NOTICE.md" "$dest/engine/PRODUCT_PROFILES_NOTICE.md"
fi
cp "$out/spektrafilm.metallib" "$dest/engine/spektrafilm.metallib"
cp "$repo/license/LICENSE" "$dest/Licenses/GPL-3.0.txt"
cp "$repo/license/SPEKTRAFILM_LICENSE.txt" "$dest/Licenses/SPEKTRAFILM_LICENSE.txt"
cp "$repo/engine/third_party/metal-cpp/LICENSE.txt" "$dest/Licenses/metal-cpp-LICENSE.txt"
cp "$repo/engine/resources_product/NOTICE.md" "$dest/Licenses/PRODUCT_PROFILES_NOTICE.md"
for required in engine/spektrafilm_constants.bin engine/spektrafilm.metallib \
  engine/profiles/kodak_portra_400.json engine/profiles/kodak_portra_endura.json \
  Licenses/GPL-3.0.txt Licenses/SPEKTRAFILM_LICENSE.txt Licenses/metal-cpp-LICENSE.txt; do
  [[ -s "$dest/$required" ]] || { echo "Missing bundle resource: $required" >&2; exit 1; }
done
echo "Bundled iOS engine resources for $sdk (safe/precise math)"
