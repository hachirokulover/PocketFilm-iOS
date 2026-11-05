import XCTest
import CoreImage
import Metal
import UIKit
import ImageIO
@testable import PocketFilm

final class SurfaceAgreementTests: XCTestCase {
    func testCanvasAndExportAgreeOnAsymmetricFrame() throws {
        let engine = try FilmEngine()
        let device = engine.device
        let sourceDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm,
            width: 16, height: 16, mipmapped: false)
        sourceDesc.storageMode = .shared
        sourceDesc.usage = .shaderRead
        let source = try XCTUnwrap(device.makeTexture(descriptor: sourceDesc))
        var pixels = [UInt16](repeating: 0, count: 16 * 16 * 4)
        for y in 0..<16 { for x in 0..<16 {
            let i = (y * 16 + x) * 4
            pixels[i + (y < 8 ? 0 : 2)] = .max
            pixels[i + 3] = .max
        } }
        pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 128) }

        let displayDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 16, height: 16, mipmapped: false)
        displayDesc.storageMode = .shared
        displayDesc.usage = [.renderTarget, .shaderRead]
        let display = try XCTUnwrap(device.makeTexture(descriptor: displayDesc))
        let library = try XCTUnwrap(device.makeDefaultLibrary())
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = library.makeFunction(name: "pocketVertex")
        pipelineDesc.fragmentFunction = library.makeFunction(name: "pocketFragment")
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = display
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
        var scale = SIMD2<Float>(1, 1)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commands.commit(); commands.waitUntilCompleted()
        XCTAssertNil(commands.error)
        var canvas = [UInt8](repeating: 0, count: 16 * 16 * 4)
        canvas.withUnsafeMutableBytes { display.getBytes($0.baseAddress!, bytesPerRow: 64,
            from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0) }

        let jpegData = try engine.jpeg(FilmFrame(texture: source, elapsedMS: 0, colorSpace: FilmEngine.outputSpace))
        let jpeg = try XCTUnwrap(CIImage(data: jpegData))
        var exported = [UInt8](repeating: 0, count: 16 * 16 * 4)
        exported.withUnsafeMutableBytes { engine.context.render(jpeg, toBitmap: $0.baseAddress!, rowBytes: 64,
            bounds: CGRect(x: 0, y: 0, width: 16, height: 16), format: .RGBA8, colorSpace: FilmEngine.outputSpace) }
        // JPEG is lossy; compare interior patches, not the red/blue boundary.
        for y in [2, 13] {
            let i = (y * 16 + 8) * 4
            XCTAssertEqual(Double(canvas[i + 2]), Double(exported[i]), accuracy: 12)
            XCTAssertEqual(Double(canvas[i]), Double(exported[i + 2]), accuracy: 12)
        }
        XCTAssertGreaterThan(canvas[(2 * 16 + 8) * 4 + 2], canvas[(2 * 16 + 8) * 4])
    }

    func testUndecodableOriginalRemainsAvailable() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let original = Data("not-a-valid-dng".utf8)
        let item = try CaptureStore.prepare(raw: original, recipe: FilmRecipe(), baseDirectory: scratch)
        XCTAssertThrowsError(try FilmEngine.validateRAW(item.source))
        XCTAssertEqual(try Data(contentsOf: item.source), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.recipeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.jpeg.path))
    }

    func testFilmBorderResultSheetReadsTheExactSavedJPEG() throws {
        let engine = try FilmEngine()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var recipe = FilmRecipe()
        recipe.grain = false; recipe.halation = false
        recipe.border.enabled = true
        let rawBytes = Data("preserved-original".utf8)
        let item = try CaptureStore.prepare(raw: rawBytes, recipe: recipe, baseDirectory: scratch)
        let red = CIImage(color: CIColor(red: 0.8, green: 0.1, blue: 0.05))
            .cropped(to: CGRect(x: 0, y: 120, width: 320, height: 120))
        let blue = CIImage(color: CIColor(red: 0.05, green: 0.1, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 120))
        let frame = try engine.render(red.composited(over: blue), recipe: recipe, preview: false)
        let crop = recipe.border.cropRect(in: CGRect(x: 0, y: 0, width: 320, height: 240))
        XCTAssertTrue(frame.texture.width > Int(crop.width) || frame.texture.height > Int(crop.height))
        let exported = try engine.jpeg(frame)
        try exported.write(to: item.jpeg, options: .atomic)
        try CaptureStore.write(recipe: recipe, for: item)
        // The result sheet uses UIImage(contentsOfFile:); Photos and ShareLink
        // consume this very file, without a separate border or display render.
        let displayed = try XCTUnwrap(UIImage(contentsOfFile: item.jpeg.path)?.cgImage)
        let savedSource = try XCTUnwrap(CGImageSourceCreateWithURL(item.jpeg as CFURL, nil))
        let saved = try XCTUnwrap(CGImageSourceCreateImageAtIndex(savedSource, 0, nil))
        XCTAssertEqual(displayed.width, frame.texture.width)
        XCTAssertEqual(displayed.height, frame.texture.height)
        XCTAssertEqual(saved.width, displayed.width)
        XCTAssertEqual(saved.height, displayed.height)
        XCTAssertEqual(try Data(contentsOf: item.jpeg), exported)
        XCTAssertTrue(CaptureStore.isCurrent(item, recipe: recipe))
        XCTAssertEqual(try Data(contentsOf: item.source), rawBytes)
    }
}
