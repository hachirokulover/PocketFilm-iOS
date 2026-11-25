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
    var export = ExportSettings()

    // Full-frame spectral rendering is required for upstream overscan. Keep
    // its input bounded on phones; the film margin adds pixels outside it.
    var usesFotufilm: Bool { film.hasPrefix(FotufilmStock.prefix) }
    var hasFilmBorder: Bool { border.enabled && !usesFotufilm }
    var processingEdge: Int { Int(pf_processing_edge(Int64(maxPhotoEdge), hasFilmBorder, false)) }

    init() {}

    enum CodingKeys: String, CodingKey {
        case film, paper, sceneEV, grain, halation, monochrome, maxPhotoEdge
        case temperature, automaticWhiteBalance, grainAmount, halationAmount, border, export
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
        export = try c.decodeIfPresent(ExportSettings.self, forKey: .export) ?? .legacy
    }

    func engineDelta(preview: Bool) throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        let delta = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            border.edgeText(stock: film).withCString { text in
                pf_engine_delta(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, preview, text)
            }
        }
        defer { pf_free_string(delta) }
        guard let delta,
              let value = try JSONSerialization.jsonObject(with: Data(String(cString: delta).utf8)) as? [String: Any] else {
            throw PocketFailure.message("无法读取显影设置。")
        }
        return value
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
