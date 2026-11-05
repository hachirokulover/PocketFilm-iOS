import AVFoundation
import Foundation

struct CameraLens: Identifiable {
    let id: String
    let name: String
}

struct CameraCapabilities {
    let supportsBayer: Bool
    let supportsProRAW: Bool
    let photoDimensions: CMVideoDimensions
    let lenses: [CameraLens]
    let selectedLensID: String
    let apertureStops: [Double]
    let aperture: Double
    var summary: String {
        let modes = [(supportsProRAW, "ProRAW"), (supportsBayer, "Bayer RAW")].filter { $0.0 }.map { $0.1 }
        let mode = modes.isEmpty ? "不支持 RAW" : modes.joined(separator: " / ")
        return "\(mode) · \(photoDimensions.width)×\(photoDimensions.height)"
    }
}

final class CameraService: NSObject {
    var onState: ((Result<CameraCapabilities, Error>) -> Void)?
    var onInterrupted: ((String) -> Void)?
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "org.pocketfilm.camera", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private var selectedDeviceID: String?
    private var currentDevice: AVCaptureDevice?
    private var apertureObservation: NSKeyValueObservation?
    private var configured = false
    private var wantsRunning = false
    private var photoDelegates: [Int64: RAWCaptureDelegate] = [:]
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted,
            object: session, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { self?.onInterrupted?("相机被系统暂时中断，恢复后会继续取景。") }
            })
        observers.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded,
            object: session, queue: nil) { [weak self] _ in self?.start() })
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError,
            object: session, queue: nil) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
                if error?.code == .mediaServicesWereReset { self?.start() }
                else { DispatchQueue.main.async { self?.onInterrupted?(error?.localizedDescription ?? "相机运行错误。") } }
            })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func start() {
        queue.async {
            self.wantsRunning = true
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.configureAndStart()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { allowed in
                    self.queue.async {
                        if allowed, self.wantsRunning { self.configureAndStart() }
                        else if !allowed { self.fail("请在系统设置中允许相机访问。") }
                    }
                }
            default: self.fail("相机权限未开启，请到系统设置中允许访问。")
            }
        }
    }

    func stop() {
        queue.async {
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureAndStart() {
        do {
            if !configured { try configure() }
            if wantsRunning, !session.isRunning { session.startRunning() }
            let caps = capabilities()
            DispatchQueue.main.async { self.onState?(.success(caps)) }
        } catch { fail(error.localizedDescription) }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Remove partial configuration left by an earlier failed setup.
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.sessionPreset = .photo
        let devices = rearDevices()
        guard let camera = devices.first(where: { $0.uniqueID == selectedDeviceID })
            ?? devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first else {
            throw PocketFailure.message("没有可用的后置主摄；模拟器请使用 RAW 文件导入。")
        }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw PocketFailure.message("无法添加相机输入。") }
        session.addInput(input)
        guard session.canAddOutput(photoOutput) else {
            throw PocketFailure.message("无法配置 RAW 拍照。")
        }
        session.addOutput(photoOutput)
        photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported
        // Choose the largest supported size up to roughly 12 MP initially.
        // This is a capture capability query, never a hard-coded device table.
        let sizes = camera.activeFormat.supportedMaxPhotoDimensions
        let bounded = sizes.filter { Int64($0.width) * Int64($0.height) <= 13_000_000 }
        if let dimensions = (bounded.isEmpty ? sizes : bounded).max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) { photoOutput.maxPhotoDimensions = dimensions }
        photoOutput.maxPhotoQualityPrioritization = .quality
        for output in [photoOutput as AVCaptureOutput] {
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
        currentDevice = camera
        selectedDeviceID = camera.uniqueID
        // Returning to a previously used physical camera must not inherit its
        // old manual aperture while the UI displays Auto for the new selection.
        try camera.lockForConfiguration()
        if camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposureMode = .continuousAutoExposure
        }
        camera.unlockForConfiguration()
        apertureObservation = camera.observe(\.lensAperture, options: [.new]) { [weak self] _, _ in
            self?.queue.async { self?.publishCapabilities() }
        }
        configured = true
    }

    private func capabilities() -> CameraCapabilities {
        let formats = photoOutput.availableRawPhotoPixelFormatTypes
        return CameraCapabilities(supportsBayer: formats.contains(where: AVCapturePhotoOutput.isBayerRAWPixelFormat),
            supportsProRAW: formats.contains(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat),
            photoDimensions: photoOutput.maxPhotoDimensions,
            lenses: rearDevices().map { CameraLens(id: $0.uniqueID, name: Self.lensName($0.deviceType)) },
            selectedLensID: currentDevice?.uniqueID ?? "",
            apertureStops: supportedApertures(), aperture: Double(currentDevice?.lensAperture ?? 0))
    }

    private func rearDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera,
            .builtInTelephotoCamera], mediaType: .video, position: .back).devices
    }
    private static func lensName(_ type: AVCaptureDevice.DeviceType) -> String {
        if type == .builtInUltraWideCamera { return "超广角" }
        if type == .builtInTelephotoCamera { return "长焦" }
        return "广角 1×"
    }
    private func supportedApertures() -> [Double] {
        guard #available(iOS 27.0, *), let camera = currentDevice,
              camera.activeFormat.maxLensAperture > camera.activeFormat.minLensAperture else { return [] }
        return camera.activeFormat.recommendedLensApertureStops.filter {
            camera.activeFormat.supportsExposureModeCustom(lensAperture: $0,
                duration: AVCaptureDevice.autoExposureDuration, iso: AVCaptureDevice.autoISO)
        }.map(Double.init)
    }
    private func publishCapabilities() {
        guard configured else { return }
        let caps = capabilities()
        DispatchQueue.main.async { self.onState?(.success(caps)) }
    }
    func selectLens(_ id: String) {
        queue.async {
            guard self.photoDelegates.isEmpty else { return }
            self.selectedDeviceID = id
            self.configured = false
            self.apertureObservation = nil
            self.configureAndStart()
        }
    }
    func setAperture(_ value: Double?) {
        queue.async {
            guard let camera = self.currentDevice else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if let value {
                    guard #available(iOS 27.0, *), self.supportedApertures().contains(where: { abs($0-value) < 0.001 }),
                          camera.activeFormat.supportsExposureModeCustom(lensAperture: Float(value),
                            duration: AVCaptureDevice.autoExposureDuration, iso: AVCaptureDevice.autoISO) else {
                        throw PocketFailure.message("当前镜头不支持此光圈优先组合。")
                    }
                    camera.setExposureModeCustom(lensAperture: Float(value),
                        duration: AVCaptureDevice.autoExposureDuration, iso: AVCaptureDevice.autoISO,
                        completionHandler: nil)
                } else if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                self.publishCapabilities()
            } catch { self.fail(error.localizedDescription) }
        }
    }

    static func chooseRaw(_ formats: [OSType], preferProRAW: Bool,
                          isProRAW: (OSType) -> Bool, isBayer: (OSType) -> Bool) -> OSType? {
        // A requested mode is exact: don't silently replace a Bayer photograph
        // with computational ProRAW, or vice versa.
        formats.first(where: preferProRAW ? isProRAW : isBayer)
    }

    func capture(preferProRAW: Bool, completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async {
            guard self.configured, self.session.isRunning else {
                DispatchQueue.main.async { completion(.failure(PocketFailure.message("相机尚未就绪。"))) }; return
            }
            guard let raw = Self.chooseRaw(self.photoOutput.availableRawPhotoPixelFormatTypes,
                preferProRAW: preferProRAW, isProRAW: AVCapturePhotoOutput.isAppleProRAWPixelFormat,
                isBayer: AVCapturePhotoOutput.isBayerRAWPixelFormat) else {
                DispatchQueue.main.async { completion(.failure(PocketFailure.message("当前配置不支持选中的 RAW 模式。"))) }; return
            }
            let settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            settings.flashMode = .off
            let id = settings.uniqueID
            let delegate = RAWCaptureDelegate { result in
                self.queue.async {
                    self.photoDelegates.removeValue(forKey: id)
                    DispatchQueue.main.async { completion(result) }
                }
            }
            self.photoDelegates[id] = delegate // survives asynchronous callbacks
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private func fail(_ text: String) {
        DispatchQueue.main.async { self.onState?(.failure(PocketFailure.message(text))) }
    }
}

private final class RAWCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private var data: Data?
    private var failure: Error?
    private let completion: (Result<Data, Error>) -> Void
    init(completion: @escaping (Result<Data, Error>) -> Void) { self.completion = completion }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error { failure = error; return }
        if photo.isRawPhoto { data = photo.fileDataRepresentation() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if let error = error ?? failure { completion(.failure(error)) }
        else if let data { completion(.success(data)) }
        else { completion(.failure(PocketFailure.message("相机没有返回 RAW 数据。"))) }
    }
}
