import XCTest
import CoreImage
import Metal
import UIKit
@testable import PocketFilm

final class PortTests: XCTestCase {
    func testRearCameraRotationMatchesDeviceAndInterfaceDirections() {
        XCTAssertEqual(CameraOrientation.captureAngle(for: .portrait, fallback: 0), 90)
        XCTAssertEqual(CameraOrientation.captureAngle(for: .portraitUpsideDown, fallback: 0), 270)
        // Device and interface landscape naming is reversed in UIKit.
        XCTAssertEqual(CameraOrientation.captureAngle(for: .landscapeLeft, fallback: 90),
                       CameraOrientation.previewAngle(for: .landscapeRight))
        XCTAssertEqual(CameraOrientation.captureAngle(for: .landscapeRight, fallback: 90),
                       CameraOrientation.previewAngle(for: .landscapeLeft))
        XCTAssertEqual(CameraOrientation.previewAngle(for: .landscapeRight), 0)
        XCTAssertEqual(CameraOrientation.previewAngle(for: .landscapeLeft), 180)
    }

    func testFlatDeviceKeepsLastCaptureOrientation() {
        for orientation in [UIDeviceOrientation.faceUp, .faceDown, .unknown] {
            for previous in [CGFloat(0), 90, 180, 270] {
                XCTAssertEqual(CameraOrientation.captureAngle(for: orientation, fallback: previous), previous)
            }
        }
    }

    func testRawModeNeverSilentlySubstitutesAnotherFormat() {
        let pro: (OSType) -> Bool = { $0 == 2 }
        let bayer: (OSType) -> Bool = { $0 == 1 }
        XCTAssertEqual(CameraService.chooseRaw([1, 2], preferProRAW: true, isProRAW: pro, isBayer: bayer), 2)
        XCTAssertEqual(CameraService.chooseRaw([1, 2], preferProRAW: false, isProRAW: pro, isBayer: bayer), 1)
        XCTAssertNil(CameraService.chooseRaw([1], preferProRAW: true, isProRAW: pro, isBayer: bayer))
        XCTAssertNil(CameraService.chooseRaw([], preferProRAW: false, isProRAW: pro, isBayer: bayer))
    }

