import AVFoundation
import CoreImage

final class RenderWorker {
    private let queue = DispatchQueue(label: "org.pocketfilm.render", qos: .userInitiated)
    private var engine: FilmEngine?

    func warmUp(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = Result { try self.getEngine().warmUp(FilmRecipe()) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func getEngine() throws -> FilmEngine {
        if let engine { return engine }
        let created = try FilmEngine()
        engine = created
        return created
    }

    func capture(raw: Data, recipe: FilmRecipe, completion: @escaping (CaptureItem?, Result<FilmFrame, Error>) -> Void) {
        queue.async {
            autoreleasepool {
                var item: CaptureItem?
                let result = Result<FilmFrame, Error> {
                    let saved = try CaptureStore.prepare(raw: raw, recipe: recipe)
                    item = saved
                    return try self.develop(saved, recipe: recipe)
                }
                let saved = item
                DispatchQueue.main.async { completion(saved, result) }
            }
        }
    }

    func reprocess(_ item: CaptureItem, recipe: FilmRecipe,
                   completion: @escaping (CaptureItem?, Result<FilmFrame, Error>) -> Void) {
        queue.async {
            autoreleasepool {
                let result = Result { try self.develop(item, recipe: recipe) }
                DispatchQueue.main.async { completion(item, result) }
            }
        }
    }

    func importRAW(_ url: URL, recipe: FilmRecipe,
                   completion: @escaping (CaptureItem?, Result<FilmFrame, Error>) -> Void) {
        queue.async {
            autoreleasepool {
                var item: CaptureItem?
                let result = Result<FilmFrame, Error> {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let bytes = try Data(contentsOf: url)
                    let saved = try CaptureStore.prepare(raw: bytes, recipe: recipe, ext: url.pathExtension)
                    item = saved
                    return try self.develop(saved, recipe: recipe)
                }
                let saved = item
                DispatchQueue.main.async { completion(saved, result) }
            }
        }
    }

    private func develop(_ item: CaptureItem, recipe: FilmRecipe) throws -> FilmFrame {
        try FilmEngine.validateRAW(item.source)
        let engine = try getEngine()
        let source = try engine.decodeRAW(item.source, maxEdge: recipe.processingEdge,
            temperature: recipe.automaticWhiteBalance ? nil : recipe.temperature)
        let result = try engine.render(source, recipe: recipe, preview: false)
        let jpeg = try engine.jpeg(result)
        // Write the new recipe only after a successful render. Existing files
        // survive failed reprocessing; the original RAW is never overwritten.
        try jpeg.write(to: item.jpeg, options: .atomic)
        try CaptureStore.write(recipe: recipe, for: item)
        return result
    }

    func memoryWarning() {
        queue.async { self.engine?.clearCaches() }
    }
}
