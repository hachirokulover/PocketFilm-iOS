import SwiftUI
import MetalKit

struct MetalPreview: UIViewRepresentable {
    let frame: FilmFrame?
    @Binding var displayError: String?

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.layer.isOpaque = true
        (view.layer as? CAMetalLayer)?.colorspace = FilmEngine.outputSpace
        do { try context.coordinator.configure(view) }
        catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { displayError = message }
        }
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.frame = frame
        view.setNeedsDisplay()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var frame: FilmFrame?
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        // A drawable never reuses an engine result: its +1 texture is held
        // through GPU completion even if a new preview arrives meanwhile.
        func configure(_ view: MTKView) throws {
            guard let device = view.device, let library = device.makeDefaultLibrary(),
                  let vertex = library.makeFunction(name: "pocketVertex"),
                  let fragment = library.makeFunction(name: "pocketFragment"),
                  let queue = device.makeCommandQueue() else {
                throw PocketFailure.message("无法加载取景显示着色器。")
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertex
            desc.fragmentFunction = fragment
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            self.queue = queue
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
                  let cb = queue?.makeCommandBuffer(), let encoder = cb.makeRenderCommandEncoder(descriptor: pass)
            else { return }
            let held = frame
            if let frame = held, let pipeline, view.drawableSize.height > 0 {
                let sourceAspect = Float(frame.texture.width) / Float(frame.texture.height)
                let viewAspect = Float(view.drawableSize.width / view.drawableSize.height)
                var scale = SIMD2<Float>(min(1, sourceAspect / viewAspect), min(1, viewAspect / sourceAspect))
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                encoder.setFragmentTexture(frame.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            encoder.endEncoding()
            cb.present(drawable)
            cb.addCompletedHandler { _ in withExtendedLifetime(held) {} }
            cb.commit()
        }
    }
}
