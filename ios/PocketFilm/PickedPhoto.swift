import CoreTransferable
import Foundation
import UniformTypeIdentifiers

final class PickedPhoto: Transferable {
    let url: URL

    private init(copying source: URL) throws {
        // The picker owns its file only for the duration of the transfer.
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketFilm-" + UUID().uuidString)
            .appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at: source, to: copy)
        url = copy
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .rawImage) { received in
            try PickedPhoto(copying: received.file)
        }
        FileRepresentation(importedContentType: .image) { received in
            try PickedPhoto(copying: received.file)
        }
    }
}
