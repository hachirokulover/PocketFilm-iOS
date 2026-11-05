import UIKit

enum CameraOrientation {
    // Rear-camera sensor coordinates. Device landscape directions are the
    // opposite of UIInterfaceOrientation's landscape directions.
    static func captureAngle(for orientation: UIDeviceOrientation, fallback: CGFloat) -> CGFloat {
        switch orientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        default: return fallback // flat on a table / unknown: retain last direction
        }
    }

    static func previewAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .landscapeRight: return 0
        case .landscapeLeft: return 180
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }
}
