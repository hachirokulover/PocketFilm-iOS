import SwiftUI
import Observation
import UIKit
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

@Observable @MainActor
final class CameraModel {
    var recipe = FilmRecipe()
    var preferProRAW = true
    var capabilities: CameraCapabilities?
    var isProcessing = false
    var engineReady = false
    var status = "正在初始化胶片引擎…"
    var errorMessage: String?
    var captures: [CaptureItem] = []
    var selectedCapture: CaptureItem?
    var showingResult = false
    var imageRevision = 0
    let stocks = FilmStock.bundled()
    let fotufilmStocks = FotufilmStock.bundled
    var selectedFilmName: String {
        if recipe.usesFotufilm {
            return fotufilmStocks.first { $0.recipeID == recipe.film }?.name ?? recipe.film
        }
        return stocks.first { $0.id == recipe.film }?.name ?? recipe.film
    }
    private let camera = CameraService()
    private let worker = RenderWorker()
    private var active = false
    private var libraryGeneration = 0
    private var captureRotationAngle: CGFloat = 90
    @ObservationIgnored private var orientationObserver: NSObjectProtocol?
    var guide = CompositionGuide.thirds
    var apertureSelection: Double = 0
    var isSwitchingLens = false
    var captureSession: AVCaptureSession { camera.session }

