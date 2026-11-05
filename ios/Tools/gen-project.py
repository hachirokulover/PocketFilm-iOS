#!/usr/bin/env python3
"""Generate the independent iPhone target; no XcodeGen/package dependencies.

Run after adding/removing iOS or engine sources. Engine MSL is deliberately
NOT part of PBXSourcesBuildPhase; the SDK-specific script preserves safe math.
"""
import hashlib
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent


def uid(key):
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()


def quote(value):
    return json.dumps(str(value), ensure_ascii=False)


def generate():
    objects = []

    def obj(key, value):
        ident = uid(key)
        objects.append(f"\t\t{ident} = {{ {value} }};")
        return ident

    def array(items):
        return "(" + ", ".join(items) + ("," if items else "") + ")"

    def config(key, name, settings):
        body = " ".join(f"{k} = {quote(v)};" for k, v in sorted(settings.items()))
        return obj(key, f"isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {name};")

    def config_list(key, configs):
        return obj(key, f"isa = XCConfigurationList; buildConfigurations = {array(configs)}; "
                   "defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

    app_sources = sorted((ROOT / "PocketFilm").glob("*.swift")) + [ROOT / "PocketFilm/Display.metal"]
    excluded = {"gpu/vulkan_gpu.cpp", "pipeline/windows_unported.cpp"}
    engine = sorted(p for p in (REPO / "engine/src").rglob("*.cpp")
                    if p.relative_to(REPO / "engine/src").parts[0] not in {"io", "desktop"}
                    and p.relative_to(REPO / "engine/src").as_posix() not in excluded)
    tests = sorted((ROOT / "PocketFilmTests").glob("*.swift"))
    file_ids = []
    app_builds = []
    test_builds = []
    for path in app_sources + engine + tests:
        rel = Path(os.path.relpath(path, ROOT)).as_posix()
        typ = {".swift": "sourcecode.swift", ".cpp": "sourcecode.cpp.cpp", ".metal": "sourcecode.metal"}[path.suffix]
        ref = obj("file:" + rel, f"isa = PBXFileReference; lastKnownFileType = {typ}; path = {quote(rel)}; sourceTree = SOURCE_ROOT;")
        build = obj("build:" + rel, f"isa = PBXBuildFile; fileRef = {ref};")
        file_ids.append(ref)
        (test_builds if path in tests else app_builds).append(build)

    frameworks = ["Metal", "MetalKit", "Foundation", "QuartzCore", "CoreImage", "CoreGraphics",
                  "CoreText", "Accelerate", "AVFoundation", "Photos", "UIKit", "ImageIO", "UniformTypeIdentifiers"]
    framework_ids, framework_builds = [], []
    for name in frameworks:
        ref = obj("framework:" + name,
                  f"isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {name}.framework; "
                  f"path = System/Library/Frameworks/{name}.framework; sourceTree = SDKROOT;")
        framework_ids.append(ref)
        framework_builds.append(obj("link:" + name, f"isa = PBXBuildFile; fileRef = {ref};"))

    product = obj("product", "isa = PBXFileReference; explicitFileType = wrapper.application; "
                  "path = PocketFilm.app; sourceTree = BUILT_PRODUCTS_DIR;")
    test_product = obj("test-product", "isa = PBXFileReference; explicitFileType = wrapper.cfbundle; "
                       "path = PocketFilmTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;")
    products = obj("products", f"isa = PBXGroup; children = {array([product, test_product])}; name = Products; sourceTree = \"<group>\";")
    sources = obj("sources", f"isa = PBXGroup; children = {array(file_ids)}; name = Sources; sourceTree = \"<group>\";")
    fwgroup = obj("framework-group", f"isa = PBXGroup; children = {array(framework_ids)}; name = Frameworks; sourceTree = \"<group>\";")
    group = obj("main-group", f"isa = PBXGroup; children = {array([sources, fwgroup, products])}; sourceTree = \"<group>\";")
    app_source_phase = obj("app-sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; "
                           f"files = {array(app_builds)}; runOnlyForDeploymentPostprocessing = 0;")
    assets_ref = obj("app-assets", "isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; "
                     "path = PocketFilm/Assets.xcassets; sourceTree = SOURCE_ROOT;")
    assets_build = obj("app-assets-build", f"isa = PBXBuildFile; fileRef = {assets_ref};")
    assets_phase = obj("app-resources", "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; "
                       f"files = {array([assets_build])}; runOnlyForDeploymentPostprocessing = 0;")
    test_source_phase = obj("test-sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; "
                            f"files = {array(test_builds)}; runOnlyForDeploymentPostprocessing = 0;")
    app_fw = obj("app-frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; "
                 f"files = {array(framework_builds)}; runOnlyForDeploymentPostprocessing = 0;")
    test_fw = obj("test-frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
    script_command = '/bin/bash "$SRCROOT/Tools/build-ios-resources.sh"'
    script = obj("build-resources", "isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; "
                 "files = (); inputPaths = (); outputPaths = (); name = \"Compile iOS engine kernels and bundle licenses\"; "
                 "runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/bash; "
                 f"shellScript = {quote(script_command)};")
    common = {
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "TARGETED_DEVICE_FAMILY": "1", "SUPPORTS_MACCATALYST": "NO", "SWIFT_VERSION": "5.0",
        "SWIFT_STRICT_CONCURRENCY": "minimal", "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
        "CLANG_CXX_LANGUAGE_STANDARD": "c++20", "CLANG_CXX_LIBRARY": "libc++",
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "NO", "CLANG_ENABLE_OBJC_WEAK": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO", "MTL_FAST_MATH": "NO",
        "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": os.environ.get("POCKETFILM_TEAM_ID", ""),
        "HEADER_SEARCH_PATHS": '$(inherited) "$(SRCROOT)/../engine/include" "$(SRCROOT)/../engine/src" "$(SRCROOT)/../engine/src/core" "$(SRCROOT)/../engine/third_party/metal-cpp"',
        "SWIFT_OBJC_BRIDGING_HEADER": "$(SRCROOT)/PocketFilm/Bridge.h",
        "OTHER_CPLUSPLUSFLAGS": "$(inherited) -fblocks", "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
    }
    app_configs, test_configs, project_configs = [], [], []
    for mode in ["Debug", "Release"]:
        debug = mode == "Debug"
        project_configs.append(config("project-config:" + mode, mode, {
            "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES", "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
            "GCC_OPTIMIZATION_LEVEL": "2", "DEBUG_INFORMATION_FORMAT": "dwarf" if debug else "dwarf-with-dsym"}))
        app_configs.append(config("app-config:" + mode, mode, dict(common, **{
            "PRODUCT_NAME": "PocketFilm", "PRODUCT_BUNDLE_IDENTIFIER": "org.pocketfilm.camera",
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "INFOPLIST_FILE": "PocketFilm/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if debug else "-O", "ENABLE_TESTABILITY": "YES" if debug else "NO",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if debug else "",
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        })))
        test_configs.append(config("test-config:" + mode, mode, dict(common, **{
            "PRODUCT_NAME": "PocketFilmTests", "PRODUCT_BUNDLE_IDENTIFIER": "org.pocketfilm.camera.tests",
            "GENERATE_INFOPLIST_FILE": "YES", "BUNDLE_LOADER": "$(TEST_HOST)",
            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/PocketFilm.app/PocketFilm",
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if debug else "-O",
        })))
    app_cl = config_list("app-configs", app_configs)
    test_cl = config_list("test-configs", test_configs)
    project_cl = config_list("project-configs", project_configs)
    app_target = uid("app-target")
    project_id = uid("project")
    proxy = obj("app-proxy", f"isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; "
                f"remoteGlobalIDString = {app_target}; remoteInfo = PocketFilm;")
    dependency = obj("test-dependency", f"isa = PBXTargetDependency; target = {app_target}; targetProxy = {proxy};")
    obj("app-target", f"isa = PBXNativeTarget; buildConfigurationList = {app_cl}; "
        f"buildPhases = {array([script, app_source_phase, app_fw, assets_phase])}; buildRules = (); dependencies = (); "
        f"name = PocketFilm; productName = PocketFilm; productReference = {product}; productType = \"com.apple.product-type.application\";")
    test_target = obj("test-target", f"isa = PBXNativeTarget; buildConfigurationList = {test_cl}; "
                      f"buildPhases = {array([test_source_phase, test_fw])}; buildRules = (); dependencies = {array([dependency])}; "
                      f"name = PocketFilmTests; productName = PocketFilmTests; productReference = {test_product}; "
                      "productType = \"com.apple.product-type.bundle.unit-test\";")
    obj("project", "isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; "
        f"TargetAttributes = {{ {test_target} = {{ TestTargetID = {app_target}; }}; }}; }}; "
        f"buildConfigurationList = {project_cl}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; "
        f"hasScannedForEncodings = 0; knownRegions = (en, Base, \"zh-Hans\"); mainGroup = {group}; productRefGroup = {products}; "
        f"projectDirPath = \"\"; projectRoot = \"\"; targets = {array([app_target, test_target])};")
    project = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n"
    project += "\n".join(objects) + f"\n\t}};\n\trootObject = {project_id};\n}}\n"
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="PocketFilm.app" BlueprintName="PocketFilm" ReferencedContainer="container:PocketFilm.xcodeproj"/>
</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
<TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="PocketFilmTests.xctest" BlueprintName="PocketFilmTests" ReferencedContainer="container:PocketFilm.xcodeproj"/></TestableReference>
</Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
<BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="PocketFilm.app" BlueprintName="PocketFilm" ReferencedContainer="container:PocketFilm.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    return {ROOT / "PocketFilm.xcodeproj/project.pbxproj": project,
            ROOT / "PocketFilm.xcodeproj/xcshareddata/xcschemes/PocketFilm.xcscheme": scheme}


if __name__ == "__main__":
    check = "--check" in sys.argv
    for path, content in generate().items():
        if check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                raise SystemExit(f"Stale project: {path}. Run ios/Tools/gen-project.py")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8", newline="\n")
    print("iOS project is current" if check else "Generated PocketFilm.xcodeproj")
