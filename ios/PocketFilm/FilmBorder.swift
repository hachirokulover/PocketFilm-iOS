import CoreImage
import Foundation

// Wire values and gate dimensions from upstream FilmEdge.swift / overscan.cpp.
// The original engine exposes the film before developing it; no bitmap overlay.
enum FilmBorderFormat: String, Codable, CaseIterable, Identifiable {
    case full135 = "135", half135 = "135_half", f645 = "120_645", f6x6 = "120_6x6"
    case f6x7 = "120_6x7", f6x8 = "120_6x8", f6x9 = "120_6x9"
    case xpan = "135_xpan", f6x12 = "120_6x12", f6x17 = "120_6x17"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full135: return "135 · 标准齿孔"
        case .half135: return "135 · 半格齿孔"
        case .f645: return "120 · 6×4.5"
        case .f6x6: return "120 · 6×6 方形"
        case .f6x7: return "120 · 6×7"
        case .f6x8: return "120 · 6×8"
        case .f6x9: return "120 · 6×9"
        case .xpan: return "135 · XPan 宽幅齿孔"
        case .f6x12: return "120 · 6×12 宽幅"
        case .f6x17: return "120 · 6×17 宽幅"
        }
    }
    var perforated: Bool { self == .full135 || self == .half135 || self == .xpan }
    var gateRatio: CGFloat {
        switch self {
        case .full135: return 36.25 / 24.3
        case .half135: return 24 / 18
        case .f645: return 56 / 41.5
        case .f6x6: return 1
        case .f6x7: return 69.5 / 56
        case .f6x8: return 76 / 56
        case .f6x9: return 84 / 56
        case .xpan: return 65 / 24
        case .f6x12: return 112 / 56
        case .f6x17: return 168 / 56
        }
    }
}

enum FilmBorderScan: String, Codable, CaseIterable, Identifiable {
    case strip, filed
    var id: String { rawValue }
    var title: String { self == .strip ? "片条扫描" : "扩孔片夹" }
}

enum FilmBorderHoles: String, Codable, CaseIterable, Identifiable {
    case white, black
    var id: String { rawValue }
    var title: String { self == .white ? "白色齿孔" : "黑色齿孔" }
}

struct FilmBorderSettings: Codable, Equatable {
    var enabled = false
    var format = FilmBorderFormat.full135
    var scan = FilmBorderScan.strip
    var holes = FilmBorderHoles.white
    var fog: Double = 1
    var leaks: Double = 0
    var frameNumber = 0
    var cameraSeed = 1
    var frameSeed = 1

    // Only the developed JPEG is cut. RAW and native viewfinder stay intact.
    func cropRect(in extent: CGRect) -> CGRect {
        guard enabled, !extent.isEmpty, !extent.isInfinite else { return extent }
        let ratio = extent.width >= extent.height ? format.gateRatio : 1 / format.gateRatio
        var width = extent.width, height = extent.height
        if width / height > ratio { width = height * ratio } else { height = width / ratio }
        // Integer dimensions without expanding outside the source.
        width = max(1, floor(width)); height = max(1, floor(height))
        return CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2, width: width, height: height)
    }

    func cropped(_ image: CIImage) -> CIImage {
        guard enabled else { return image }
        let rect = cropRect(in: image.extent)
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    func edgeText(stock: String) -> String {
        // Preserve upstream's measured edge labels for stocks with special text.
        let labels: [String: (String, String)] = [
            "kodak_gold_200": ("KODAK GB 200-7", "KODAK 200"),
            "kodak_portra_800": ("KODAK PORTRA 800-3", "KODAK PORTRA 800"),
            "kodak_portra_800_push1": ("KODAK PORTRA 800-3", "KODAK PORTRA 800"),
            "kodak_portra_800_push2": ("KODAK PORTRA 800-3", "KODAK PORTRA 800"),
            "kodak_ultramax_400": ("KODAK GC 400", "KODAK GC 400"),
            "kodak_ektachrome_100": ("KODAK E100", "KODAK E100"),
            "fujifilm_c200": ("FUJI 200", "FUJI 200"),
            "fujifilm_xtra_400": ("S-400", "FUJI S-400"),
            "fujifilm_pro_400h": ("PRO400H", "FUJI PRO400H"),
            "fujifilm_provia_100f": ("FUJI RDPIII", "FUJI RDPIII"),
            "fujifilm_velvia_100": ("RVP100", "FUJI RVP100"),
            "kodak_vision3_50d": ("EASTMAN 5203", "EASTMAN 5203"),
            "kodak_vision3_250d": ("EASTMAN 5207", "EASTMAN 5207"),
            "kodak_vision3_200t": ("EASTMAN 5213", "EASTMAN 5213"),
            "kodak_vision3_500t": ("EASTMAN 5219", "EASTMAN 5219"),
            "cinestill_800t": ("CINESTILL 800T", "CINESTILL 800T"),
            "kodak_tri_x_400": ("KODAK 400TX", "KODAK 400TX"),
            "kodak_tmax_100": ("KODAK 100TMX", "KODAK 100TMX"),
            "fujifilm_neopan_acros_100_ii": ("FUJI 100 ACROS II", "FUJI 100 ACROS II"),
            "ilford_hp5_plus_400": ("ILFORD HP5 PLUS", "ILFORD HP5 PLUS")]
        if let text = labels[stock] { return format.perforated ? text.0 : text.1 }
        return stock.replacingOccurrences(of: "_", with: " ").uppercased()
    }
}