    init() {
        orientationObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshOrientation() }
            }
        camera.onState = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .success(let caps):
                    if self.capabilities?.selectedLensID != caps.selectedLensID { self.apertureSelection = 0 }
                    self.isSwitchingLens = false
                    self.capabilities = caps
                    if !caps.supportsProRAW { self.preferProRAW = false }
                    if !caps.supportsBayer, caps.supportsProRAW { self.preferProRAW = true }
                    if !self.isProcessing && !self.showingResult { self.status = caps.summary }
                case .failure(let error): self.isSwitchingLens = false; self.errorMessage = error.localizedDescription
                }
            }
        }
        camera.onInterrupted = { [weak self] text in
            Task { @MainActor in self?.status = text }
        }
        refreshLibrary()
        worker.warmUp { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success: self?.engineReady = true; self?.status = "胶片引擎已就绪"
                case .failure(let error): self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    var canCapture: Bool {
        guard active, engineReady, !isProcessing, !showingResult, !isSwitchingLens, let caps = capabilities else { return false }
        return preferProRAW ? caps.supportsProRAW : caps.supportsBayer
    }

    func selectFilm(_ id: String) {
        if let stock = stocks.first(where: { $0.id == id }) {
            recipe.film = id
            recipe.paper = stock.paper
            recipe.monochrome = stock.monochrome
        } else if fotufilmStocks.contains(where: { $0.recipeID == id }) {
            recipe.film = id
            recipe.paper = ""
            recipe.monochrome = false
        }
    }

    func setActive(_ value: Bool) {
        // App-hosted tests must not ask for camera permission or capture frames.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        if value != active {
            if value { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
            else { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        }
        active = value
        if value { refreshOrientation() }
        if value { camera.start() } else { camera.stop() }
    }

    func capture() {
        guard canCapture else { return }
        refreshOrientation()
        beginProcessing("正在拍摄 RAW…")
        recipe.border.frameSeed = Int.random(in: 1...Int(Int32.max))
        let snapshot = recipe
        let capturedAt = Date()
        camera.capture(preferProRAW: preferProRAW, rotationAngle: captureRotationAngle) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let bytes):
                    self.status = "正在保存原片并进行胶片显影…"
                    self.worker.capture(raw: bytes, recipe: snapshot, capturedAt: capturedAt, completion: self.completion())
                case .failure(let error): self.finish(nil, result: .failure(error))
                }
            }
        }
    }

    func importRAW(_ url: URL) {
        guard engineReady, !isProcessing else { return }
        beginProcessing("正在导入并显影 RAW…")
        recipe.border.frameSeed = Int.random(in: 1...Int(Int32.max))
        worker.importImage(url, requiresRAW: true, recipe: recipe, importedAt: Date(), completion: completion())
    }

    func importPhoto(_ selection: PhotosPickerItem) async {
        guard engineReady, !isProcessing else { return }
        beginProcessing("正在从相册读取原片…")
        recipe.border.frameSeed = Int.random(in: 1...Int(Int32.max))
        let snapshot = recipe
        let importedAt = Date()
        let requiresRAW = selection.supportedContentTypes.contains { $0.conforms(to: .rawImage) }
        do {
            guard let photo = try await selection.loadTransferable(type: PickedPhoto.self) else {
                let message = requiresRAW
                    ? "相册未提供 RAW 文件。可把 RAW 原片存到“文件”后重试。"
                    : "相册未提供此照片的图像文件。"
                throw PocketFailure.message(message)
            }
            status = "正在导入并显影照片…"
            let finishImport = completion()
            worker.importImage(photo.url, requiresRAW: requiresRAW, recipe: snapshot, importedAt: importedAt) { item, result in
                withExtendedLifetime(photo) { finishImport(item, result) }
            }
        } catch {
            isProcessing = false
            status = "相册导入未完成"
            errorMessage = error.localizedDescription
        }
    }

    func reprocess(_ item: CaptureItem) {
        guard engineReady, !isProcessing else { return }
        beginProcessing("正在用当前设置重新显影…")
        worker.reprocess(item, recipe: recipe, completion: completion())
    }

    // Save the recipe currently shown in the sheet, even if the user has not
    // pressed the separate preview/redevelop button. Never export a stale image
    // after a failed render. Keep controls locked until Photos consumes files.
    func saveToPhotos(_ item: CaptureItem, completion: @escaping (Result<Void, Error>) -> Void) {
        guard engineReady, !isProcessing else { return }
        let snapshot = recipe
        beginProcessing("正在准备保存…")
        if CaptureStore.isCurrent(item, recipe: snapshot) {
            writeToPhotos(item, completion: completion)
            return
        }
        worker.reprocess(item, recipe: snapshot) { [weak self] saved, result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    guard let saved, CaptureStore.isCurrent(saved, recipe: snapshot) else {
                        let error = PocketFailure.message("未找到应用当前设置的成片，请重新显影。")
                        self.finish(saved ?? item, result: .failure(error))
                        completion(.failure(error))
                        return
                    }
                    self.finish(saved, result: result)
                    self.beginProcessing("正在保存原片与当前成片…")
                    self.writeToPhotos(saved, completion: completion)
                case .failure(let error):
                    self.finish(saved, result: result)
                    completion(.failure(error))
                }
            }
        }
    }

    private func writeToPhotos(_ item: CaptureItem, completion: @escaping (Result<Void, Error>) -> Void) {
        CaptureStore.saveToPhotos(item) { [weak self] result in
            Task { @MainActor in
                self?.isProcessing = false
                switch result {
                case .success: self?.status = item.isRAW ? "原始 RAW 与胶片成片已保存到相册" : "胶片成片已保存到相册"
                case .failure: self?.status = "保存相册未完成，本地文件已保留"
                }
                completion(result)
            }
        }
    }

    private func completion() -> (CaptureItem?, Result<FilmFrame, Error>) -> Void {
        { [weak self] item, result in
            Task { @MainActor in self?.finish(item, result: result) }
        }
    }

    private func beginProcessing(_ text: String) {
        isProcessing = true
        status = text
    }

    private func finish(_ item: CaptureItem?, result: Result<FilmFrame, Error>) {
        isProcessing = false
        refreshLibrary()
        if let item { selectedCapture = item }
        switch result {
        case .success(let frame):
            imageRevision += 1
            status = String(format: "显影完成 · %d×%d · 引擎 %.0f ms",
                            frame.texture.width, frame.texture.height, frame.elapsedMS)
            showingResult = true
        case .failure(let error):
            status = item == nil ? "未能完成原片处理" : "原片已保留，可以重新显影"
            errorMessage = error.localizedDescription
            // Make a preserved RAW accessible even when its first decode fails.
            if item != nil { showingResult = true }
        }
    }

    func show(_ item: CaptureItem) {
        if let saved = CaptureStore.readRecipe(for: item) { recipe = saved }
        selectedCapture = item
        imageRevision += 1
        status = "已打开本地底片，可调整显影与导出设置"
        showingResult = true
    }
    func refreshLibrary() {
        libraryGeneration += 1
        let generation = libraryGeneration
        worker.loadLibrary { [weak self] items in
            Task { @MainActor in
                guard let self, self.libraryGeneration == generation else { return }
                self.captures = items
            }
        }
    }
    func deleteCaptures(_ items: [CaptureItem], completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        guard !isProcessing, !items.isEmpty else { return }
        libraryGeneration += 1
        beginProcessing("正在删除本地底片…")
        worker.delete(items) { [weak self] result, remaining in
            Task { @MainActor in
                guard let self else { return }
                self.libraryGeneration += 1
                self.captures = remaining
                self.isProcessing = false
                if let selected = self.selectedCapture, !remaining.contains(where: { $0.id == selected.id }) {
                    self.selectedCapture = nil
                    self.showingResult = false
                }
                switch result {
                case .success: self.status = "已删除所选本地底片"
                case .failure(let error):
                    self.status = "部分底片未删除，请重试"
                    self.status += "：\(error.localizedDescription)"
                }
                completion(result)
            }
        }
    }
    func closeResult() { showingResult = false }
    func memoryWarning() { worker.memoryWarning() }
    func selectLens(_ id: String) {
        guard !isProcessing, !isSwitchingLens else { return }
        isSwitchingLens = true
        camera.selectLens(id)
    }
    func changeAperture() { camera.setAperture(apertureSelection == 0 ? nil : apertureSelection) }
    private func refreshOrientation() {
        captureRotationAngle = CameraOrientation.captureAngle(for: UIDevice.current.orientation, fallback: captureRotationAngle)
    }
    func focus(at point: CGPoint) {
        guard active, !isProcessing, !isSwitchingLens, !showingResult else { return }
        camera.focus(at: point)
    }
    deinit {
        if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
    }
}
