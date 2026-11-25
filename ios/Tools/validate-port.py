#!/usr/bin/env python3
"""Portable structural checks. This does NOT compile Swift or execute Metal."""
import hashlib
import importlib.util
import json
import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent


def validate_fotufilm(errors):
    directory = ROOT / "Fotufilm/Assets"
    catalogue = json.loads((directory / "catalogue.json").read_text(encoding="utf-8"))
    manifest = (REPO / "license/Fotufilm-FILM-PROFILES.txt").read_text(encoding="utf-8")
    expected = set(re.findall(r"^  ([a-z0-9]+)\.json$", manifest, re.MULTILINE))
    stocks = catalogue["stocks"]
    ids = {stock["id"] for stock in stocks}
    if catalogue["dimension"] != 33 or len(stocks) != 47 or ids != expected:
        errors.append("Fotufilm catalogue must match the 47 attributed 33³ profiles")
        return
    assets = {path.stem for path in directory.glob("*.rgba16f")}
    if assets != ids:
        errors.append(f"Fotufilm assets differ from manifest: {sorted(assets ^ ids)}")
        return
    for stock in stocks:
        data = (directory / (stock["id"] + ".rgba16f")).read_bytes()
        if len(data) != 33 ** 3 * 8 or hashlib.sha256(data).hexdigest() != stock["lutSHA256"]:
            errors.append(f"Invalid Fotufilm LUT: {stock['id']}")


def validate():
    errors = []
    schema_text = (REPO / "engine/src/core/params.cpp").read_text(encoding="utf-8")
    schema = {m[0]: (m[1], float(m[2]), float(m[3])) for m in re.findall(
        r'\{"([a-z0-9_]+)"\s*,\s*"[^"]+"\s*,\s*[SBIF],\s*(?:SHOOT|PRINT),\s*(true|false),\s*([\d.eE+-]+),\s*([\d.eE+-]+)', schema_text)}
    recipe = (ROOT / "RustCore/src/lib.rs").read_text(encoding="utf-8")
    # These are the *actual wire keys* sent by the phone. Compare against the
    # upstream schema, rather than maintaining a second list of accepted keys.
    delta = recipe.split("fn engine_delta", 1)[1].split("\n}", 1)[0]
    for key, value in re.findall(r'"([a-z0-9_]+)"\s*:\s*([^,\n\]]+)', delta):
        if key == "product_defaults":
            continue
        if key not in schema:
            errors.append(f"Unknown engine wire key: {key}")
            continue
        ranged, lo, hi = schema[key]
        if ranged == "true":
            numbers = re.findall(r'(?<![\w.])-?\d+(?:\.\d+)?(?![\w.])', value)
            for number in numbers:
                if not lo <= float(number) <= hi:
                    errors.append(f"{key} sends {number}, outside upstream range [{lo}, {hi}]")
    # Border choices must be real engine formats, and the pre-render crop
    # must match the *engine's measured gates*, including 135's 36.25 x 24.3.
    border = (ROOT / "PocketFilm/FilmBorder.swift").read_text(encoding="utf-8")
    overscan = (REPO / "engine/src/pipeline/overscan.cpp").read_text(encoding="utf-8")
    formats = dict(re.findall(r'(\w+) = "((?:135|120)[^"]*)"', border))
    gates = {name: max(float(a), float(b)) / min(float(a), float(b))
             for name, a, b in re.findall(
                 r'\{"((?:135|120)[^"]*)",\s*[\d.]+,\s*([\d.]+),\s*([\d.]+),', overscan)}
    ratios = {name: float(a) / (float(b) if b else 1)
              for name, a, b in re.findall(r'case \.(\w+): return ([\d.]+)(?: / ([\d.]+))?', border)}
    if len(formats) != 10: errors.append("Expected ten user-selectable film border formats")
    for name, wire in formats.items():
        if wire not in gates or name not in ratios or abs(ratios[name] / gates[wire] - 1) > 0.001:
            errors.append(f"Border gate differs from upstream engine: {name} = {wire}")
    if '"striped": !border.enabled' not in delta:
        errors.append("Upstream overscan cannot use the striped executor")
    with (ROOT / "PocketFilm/Info.plist").open("rb") as f:
        info = plistlib.load(f)
    for key in ["NSCameraUsageDescription", "NSPhotoLibraryAddUsageDescription"]:
        if not info.get(key): errors.append(f"Missing permission usage string: {key}")
    if set(info.get("UISupportedInterfaceOrientations", [])) != {
        "UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"
    }:
        errors.append("Camera UI must support portrait and both landscape directions")
    project = (ROOT / "PocketFilm.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    for source in list((ROOT / "PocketFilm").glob("*.swift")) + list((ROOT / "PocketFilmTests").glob("*.swift")):
        if source.name not in project: errors.append(f"Source absent from Xcode project: {source.name}")
    if "../engine/src/shaders/" in project:
        errors.append("Engine kernels must be compiled separately with safe math")
    script = (ROOT / "Tools/build-ios-resources.sh").read_text(encoding="utf-8")
    for required in ["-fmetal-math-mode=safe", "-fmetal-math-fp32-functions=precise", "iphonesimulator", "iphoneos"]:
        if required not in script: errors.append(f"Missing platform/math setting: {required}")
    profiles = list((REPO / "engine/resources/profiles").glob("*.json"))
    profiles += list((REPO / "engine/resources_product/profiles").glob("*.json"))
    by_stock = {}
    for path in profiles:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data.get("info"), dict):
            by_stock[data["info"].get("stock", path.stem)] = data
    for stock in ["kodak_portra_400", "kodak_portra_endura"]:
        if stock not in by_stock: errors.append(f"Missing default stock: {stock}")
    count = 0
    for stock, data in by_stock.items():
        meta = data["info"]
        if meta.get("stage") == "filming" and meta.get("target_print") in by_stock:
            count += 1
    if count == 0: errors.append("No film/paper pair can be shown")
    required_files = ["license/LICENSE", "license/SPEKTRAFILM_LICENSE.txt",
        "engine/third_party/metal-cpp/LICENSE.txt", "engine/resources_product/NOTICE.md",
        "engine/resources/spektrafilm_constants.bin", "license/Fotufilm-FILM-PROFILES.txt",
        "license/Fotufilm-CC-BY-SA-4.0.txt", "ios/Fotufilm/Assets/catalogue.json"]
    for rel in required_files:
        path = REPO / rel
        if not path.is_file() or not path.stat().st_size: errors.append(f"Missing source resource: {rel}")
    if not errors:
        validate_fotufilm(errors)
    ET.parse(ROOT / "PocketFilm.xcodeproj/xcshareddata/xcschemes/PocketFilm.xcscheme")
    spec = importlib.util.spec_from_file_location("ios_project", ROOT / "Tools/gen-project.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for path, content in module.generate().items():
        if not path.exists() or path.read_text(encoding="utf-8") != content:
            errors.append(f"Generated project is stale: {path.name}")
    if errors:
        raise SystemExit("\n".join("FAIL: " + error for error in errors))
    print(f"PASS: wire keys/ranges, 10 upstream film-border gates, permissions, project, SDK/math flags, licenses, {len(profiles)} profiles ({count} film/paper pairs), 47 Fotufilm LUTs")
    print("NOT RUN: Xcode build, Swift type checking, Metal compilation, iPhone capture/performance")


if __name__ == "__main__":
    validate()
