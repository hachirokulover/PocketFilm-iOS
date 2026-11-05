import Foundation
import Photos

struct CaptureItem: Identifiable {
    let folder: URL
    let source: URL
    let jpeg: URL
    var id: String { folder.lastPathComponent }
    var recipeURL: URL { folder.appendingPathComponent("recipe.json") }
    var shareURLs: [URL] {
        [source, jpeg, recipeURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum CaptureStore {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
    }

    static func prepare(raw: Data, recipe: FilmRecipe, ext: String = "dng", baseDirectory: URL? = nil) throws -> CaptureItem {
        let folder = (baseDirectory ?? root).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("source").appendingPathExtension(ext)
        // Original first: decoding, rendering, Photos permission, and export
        // can all fail without losing the camera's DNG.
        try raw.write(to: source, options: .atomic)
        let item = CaptureItem(folder: folder, source: source,
                               jpeg: folder.appendingPathComponent("film.jpg"))
        try write(recipe: recipe, for: item)
        return item
    }

    static func write(recipe: FilmRecipe, for item: CaptureItem) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recipe).write(to: item.recipeURL, options: .atomic)
    }

    static func readRecipe(for item: CaptureItem) -> FilmRecipe? {
        guard let data = try? Data(contentsOf: item.recipeURL) else { return nil }
        return try? JSONDecoder().decode(FilmRecipe.self, from: data)
    }

    static func isCurrent(_ item: CaptureItem, recipe: FilmRecipe) -> Bool {
        FileManager.default.fileExists(atPath: item.jpeg.path) && readRecipe(for: item) == recipe
    }

    static func recent() -> [CaptureItem] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) else { return [] }
        return folders.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }.compactMap { folder in
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: nil),
                  let source = files.first(where: { $0.deletingPathExtension().lastPathComponent == "source" })
            else { return nil }
            return CaptureItem(folder: folder, source: source, jpeg: folder.appendingPathComponent("film.jpg"))
        }
    }

    // Two independent assets: Photos displays the finished film JPEG directly.
    // A RAW+alternatePhoto pair can otherwise default to the RAW's own preview.
    static func saveToPhotos(_ item: CaptureItem, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(.failure(PocketFailure.message("没有相册写入权限；RAW 和成片仍保存在应用内，可分享导出。")))
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let raw = PHAssetCreationRequest.forAsset()
                raw.addResource(with: .photo, fileURL: item.source, options: nil)
                let processed = PHAssetCreationRequest.forAsset()
                processed.addResource(with: .photo, fileURL: item.jpeg, options: nil)
            } completionHandler: { ok, error in
                if ok { completion(.success(Void())) }
                else { completion(.failure(error ?? PocketFailure.message("保存相册失败；本地文件已保留。"))) }
            }
        }
    }
}
