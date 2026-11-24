import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FilmFrame {
    let texture: MTLTexture
    let elapsedMS: Double
    let colorSpace: CGColorSpace
}

// Access only on CameraModel.renderQueue. The C ABI's errors are thread-local;
// a serial queue also keeps preview and photo sessions off the GPU together.
final class FilmEngine {
    let device: MTLDevice
    let context: CIContext
    private let handle: OpaquePointer
    static let outputSpace = ExportColorSpace.sRGB.colorSpace
    static let linearProPhoto: CGColorSpace = {
        let white: [CGFloat] = [0.9642, 1, 0.8249]
        let black: [CGFloat] = [0, 0, 0]
        let gamma: [CGFloat] = [1, 1, 1]
        let matrix: [CGFloat] = [0.7976749, 0.2880402, 0,
                                 0.1351917, 0.7118741, 0,
                                 0.0313534, 0.0000857, 0.8252100]
        return white.withUnsafeBufferPointer { w in
            black.withUnsafeBufferPointer { b in
                gamma.withUnsafeBufferPointer { g in
                    matrix.withUnsafeBufferPointer { m in
                        CGColorSpace(calibratedRGBWhitePoint: w.baseAddress!, blackPoint: b.baseAddress,
                                     gamma: g.baseAddress!, matrix: m.baseAddress)!
                    }
                }
            }
        }
    }()

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PocketFailure.message("设备无法创建 Metal 渲染器。")
        }
        self.device = device
        context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
            .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
            .highQualityDownsample: true])
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("engine"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("spektrafilm.metallib").path)
        else { throw PocketFailure.message("应用缺少 iOS Metal 内核或胶片资源，请重新编译。") }
        setenv("SPEKTRAFILM_PLANE_DIR", NSTemporaryDirectory(), 1)
        guard let engine = root.path.withCString({
            spk_engine_create($0, Unmanaged.passUnretained(device as AnyObject).toOpaque())
        }) else {
            throw PocketFailure.message(String(cString: spk_last_error(nil)))
        }
        let capabilities = String(cString: spk_capabilities(engine))
        guard let data = capabilities.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["transport_version"] as? Int == Int(SPK_TRANSPORT_VERSION),
              json["schema_version"] as? Int == Int(SPK_SCHEMA_VERSION) else {
            spk_engine_destroy(engine)
            throw PocketFailure.message("渲染引擎协议不匹配。")
        }
        handle = engine
        print("PocketFilm: core=native-metal; \(String(cString: spk_build_info()))")
    }

    deinit { spk_engine_destroy(handle) }

    func warmUp(_ recipe: FilmRecipe) throws {
        var reply: UnsafeMutablePointer<CChar>?
        defer { spk_string_free(reply) }
        try check(recipe.film.withCString { film in
            recipe.paper.withCString { spk_warm_up(handle, film, $0, &reply) }
        })
    }

    static func imageType(_ url: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image) else { return nil }
        return type
    }

    static func validateRAW(_ url: URL) throws {
        guard imageType(url)?.conforms(to: .rawImage) == true else {
            throw PocketFailure.message("文件不是系统可识别的 RAW，或文件已损坏。原始文件已保留。")
        }
    }

    static func decodePhoto(_ url: URL, maxEdge: Int, temperature: Double?) throws -> CIImage {
        guard maxEdge > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxEdge,
              ] as CFDictionary) else {
            throw PocketFailure.message("系统无法解码这张照片。原始文件已保留。")
        }
        // Preserve embedded color profiles and use sRGB for untagged photos.
        let options: [CIImageOption: Any] = [.colorSpace: bitmap.colorSpace ?? outputSpace]
        let image = CIImage(cgImage: bitmap, options: options)
        guard let temperature else { return image }
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: CGFloat(temperature), y: 0)
        filter.targetNeutral = CIVector(x: 6500, y: 0)
        return filter.outputImage ?? image
    }

    func decodeRAW(_ url: URL, maxEdge: Int, temperature: Double? = nil) throws -> CIImage {
        try Self.validateRAW(url)
        guard let raw = CIRAWFilter(imageURL: url) else {
            throw PocketFailure.message("系统无法解码这份 RAW。原始文件已保留。")
        }
        // Match SpektraLab's scene-linear decode, including the camera's
        // baseline exposure and as-shot white balance. No second gamma decode.
        raw.boostAmount = 0
        raw.boostShadowAmount = 0
        raw.isGamutMappingEnabled = false
        raw.localToneMapAmount = 0
        raw.extendedDynamicRangeAmount = 0
        raw.isDraftModeEnabled = false
        if let temperature { raw.neutralTemperature = Float(temperature) }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = true }
        let nativeEdge = max(raw.nativeSize.width, raw.nativeSize.height)
        guard nativeEdge.isFinite, nativeEdge > 0 else {
            throw PocketFailure.message("RAW 文件没有有效的图像尺寸。原始文件已保留。")
        }
        if maxEdge > 0, nativeEdge > 0 {
            raw.scaleFactor = Float(min(1, CGFloat(maxEdge) / nativeEdge))
        }
        guard let image = raw.outputImage, !image.extent.isInfinite, !image.extent.isEmpty else {
            throw PocketFailure.message("RAW 解码没有返回图像。")
        }
        return image
    }

    static func resized(_ image: CIImage, maxEdge: Int) -> CIImage {
        let extent = image.extent
        guard maxEdge > 0, !extent.isEmpty, !extent.isInfinite else { return image }
        // Compute the target before applying floating-point transforms. The
        // transformed extent can be 480.0000000001; integral then adds a pixel.
        let size = pf_resized_size(Double(extent.width), Double(extent.height), Int64(maxEdge))
        let width = CGFloat(size.width), height = CGFloat(size.height)
        let origin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaled = origin.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        return scaled.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func inputBuffer(_ image: CIImage) throws -> (MTLBuffer, Int, Int) {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty,
              extent.width <= 16384, extent.height <= 16384 else {
            throw PocketFailure.message("图像尺寸无效或过大。")
        }
        let width = Int(extent.width), height = Int(extent.height)
        let bytes = width * height * 16
        guard bytes <= device.maxBufferLength,
              let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw PocketFailure.message("图像所需内存过大，请降低输出分辨率。")
        }
        // Core Image's bitmap API writes top row first. Do not flip here.
        autoreleasepool {
            context.render(image, toBitmap: buffer.contents(), rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: Self.linearProPhoto)
        }
        return (buffer, width, height)
    }

    func render(_ source: CIImage, recipe: FilmRecipe, preview: Bool) throws -> FilmFrame {
        let start = CFAbsoluteTimeGetCurrent()
        let maxEdge = Int(pf_processing_edge(Int64(recipe.maxPhotoEdge), recipe.border.enabled, preview))
        let image = Self.resized(recipe.border.cropped(source), maxEdge: maxEdge)
        let data = try JSONEncoder().encode(recipe)
        var error: UnsafeMutablePointer<CChar>?
        defer { pf_free_string(error) }
        let opaque = try autoreleasepool {
            let (buffer, width, height) = try inputBuffer(image)
            return withExtendedLifetime(buffer) {
                data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                    recipe.border.edgeText(stock: recipe.film).withCString { text in
                        pf_render_texture(handle, Unmanaged.passUnretained(buffer as AnyObject).toOpaque(),
                            UInt32(width), UInt32(height), bytes.bindMemory(to: UInt8.self).baseAddress,
                            bytes.count, preview, text, &error)
                    }
                }
            }
        }
        guard let opaque else {
            let message = error.map { String(cString: $0) } ?? "胶片引擎无法完成显影。"
            throw PocketFailure.message(message)
        }
        let texture = Unmanaged<AnyObject>.fromOpaque(opaque).takeRetainedValue() as! MTLTexture
        return FilmFrame(texture: texture, elapsedMS: (CFAbsoluteTimeGetCurrent() - start) * 1000,
                         colorSpace: recipe.export.colorSpace.engineColorSpace)
    }

    func encode(_ frame: FilmFrame, settings: ExportSettings) throws -> Data {
        guard let image = CIImage(mtlTexture: frame.texture, options: [.colorSpace: frame.colorSpace]) else {
            throw PocketFailure.message("无法读取成片纹理。")
        }
        // Texture row zero is the top of the photograph. A CI texture image
        // uses a bottom-left origin; flip only on this route to ImageIO.
        let flipped = image.transformed(by: CGAffineTransform(translationX: 0, y: image.extent.height)
            .scaledBy(x: 1, y: -1))
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let options: [CIImageRepresentationOption: Any] = [quality: settings.compressionQuality]
        let destination = settings.colorSpace.colorSpace
        let encoded: Data?
        switch settings.format {
        case .jpeg:
            encoded = context.jpegRepresentation(of: flipped, colorSpace: destination, options: options)
        case .heif:
            encoded = context.heifRepresentation(of: flipped, format: .RGBA8, colorSpace: destination, options: options)
        }
        guard let encoded else {
            throw PocketFailure.message("无法生成 \(settings.colorSpace.title) \(settings.format.title) 成片。请尝试其他导出设置。")
        }
        guard let source = CGImageSourceCreateWithData(encoded as CFData, nil),
              let type = CGImageSourceGetType(source),
              let contentType = UTType(type as String), contentType.conforms(to: settings.format.contentType) else {
            throw PocketFailure.message("系统返回的成片格式与导出设置不一致。")
        }
        return encoded
    }

    func clearCaches() { context.clearCaches() }
    private func failure() -> PocketFailure { .message(String(cString: spk_last_error(handle))) }
    private func check(_ status: spk_status) throws {
        if status != SPK_OK { throw failure() }
    }
}
