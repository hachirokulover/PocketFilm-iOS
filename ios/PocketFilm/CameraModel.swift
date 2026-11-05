import SwiftUI
import Observation
import UIKit
import AVFoundation

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
    private let camera = CameraService()
    private let worker = RenderWorker()
    private var active = false
    var guide = CompositionGuide.thirds
    var apertureSelection: Double = 0
    var isSwitchingLens = false
    var captureSession: AVCaptureSession { camera.session }

    init() {
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
        captures = CaptureStore.recent()
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

    func updateRecipe() {
        if let stock = stocks.first(where: { $0.id == recipe.film }) {
            recipe.paper = stock.paper
            recipe.monochrome = stock.monochrome
        }
    }

    func setActive(_ value: Bool) {
        // App-hosted tests must not ask for camera permission or capture frames.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        active = value
        if value { camera.start() } else { camera.stop() }
    }

    func capture() {
        guard canCapture else { return }
        beginProcessing("正在拍摄 RAW…")
        recipe.border.frameSeed = Int.random(in: 1...Int(Int32.max))
        let snapshot = recipe
        camera.capture(preferProRAW: preferProRAW) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let bytes):
                    self.status = "正在保存原片并进行胶片显影…"
                    self.worker.capture(raw: bytes, recipe: snapshot, completion: self.completion())
                case .failure(let error): self.finish(nil, result: .failure(error))
                }
            }
        }
    }

    func importRAW(_ url: URL) {
        guard engineReady, !isProcessing else { return }
        beginProcessing("正在导入并显影 RAW…")
        recipe.border.frameSeed = Int.random(in: 1...Int(Int32.max))
        worker.importRAW(url, recipe: recipe, completion: completion())
    }

    func reprocess(_ item: CaptureItem) {
        guard engineReady, !isProcessing else { return }
        beginProcessing("正在用当前设置重新显影…")
        worker.reprocess(item, recipe: recipe, completion: completion())
    }

    // Save the recipe currently shown in the sheet, even if the user has not
    // pressed the separate preview/redevelop button. Never export a stale JPEG
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
                    self.finish(saved, result: result)
                    self.beginProcessing("正在保存原片与当前成片…")
                    self.writeToPhotos(item, completion: completion)
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
                case .success: self?.status = "原始 RAW 与当前胶片成片已保存到相册"
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
        captures = CaptureStore.recent()
        if let item { selectedCapture = item }
        switch result {
        case .success(let frame):
            imageRevision += 1
            status = String(format: "显影完成 · %d×%d · 引擎 %.0f ms",
                            frame.texture.width, frame.texture.height, frame.elapsedMS)
            showingResult = true
        case .failure(let error):
            status = item == nil ? "拍摄未完成" : "原片已保留，可以重新显影"
            errorMessage = error.localizedDescription
            // Make a preserved RAW accessible even when its first decode fails.
            if item != nil { showingResult = true }
        }
    }

    func show(_ item: CaptureItem) {
        if let saved = CaptureStore.readRecipe(for: item) { recipe = saved }
        selectedCapture = item
        imageRevision += 1
        status = "已打开本地底片，可调整片边后重新显影或保存"
        showingResult = true
    }
    func closeResult() { showingResult = false }
    func memoryWarning() { worker.memoryWarning() }
    func selectLens(_ id: String) {
        guard !isProcessing, !isSwitchingLens else { return }
        isSwitchingLens = true
        camera.selectLens(id)
    }
    func changeAperture() { camera.setAperture(apertureSelection == 0 ? nil : apertureSelection) }
}
