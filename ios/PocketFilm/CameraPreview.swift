import SwiftUI
import AVFoundation
import UIKit

enum CompositionGuide: String, CaseIterable, Identifiable {
    case off = "关闭", thirds = "九宫格", square = "方形", widescreen = "16:9"
    var id: String { rawValue }
}

// The camera now draws directly to an AVCaptureVideoPreviewLayer. No video
// frame is decoded, copied to the film engine, or throttled by RenderWorker.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let guide: CompositionGuide
    var onFocus: (CGPoint) -> Void = { _ in }
    func makeUIView(context: Context) -> PreviewHost {
        let view = PreviewHost()
        // CameraArrangement preserves this layer when the layout axis changes.
        // Attach once; never reattach a running session just to rotate the UI.
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.onFocus = onFocus
        return view
    }
    func updateUIView(_ view: PreviewHost, context: Context) {
        view.guide = guide
        view.onFocus = onFocus
        // Also retry after camera setup/lens switching creates a connection.
        view.scheduleRotationUpdate()
        view.setNeedsLayout()
    }
    static func dismantleUIView(_ view: PreviewHost, coordinator: ()) {
        view.disconnect()
    }
}

final class PreviewHost: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var guide: CompositionGuide = .thirds
    var onFocus: ((CGPoint) -> Void)?
    private var requestedAngle: CGFloat?
    private var rotationUpdate: DispatchWorkItem?
    private let guideLayer = CAShapeLayer()
    private let focusLayer = CAShapeLayer()
    private var hideFocus: DispatchWorkItem?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        guideLayer.strokeColor = UIColor.white.withAlphaComponent(0.65).cgColor
        guideLayer.fillColor = UIColor.clear.cgColor
        guideLayer.lineWidth = 1
        guideLayer.shadowColor = UIColor.black.cgColor
        guideLayer.shadowOpacity = 0.5
        guideLayer.shadowRadius = 1
        layer.addSublayer(guideLayer)
        focusLayer.strokeColor = UIColor.systemYellow.cgColor
        focusLayer.fillColor = UIColor.clear.cgColor
        focusLayer.lineWidth = 2
        focusLayer.opacity = 0
        layer.addSublayer(focusLayer)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focusTapped(_:))))
        accessibilityLabel = "相机取景，点击画面选择对焦点"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    func disconnect() {
        hideFocus?.cancel()
        rotationUpdate?.cancel()
        previewLayer.session = nil
        onFocus = nil
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleRotationUpdate()
        setNeedsLayout()
    }

    @objc private func focusTapped(_ gesture: UITapGestureRecognizer) {
        guard previewLayer.isPreviewing else { return }
        let point = gesture.location(in: self)
        let video = previewLayer.layerRectConverted(
            fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)).intersection(bounds)
        guard video.contains(point) else { return } // Ignore letterboxing.
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        onFocus?(devicePoint)
        hideFocus?.cancel()
        focusLayer.removeAllAnimations()
        focusLayer.frame = bounds
        focusLayer.path = UIBezierPath(rect: CGRect(x: point.x - 30, y: point.y - 30, width: 60, height: 60)).cgPath
        focusLayer.opacity = 1
        let work = DispatchWorkItem { [weak self] in self?.focusLayer.opacity = 0 }
        hideFocus = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let angle = CameraOrientation.previewAngle(for: window?.windowScene?.interfaceOrientation ?? .portrait)
        if requestedAngle != angle {
            focusLayer.opacity = 0
            scheduleRotationUpdate()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guideLayer.frame = bounds
        let video = previewLayer.layerRectConverted(
            fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)).intersection(bounds)
        let path = UIBezierPath()
        if !video.isEmpty {
            switch guide {
            case .off: break
            case .thirds:
                for fraction in [CGFloat(1)/3, CGFloat(2)/3] {
                    let x = video.minX + video.width * fraction
                    let y = video.minY + video.height * fraction
                    path.move(to: CGPoint(x: x, y: video.minY)); path.addLine(to: CGPoint(x: x, y: video.maxY))
                    path.move(to: CGPoint(x: video.minX, y: y)); path.addLine(to: CGPoint(x: video.maxX, y: y))
                }
            case .square, .widescreen:
                let ratio: CGFloat = guide == .square ? 1 : 16/9
                let width = min(video.width, video.height * ratio)
                let height = width / ratio
                path.append(UIBezierPath(rect: CGRect(x: video.midX-width/2, y: video.midY-height/2,
                                                      width: width, height: height)))
            }
        }
        guideLayer.path = path.cgPath
    }

    func scheduleRotationUpdate() {
        let angle = CameraOrientation.previewAngle(for: window?.windowScene?.interfaceOrientation ?? .portrait)
        requestedAngle = angle
        rotationUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let scene = self.window?.windowScene,
                  let connection = self.previewLayer.connection else { return }
            let currentAngle = CameraOrientation.previewAngle(for: scene.interfaceOrientation)
            guard connection.isVideoRotationAngleSupported(currentAngle),
                  connection.videoRotationAngle != currentAngle else { return }
            // Preview-layer work stays on main, but outside UIKit/SwiftUI's
            // synchronous layout transaction. Never wait on the camera queue.
            connection.videoRotationAngle = currentAngle
            self.setNeedsLayout()
        }
        rotationUpdate = work
        DispatchQueue.main.async(execute: work)
    }
}
