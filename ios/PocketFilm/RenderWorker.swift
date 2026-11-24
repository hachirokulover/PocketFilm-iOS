import AVFoundation
import CoreImage
import UniformTypeIdentifiers

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

    func capture(raw: Data, recipe: FilmRecipe, capturedAt: Date = Date(),
                 completion: @escaping (CaptureItem?, Result<FilmFrame, Error>) -> Void) {
        queue.async {
            autoreleasepool {
                var item: CaptureItem?
                let result = Result<FilmFrame, Error> {
                    let saved = try CaptureStore.prepare(raw: raw, recipe: recipe, capturedAt: capturedAt)
                    item = saved
                    let (updated, frame) = try self.develop(saved, recipe: recipe)
                    item = updated
                    return frame
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
                DispatchQueue.main.async {
                    switch result {
                    case .success(let (updated, frame)): completion(updated, .success(frame))
                    case .failure(let error): completion(item, .failure(error))
                    }
                }
            }
        }
    }

    func importImage(_ url: URL, requiresRAW: Bool, recipe: FilmRecipe, importedAt: Date,
                   completion: @escaping (CaptureItem?, Result<FilmFrame, Error>) -> Void) {
        queue.async {
            autoreleasepool {
                var item: CaptureItem?
                let result = Result<FilmFrame, Error> {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard let type = FilmEngine.imageType(url) else {
                        throw PocketFailure.message("系统无法识别这份图像文件。")
                    }
                    guard !requiresRAW || type.conforms(to: .rawImage) else {
                        throw PocketFailure.message("未收到 RAW 原片。请将原始 RAW 保存到“文件”，再从 PocketFilm 导入。")
                    }
                    let saved = try CaptureStore.copyImportedImage(url, type: type, recipe: recipe, importedAt: importedAt)
                    item = saved
                    let (updated, frame) = try self.develop(saved, recipe: recipe)
                    item = updated
                    return frame
                }
                let saved = item
                DispatchQueue.main.async { completion(saved, result) }
            }
        }
    }

    private func develop(_ item: CaptureItem, recipe: FilmRecipe) throws -> (CaptureItem, FilmFrame) {
        let engine = try getEngine()
        let temperature = recipe.automaticWhiteBalance ? nil : recipe.temperature
        let source = item.isRAW
            ? try engine.decodeRAW(item.source, maxEdge: recipe.processingEdge, temperature: temperature)
            : try FilmEngine.decodePhoto(item.source, maxEdge: recipe.processingEdge, temperature: temperature)
        let result = try engine.render(source, recipe: recipe, preview: false)
        let encoded = try engine.encode(result, settings: recipe.export)
        let updated = try CaptureStore.writeDevelopedImage(encoded, recipe: recipe, for: item)
        // A missing thumbnail must not turn an otherwise saved photo into an
        // error. The library can retry its bounded ImageIO preview later.
        try? CaptureStore.updateThumbnail(for: updated)
        return (updated, result)
    }

    func loadLibrary(completion: @escaping ([CaptureItem]) -> Void) {
        queue.async {
            let items = CaptureStore.recent()
            DispatchQueue.main.async { completion(items) }
        }
    }

    func delete(_ items: [CaptureItem], completion: @escaping (Result<Void, Error>, [CaptureItem]) -> Void) {
        // Shares the renderer's queue: a deleted RAW cannot be written back by
        // a pending develop. CameraModel also blocks deletion during Photos IO.
        queue.async {
            let result = Result { try CaptureStore.delete(items) }
            let remaining = CaptureStore.recent()
            DispatchQueue.main.async { completion(result, remaining) }
        }
    }

    func memoryWarning() {
        queue.async { self.engine?.clearCaches() }
    }
}
