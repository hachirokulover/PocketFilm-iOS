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
    func makeUIView(context: Context) -> PreviewHost {
        let view = PreviewHost()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: PreviewHost, context: Context) {
        view.guide = guide
        view.setNeedsLayout()
    }
}

final class PreviewHost: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var guide: CompositionGuide = .thirds
    private let guideLayer = CAShapeLayer()
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
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
}
