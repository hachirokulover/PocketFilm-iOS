import Foundation
import CoreGraphics
import Metal

struct FotufilmStock: Decodable, Identifiable {
    let id: String
    let name: String

    static let prefix = "fotufilm:"
    var recipeID: String { Self.prefix + id }

    private struct Catalogue: Decodable {
        let dimension: Int
        let stocks: [FotufilmStock]
    }

    static let dimension = 33
    static let resources = Bundle.main.resourceURL?.appendingPathComponent("Fotufilm", isDirectory: true)

    static let bundled: [FotufilmStock] = {
        guard let resources,
              let bytes = try? Data(contentsOf: resources.appendingPathComponent("catalogue.json")),
              let catalogue = try? JSONDecoder().decode(Catalogue.self, from: bytes),
              catalogue.dimension == dimension else { return [] }
        return catalogue.stocks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()
}

// Uses the same top-row-first texture convention as the Spektrafilm renderer.
final class FotufilmRenderer {
    static let inputSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let outputSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var cachedStock: String?
    private var cachedCube: MTLTexture?

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue(),
              let function = device.makeDefaultLibrary()?.makeFunction(name: "pocketFotufilm") else {
            throw PocketFailure.message("无法初始化 Fotufilm 调色。")
        }
        self.device = device
        self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)
    }

    func render(buffer: MTLBuffer, width: Int, height: Int, stock: String, exposureEV: Double) throws -> MTLTexture {
        let cube = try loadCube(stock)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let output = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw PocketFailure.message("无法分配 Fotufilm 成片所需的内存。")
        }
        var gain = Float(pow(2.0, exposureEV))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&gain, length: MemoryLayout<Float>.size, index: 1)
        encoder.setTexture(cube, index: 0)
        encoder.setTexture(output, index: 1)
        let groupWidth = pipeline.threadExecutionWidth
        let groupHeight = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / groupWidth))
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + groupWidth - 1) / groupWidth,
                    height: (height + groupHeight - 1) / groupHeight, depth: 1),
            threadsPerThreadgroup: MTLSize(width: groupWidth, height: groupHeight, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw PocketFailure.message(command.error?.localizedDescription ?? "Fotufilm 调色未完成。")
        }
        return output
    }

    private func loadCube(_ recipeID: String) throws -> MTLTexture {
        if cachedStock == recipeID, let cachedCube { return cachedCube }
        guard let stock = FotufilmStock.bundled.first(where: { $0.recipeID == recipeID }),
              let resources = FotufilmStock.resources else {
            throw PocketFailure.message("找不到此 Fotufilm 配方，请选择其他胶片。")
        }
        let dimension = FotufilmStock.dimension
        let bytesPerRow = dimension * 8
        let bytesPerImage = bytesPerRow * dimension
        let bytes = try Data(contentsOf: resources.appendingPathComponent(stock.id + ".rgba16f"))
        guard bytes.count == bytesPerImage * dimension else {
            throw PocketFailure.message("Fotufilm 配方数据损坏，请重新安装应用。")
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = dimension
        descriptor.height = dimension
        descriptor.depth = dimension
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let cube = device.makeTexture(descriptor: descriptor) else {
            throw PocketFailure.message("无法读取 Fotufilm 调色表。")
        }
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            cube.replace(region: MTLRegionMake3D(0, 0, 0, dimension, dimension, dimension),
                         mipmapLevel: 0, slice: 0, withBytes: raw.baseAddress!,
                         bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
        }
        cachedStock = recipeID
        cachedCube = cube
        return cube
    }
}