    func testInputAndJPEGKeepTopRowFirst() throws {
        let engine = try FilmEngine() // missing Metal is a failure, never a skip
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 8, width: 16, height: 8))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8))
        let image = red.composited(over: blue)
        let (input, width, height) = try engine.inputBuffer(image)
        XCTAssertEqual(width, 16); XCTAssertEqual(height, 16)
        let pixels = input.contents().bindMemory(to: Float.self, capacity: width * height * 4)
        XCTAssertGreaterThan(pixels[0], pixels[2])
        let last = (height - 1) * width * 4
        XCTAssertGreaterThan(pixels[last + 2], pixels[last])

        // Exercise the exact texture -> JPEG route the result sheet and Photos
        // read. Distinct regions catch a vertical flip that gray ramps cannot.
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: 16, height: 16, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .shaderRead
        let texture = try XCTUnwrap(engine.device.makeTexture(descriptor: desc))
        var rgba = [UInt16](repeating: 0, count: 16 * 16 * 4)
        for y in 0..<16 { for x in 0..<16 {
            let offset = (y * 16 + x) * 4
            rgba[offset + (y < 8 ? 0 : 2)] = .max
            rgba[offset + 3] = .max
        } }
        rgba.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0,
                                               withBytes: $0.baseAddress!, bytesPerRow: 16 * 8) }
        let bytes = try engine.jpeg(FilmFrame(texture: texture, elapsedMS: 0, colorSpace: FilmEngine.outputSpace))
        let jpeg = try XCTUnwrap(CIImage(data: bytes))
        var row = [UInt8](repeating: 0, count: 16 * 16 * 4)
        row.withUnsafeMutableBytes { engine.context.render(jpeg, toBitmap: $0.baseAddress!, rowBytes: 64,
            bounds: CGRect(x: 0, y: 0, width: 16, height: 16), format: .RGBA8, colorSpace: FilmEngine.outputSpace) }
        XCTAssertGreaterThan(row[0], row[2])
        XCTAssertGreaterThan(row[last + 2], row[last])
    }

    func testEngineResultSurvivesNextRenderAndHasDeclaredDimensions() throws {
        let engine = try FilmEngine()
        var recipe = FilmRecipe()
        recipe.grain = false; recipe.halation = false
        let a = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let first = try engine.render(a, recipe: recipe, preview: false)
        let before = snapshot(first.texture)
        let b = CIImage(color: CIColor(red: 0.5, green: 0.2, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let second = try engine.render(b, recipe: recipe, preview: false)
        XCTAssertEqual(first.texture.width, 32); XCTAssertEqual(first.texture.height, 24)
        XCTAssertEqual(snapshot(first.texture), before)
        XCTAssertNotEqual(snapshot(second.texture), before)
        let repeatFrame = try engine.render(a, recipe: recipe, preview: false)
        XCTAssertEqual(snapshot(repeatFrame.texture), before)
        recipe.sceneEV = 1
        let brighter = try engine.render(a, recipe: recipe, preview: false)
        XCTAssertGreaterThan(snapshot(brighter.texture)[0], before[0],
            "Film EV must be applied after metering and not cancelled by print compensation")
    }

    func testResizeDoesNotAddTransparentBorder() {
        for origin in [CGPoint(x: 3, y: 5), CGPoint(x: 3.2, y: 5.7), CGPoint(x: -13.1, y: -5.3)] {
            let image = CIImage(color: .white).cropped(to: CGRect(origin: origin, size: CGSize(width: 4032, height: 3024)))
            let resized = FilmEngine.resized(image, maxEdge: 480)
            XCTAssertEqual(resized.extent, CGRect(x: 0, y: 0, width: 480, height: 360))
        }
    }

    func testManualEffectValuesReachTheEngine() {
        var recipe = FilmRecipe()
        recipe.grainAmount = 0
        recipe.halationAmount = 2.5
        let delta = recipe.engineDelta(preview: false)
        XCTAssertEqual(delta["grain_active"] as? Bool, false)
        XCTAssertEqual(delta["grain_amount"] as? Double, 0)
        XCTAssertEqual(delta["halation_amount"] as? Double, 2.5)
    }

    func testImageRenamedToDNGIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let bytes = try XCTUnwrap(context.jpegRepresentation(of: image,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:]))
        try bytes.write(to: url)
        XCTAssertThrowsError(try FilmEngine.validateRAW(url))
    }

    func testAllFilmGatesCropInsideSourceInEitherOrientation() {
        var border = FilmBorderSettings()
        border.enabled = true
        for format in FilmBorderFormat.allCases {
            border.format = format
            for size in [CGSize(width: 4032, height: 3024), CGSize(width: 3024, height: 4032)] {
                let extent = CGRect(origin: CGPoint(x: -7.25, y: 3.75), size: size)
                let crop = border.cropRect(in: extent)
                XCTAssertTrue(extent.contains(crop), format.rawValue)
                XCTAssertEqual(crop.midX, extent.midX, accuracy: 0.001)
                XCTAssertEqual(crop.midY, extent.midY, accuracy: 0.001)
                let expected = size.width >= size.height ? format.gateRatio : 1 / format.gateRatio
                XCTAssertEqual(crop.width / crop.height, expected, accuracy: 0.002)
                let image = border.cropped(CIImage(color: .white).cropped(to: extent))
                XCTAssertEqual(image.extent.origin, .zero)
                XCTAssertEqual(image.extent.size, crop.size)
            }
        }
        border.enabled = false
        let original = CGRect(x: 1.25, y: 2.5, width: 400, height: 300)
        XCTAssertEqual(border.cropRect(in: original), original)
    }

    func testBorderRecipeRoundTripAndLegacySidecar() throws {
        let legacy = Data(#"{"film":"kodak_portra_400","sceneEV":0.5,"temperature":6300}"#.utf8)
        let old = try JSONDecoder().decode(FilmRecipe.self, from: legacy)
        XCTAssertFalse(old.border.enabled)
        XCTAssertEqual(old.sceneEV, 0.5)
        XCTAssertEqual(old.temperature, 6300)
        var recipe = old
        recipe.border.enabled = true
        recipe.border.format = .f6x7
        recipe.border.frameSeed = 91234
        recipe.border.holes = .black
        let roundTrip = try JSONDecoder().decode(FilmRecipe.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(roundTrip, recipe)
        let delta = recipe.engineDelta(preview: false)
        XCTAssertEqual(delta["overscan_active"] as? Bool, true)
        XCTAssertEqual(delta["overscan_format"] as? String, "120_6x7")
        XCTAssertEqual(delta["striped"] as? Bool, false)
        XCTAssertEqual(recipe.processingEdge, 2048)
        recipe.border.enabled = false
        XCTAssertEqual(recipe.engineDelta(preview: false)["overscan_active"] as? Bool, false)
        XCTAssertEqual(recipe.engineDelta(preview: false)["striped"] as? Bool, true)
        XCTAssertEqual(recipe.processingEdge, 4032)
    }

    func testChangedBorderCannotExportOldJPEGAsCurrent() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let original = Data("original-raw-bytes".utf8)
        var recipe = FilmRecipe()
        let item = try CaptureStore.prepare(raw: original, recipe: recipe, baseDirectory: scratch)
        XCTAssertFalse(CaptureStore.isCurrent(item, recipe: recipe))
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: item.jpeg)
        XCTAssertTrue(CaptureStore.isCurrent(item, recipe: recipe))
        recipe.border.enabled = true
        XCTAssertFalse(CaptureStore.isCurrent(item, recipe: recipe))
        try CaptureStore.write(recipe: recipe, for: item)
        XCTAssertTrue(CaptureStore.isCurrent(item, recipe: recipe))
        recipe.border.format = .f6x6
        XCTAssertFalse(CaptureStore.isCurrent(item, recipe: recipe))
        XCTAssertEqual(try Data(contentsOf: item.source), original)
    }

    func testNativeEngineAcceptsEveryOfferedBorderAndScan() throws {
        let engine = try FilmEngine()
        let source = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 240, height: 180))
        var recipe = FilmRecipe()
        recipe.grain = false; recipe.halation = false
        recipe.border.enabled = true
        for format in FilmBorderFormat.allCases {
            recipe.border.format = format
            for scan in FilmBorderScan.allCases {
                recipe.border.scan = scan
                let frame = try engine.render(source, recipe: recipe, preview: false)
                XCTAssertGreaterThan(frame.texture.width, 0, format.rawValue)
                XCTAssertGreaterThan(frame.texture.height, 0, format.rawValue)
            }
        }
        recipe.border.enabled = false
        let plain = try engine.render(source, recipe: recipe, preview: false)
        XCTAssertEqual(plain.texture.width, 240)
        XCTAssertEqual(plain.texture.height, 180)
    }

    private func snapshot(_ texture: MTLTexture) -> [UInt16] {
        var data = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        data.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
        return data
    }
}
