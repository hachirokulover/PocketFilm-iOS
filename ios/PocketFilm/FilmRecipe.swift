import Foundation

struct FilmRecipe: Codable, Equatable {
    var film = "kodak_portra_400"
    var paper = "kodak_portra_endura"
    var sceneEV: Double = 0
    var grain = true
    var halation = true
    var monochrome = false
    var maxPhotoEdge = 4032
    var temperature: Double = 5500
    var automaticWhiteBalance = true
    var grainAmount: Double = 1
    var halationAmount: Double = 1
    var border = FilmBorderSettings()

    // Full-frame spectral rendering is required for upstream overscan. Keep
    // its input bounded on phones; the film margin adds pixels outside it.
    var processingEdge: Int { border.enabled ? min(maxPhotoEdge, 2048) : maxPhotoEdge }

    init() {}

    enum CodingKeys: String, CodingKey {
        case film, paper, sceneEV, grain, halation, monochrome, maxPhotoEdge
        case temperature, automaticWhiteBalance, grainAmount, halationAmount, border
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FilmRecipe()
        film = try c.decodeIfPresent(String.self, forKey: .film) ?? d.film
        paper = try c.decodeIfPresent(String.self, forKey: .paper) ?? d.paper
        sceneEV = try c.decodeIfPresent(Double.self, forKey: .sceneEV) ?? d.sceneEV
        grain = try c.decodeIfPresent(Bool.self, forKey: .grain) ?? d.grain
        halation = try c.decodeIfPresent(Bool.self, forKey: .halation) ?? d.halation
        monochrome = try c.decodeIfPresent(Bool.self, forKey: .monochrome) ?? d.monochrome
        maxPhotoEdge = try c.decodeIfPresent(Int.self, forKey: .maxPhotoEdge) ?? d.maxPhotoEdge
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        automaticWhiteBalance = try c.decodeIfPresent(Bool.self, forKey: .automaticWhiteBalance) ?? d.automaticWhiteBalance
        grainAmount = try c.decodeIfPresent(Double.self, forKey: .grainAmount) ?? d.grainAmount
        halationAmount = try c.decodeIfPresent(Double.self, forKey: .halationAmount) ?? d.halationAmount
        border = try c.decodeIfPresent(FilmBorderSettings.self, forKey: .border) ?? d.border
    }

    // Current SpektraLab's product_defaults disables print exposure compensation.
    // Apply film EV after its meter so auto exposure cannot cancel this control.
    func engineDelta(preview: Bool) -> [String: Any] {
        ["product_defaults": true,
         "film_stock": film, "print_stock": paper,
         "input_color_space": "ProPhoto RGB", "input_cctf_decoding": false,
         "output_color_space": "sRGB", "output_cctf_encoding": true,
         "exposure_compensation_ev": sceneEV,
         "auto_exposure": true, "grain_active": preview ? false : (grain && grainAmount > 0),
         "grain_amount": grainAmount,
         "grain_sublayers_active": !monochrome,
         "halation_active": halation && halationAmount > 0,
         "halation_amount": halationAmount, "glare_active": false,
         "extended_dynamic_range": false, "striped": !border.enabled,
         "overscan_active": border.enabled,
         "overscan_format": border.format.rawValue, "overscan_mode": border.scan.rawValue,
         "overscan_holes": border.holes.rawValue, "overscan_gate": "auto",
         "overscan_fog": border.fog, "overscan_leaks": border.leaks,
         "overscan_camera_seed": border.cameraSeed, "overscan_frame_seed": border.frameSeed,
         "overscan_frame_number": border.frameNumber,
         "overscan_edge_text": border.edgeText(stock: film), "overscan_pair": false,
         "overscan_carrier": "none",
         // The render uses the full tier of a pre-scaled source. 800 is the
         // wire's minimum live-tier setting, not the preview's input size.
         "strip_rows": 128, "preview_long_edge": 800]
    }
}

struct FilmStock: Identifiable {
    let id: String
    let name: String
    let paper: String
    let monochrome: Bool

    static func bundled() -> [FilmStock] {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("engine/profiles"),
              let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.compactMap { url -> FilmStock? in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = json["info"] as? [String: Any],
                  info["stage"] as? String == "filming",
                  let id = info["stock"] as? String,
                  let name = info["name"] as? String,
                  let paper = info["target_print"] as? String,
                  FileManager.default.fileExists(atPath: root.appendingPathComponent(paper + ".json").path)
            else { return nil }
            return FilmStock(id: id, name: name, paper: paper, monochrome: info["channel_model"] as? String == "bw")
        }.sorted { $0.name < $1.name }
    }
}

enum PocketFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
