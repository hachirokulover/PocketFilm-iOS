import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Codable {
    case jpeg, heif

    var title: String { self == .jpeg ? "JPG" : "HEIF" }
    var fileExtension: String { self == .jpeg ? "jpg" : "heic" }
    var contentType: UTType { self == .jpeg ? .jpeg : .heic }
}

enum ExportColorSpace: String, CaseIterable, Codable {
    case sRGB, adobeRGB, displayP3, dciP3

    var title: String {
        switch self {
        case .sRGB: return "sRGB"
        case .adobeRGB: return "Adobe RGB (1998)"
        case .displayP3: return "Display P3"
        case .dciP3: return "DCI-P3"
        }
    }

    var colorSpace: CGColorSpace {
        let name: CFString
        switch self {
        case .sRGB: name = CGColorSpace.sRGB
        case .adobeRGB: name = CGColorSpace.adobeRGB1998
        case .displayP3: name = CGColorSpace.displayP3
        case .dciP3: name = CGColorSpace.dcip3
        }
        return CGColorSpace(name: name)!
    }

    // The engine supports Adobe RGB and Display P3 directly. DCI-P3 needs
    // different white point and transfer curves, so convert from a wide
    // linear engine output through Core Image's DCI-P3 profile.
    var engineName: String { self == .dciP3 ? "ProPhoto RGB" : title }
    var engineEncodesTransfer: Bool { self != .dciP3 }
    var engineColorSpace: CGColorSpace { self == .dciP3 ? FilmEngine.linearProPhoto : colorSpace }
}

struct ExportSettings: Codable, Equatable {
    var format: ExportFormat = .jpeg
    var colorSpace: ExportColorSpace = .sRGB
    var quality: Double = 100

    static let qualityRange: ClosedRange<Double> = 1...100
    static let legacy = ExportSettings(quality: 95)

    var compressionQuality: Double {
        min(Self.qualityRange.upperBound, max(Self.qualityRange.lowerBound, quality)) / 100
    }
}
