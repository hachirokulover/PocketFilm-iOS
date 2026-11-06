import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers

struct CaptureItem: Identifiable {
    let folder: URL
    let source: URL
    let jpeg: URL
    let capturedAt: Date
    let displayName: String
    init(folder: URL, source: URL, jpeg: URL, capturedAt: Date = Date(), displayName: String? = nil) {
        self.folder = folder
        self.source = source
        self.jpeg = jpeg
        self.capturedAt = capturedAt
        self.displayName = displayName ?? CaptureStore.dateName(capturedAt)
    }
    var id: String { folder.lastPathComponent }
    var recipeURL: URL { folder.appendingPathComponent("recipe.json") }
    var thumbnailURL: URL { folder.appendingPathComponent("thumbnail.jpg") }
    var shareURLs: [URL] {
        [source, jpeg, recipeURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum CaptureStore {
    private struct CaptureInfo: Codable {
        let capturedAt: Date
        let displayName: String
    }
    private static let allocationLock = NSLock()
    private static let thumbnailLock = NSLock()
    private static let thumbnailQueue = DispatchQueue(label: "org.pocketfilm.thumbnails", qos: .utility)

    static func dateName(_ date: Date, filename: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = filename ? "yyyy-MM-dd_HH-mm-ss-SSS" : "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
    }

    static func prepare(raw: Data, recipe: FilmRecipe, ext: String = "dng", baseDirectory: URL? = nil,
                        capturedAt: Date = Date()) throws -> CaptureItem {
        let folder = try allocateFolder(in: baseDirectory ?? root, date: capturedAt)
        let stem = folder.lastPathComponent
        let source = folder.appendingPathComponent(stem + "_RAW").appendingPathExtension(ext)
        // Original first: decoding, rendering, Photos permission, and export
        // can all fail without losing the camera's DNG.
        try raw.write(to: source, options: .atomic)
        let item = CaptureItem(folder: folder, source: source,
            jpeg: folder.appendingPathComponent(stem + "_Film.jpg"), capturedAt: capturedAt)
        let info = CaptureInfo(capturedAt: capturedAt, displayName: item.displayName)
        try JSONEncoder().encode(info).write(to: folder.appendingPathComponent("capture.json"), options: .atomic)
        try write(recipe: recipe, for: item)
        return item
    }

    private static func allocateFolder(in root: URL, date: Date) throws -> URL {
        // Prevent two saves with the same timestamp from sharing/overwriting files.
        allocationLock.lock()
        defer { allocationLock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let name = dateName(date, filename: true)
        var index = 1
        var folder = root.appendingPathComponent(name, isDirectory: true)
        while fm.fileExists(atPath: folder.path) {
            index += 1
            folder = root.appendingPathComponent(name + "_\(index)", isDirectory: true)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
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

    static func recent(baseDirectory: URL? = nil) -> [CaptureItem] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: baseDirectory ?? root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) else { return [] }
        return folders.compactMap { folder -> CaptureItem? in
            guard let values = try? folder.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: nil),
                  let source = files.first(where: {
                      let name = $0.deletingPathExtension().lastPathComponent
                      return name == "source" || name == folder.lastPathComponent + "_RAW"
                  })
            else { return nil }
            let info = (try? Data(contentsOf: folder.appendingPathComponent("capture.json")))
                .flatMap { try? JSONDecoder().decode(CaptureInfo.self, from: $0) }
            let legacy = source.deletingPathExtension().lastPathComponent == "source"
            let jpeg = folder.appendingPathComponent(legacy ? "film.jpg" : folder.lastPathComponent + "_Film.jpg")
            return CaptureItem(folder: folder, source: source, jpeg: jpeg,
                capturedAt: info?.capturedAt ?? values.creationDate ?? .distantPast, displayName: info?.displayName)
        }.sorted {
            $0.capturedAt == $1.capturedAt ? $0.id > $1.id : $0.capturedAt > $1.capturedAt
        }
    }

    static func delete(_ items: [CaptureItem], baseDirectory: URL? = nil) throws {
        let parent = (baseDirectory ?? root).standardizedFileURL
        let folders = Array(Set(items.map { $0.folder.standardizedFileURL }))
        for folder in folders {
            // Only direct, real capture folders. Never remove the library root,
            // a path outside it, or follow a substituted symbolic-link directory.
            guard folder.deletingLastPathComponent().path == parent.path,
                  folder.resolvingSymlinksInPath().deletingLastPathComponent().path == parent.resolvingSymlinksInPath().path,
                  let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else {
                throw PocketFailure.message("无法删除：底片目录不存在或不属于本地底片库。")
            }
        }
        // Reject an unsafe batch before removing any of its valid entries.
        for folder in folders { try FileManager.default.removeItem(at: folder) }
    }

    // Downsample with ImageIO off main; never decode full RAW just for a row.
    static func thumbnailData(for item: CaptureItem) async -> Data? {
        await withCheckedContinuation { continuation in
            thumbnailQueue.async {
                let bytes: Data? = autoreleasepool { try? thumbnail(item) }
                continuation.resume(returning: bytes)
            }
        }
    }

    static func updateThumbnail(for item: CaptureItem) throws {
        _ = try thumbnail(item, force: true)
    }

    private static func thumbnail(_ item: CaptureItem, force: Bool = false) throws -> Data? {
        thumbnailLock.lock()
        defer { thumbnailLock.unlock() }
        let fm = FileManager.default
        // Do not recreate a deleted parent when an old row's task completes.
        guard fm.fileExists(atPath: item.folder.path) else { return nil }
        let hasJPEG = fm.fileExists(atPath: item.jpeg.path)
        let input = hasJPEG ? item.jpeg : item.source
        let sourceDate = (try? input.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
        let cachedDate = (try? item.thumbnailURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if !force, cachedDate >= sourceDate, let bytes = try? Data(contentsOf: item.thumbnailURL) { return bytes }
        if fm.fileExists(atPath: item.thumbnailURL.path) { try fm.removeItem(at: item.thumbnailURL) }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: hasJPEG,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: hasJPEG,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 384,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let bytes = data as Data
        try bytes.write(to: item.thumbnailURL, options: .atomic)
        return bytes
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
