import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PocketFilm

final class CaptureLibraryTests: XCTestCase {
    private var scratch: URL!
    private var library: URL { scratch.appendingPathComponent("Captures", isDirectory: true) }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketFilm-CaptureTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let scratch,
              scratch.lastPathComponent.hasPrefix("PocketFilm-CaptureTests-"),
              scratch.deletingLastPathComponent().standardizedFileURL.path == FileManager.default.temporaryDirectory.standardizedFileURL.path
        else { return }
        try FileManager.default.removeItem(at: scratch)
    }

    func testDateNamesAndIdenticalTimestampNeverOverwriteOriginals() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5, nanosecond: 123_000_000)))
        let firstBytes = Data("first original RAW".utf8)
        let secondBytes = Data("second original RAW".utf8)
        let first = try CaptureStore.prepare(raw: firstBytes, recipe: FilmRecipe(),
            baseDirectory: library, capturedAt: date)
        let second = try CaptureStore.prepare(raw: secondBytes, recipe: FilmRecipe(), ext: "arw",
            baseDirectory: library, capturedAt: date)

        XCTAssertEqual(first.displayName, "2026-01-02 03:04:05")
        XCTAssertEqual(first.folder.lastPathComponent, "2026-01-02_03-04-05-123")
        XCTAssertNotEqual(first.folder, second.folder)
        XCTAssertTrue(second.folder.lastPathComponent.hasPrefix(first.folder.lastPathComponent + "_"))
        XCTAssertEqual(first.source.lastPathComponent, first.id + "_RAW.dng")
        XCTAssertEqual(second.source.lastPathComponent, second.id + "_RAW.arw")
        XCTAssertEqual(first.jpeg.lastPathComponent, first.id + "_Film.jpg")
        XCTAssertEqual(try Data(contentsOf: first.source), firstBytes)
        XCTAssertEqual(try Data(contentsOf: second.source), secondBytes)
        let listed = CaptureStore.recent(baseDirectory: library)
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(Set(listed.map(\.id)), Set([first.id, second.id]))
        XCTAssertTrue(listed.allSatisfy { abs($0.capturedAt.timeIntervalSince(date)) < 0.001 })
    }

    func testLegacyUUIDFolderGetsDateLabelAndParticipatesInNewestFirstOrder() throws {
        let folder = library.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let raw = folder.appendingPathComponent("source.dng")
        let oldJPEG = folder.appendingPathComponent("film.jpg")
        try Data("legacy original".utf8).write(to: raw)
        try jpeg(width: 80, height: 60, red: 1, blue: 0).write(to: oldJPEG)
        let createdAt = try XCTUnwrap(folder.resourceValues(forKeys: [.creationDateKey]).creationDate)
        let newest = try CaptureStore.prepare(raw: Data([1]), recipe: FilmRecipe(),
            baseDirectory: library, capturedAt: createdAt.addingTimeInterval(60))
        let oldest = try CaptureStore.prepare(raw: Data([2]), recipe: FilmRecipe(),
            baseDirectory: library, capturedAt: createdAt.addingTimeInterval(-60))

        let listed = CaptureStore.recent(baseDirectory: library)
        XCTAssertEqual(listed.map(\.id), [newest.id, folder.lastPathComponent, oldest.id])
        let legacy = try XCTUnwrap(listed.first { $0.folder == folder })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar()
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        XCTAssertEqual(legacy.displayName, formatter.string(from: createdAt))
        XCTAssertEqual(legacy.source, raw)
        XCTAssertEqual(legacy.jpeg, oldJPEG)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "Listing must not rename existing folders")
        XCTAssertEqual(try Data(contentsOf: raw), Data("legacy original".utf8))
    }

    func testDeletingEntryRemovesItsFilesAndPreservesSibling() throws {
        let first = try CaptureStore.prepare(raw: Data("delete me".utf8), recipe: FilmRecipe(), baseDirectory: library)
        let keepBytes = Data("keep this original".utf8)
        let sibling = try CaptureStore.prepare(raw: keepBytes, recipe: FilmRecipe(), baseDirectory: library)
        try Data([10, 20]).write(to: first.jpeg)
        try Data([30, 40]).write(to: first.thumbnailURL)

        try CaptureStore.delete([first], baseDirectory: library)

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.jpeg.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.recipeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.thumbnailURL.path))
        XCTAssertEqual(try Data(contentsOf: sibling.source), keepBytes)
        XCTAssertNotNil(CaptureStore.readRecipe(for: sibling))
        XCTAssertEqual(CaptureStore.recent(baseDirectory: library).map(\.id), [sibling.id])
    }

    func testDeletionRejectsRootOutsideFolderAndSymbolicLink() throws {
        let original = Data("outside original must survive".utf8)
        let outside = try CaptureStore.prepare(raw: original, recipe: FilmRecipe(),
            baseDirectory: scratch.appendingPathComponent("Outside", isDirectory: true))
        let rootItem = CaptureItem(folder: library, source: library.appendingPathComponent("source.dng"),
            jpeg: library.appendingPathComponent("film.jpg"))
        XCTAssertThrowsError(try CaptureStore.delete([rootItem], baseDirectory: library))
        XCTAssertThrowsError(try CaptureStore.delete([outside], baseDirectory: library))
        let link = library.appendingPathComponent("linked-capture", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.folder)
        let linkedItem = CaptureItem(folder: link, source: link.appendingPathComponent(outside.source.lastPathComponent),
            jpeg: link.appendingPathComponent(outside.jpeg.lastPathComponent))
        XCTAssertThrowsError(try CaptureStore.delete([linkedItem], baseDirectory: library))
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertEqual(try Data(contentsOf: outside.source), original)
        XCTAssertTrue(CaptureStore.recent(baseDirectory: library).isEmpty, "A link must not become a library entry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path))
    }

    func testUnsafeBatchDoesNotDeleteEarlierValidEntry() throws {
        let original = Data("valid entry must survive a rejected batch".utf8)
        let valid = try CaptureStore.prepare(raw: original, recipe: FilmRecipe(), baseDirectory: library)
        let outsideBytes = Data("outside original".utf8)
        let outside = try CaptureStore.prepare(raw: outsideBytes, recipe: FilmRecipe(),
            baseDirectory: scratch.appendingPathComponent("Outside", isDirectory: true))
        XCTAssertThrowsError(try CaptureStore.delete([valid, outside], baseDirectory: library))
        XCTAssertEqual(try Data(contentsOf: valid.source), original)
        XCTAssertEqual(try Data(contentsOf: outside.source), outsideBytes)
        XCTAssertEqual(CaptureStore.recent(baseDirectory: library).map(\.id), [valid.id])
    }

    func testInvalidRAWRemainsListableAndDeletableWithoutThumbnail() async throws {
        let raw = Data("invalid raw with no JPEG".utf8)
        let item = try CaptureStore.prepare(raw: raw, recipe: FilmRecipe(), baseDirectory: library)
        let thumbnail = await CaptureStore.thumbnailData(for: item)
        XCTAssertNil(thumbnail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.thumbnailURL.path))
        XCTAssertEqual(CaptureStore.recent(baseDirectory: library).map(\.id), [item.id])
        XCTAssertEqual(try Data(contentsOf: item.source), raw)
        try CaptureStore.delete([item], baseDirectory: library)
        XCTAssertTrue(CaptureStore.recent(baseDirectory: library).isEmpty)
    }

    func testThumbnailIsBoundedRefreshesAndCannotRecreateDeletedFolder() async throws {
        let original = Data("original RAW is never changed by thumbnail work".utf8)
        let item = try CaptureStore.prepare(raw: original, recipe: FilmRecipe(), baseDirectory: library)
        try jpeg(width: 1500, height: 1000, red: 1, blue: 0).write(to: item.jpeg, options: .atomic)
        let firstBytes = await CaptureStore.thumbnailData(for: item)
        let firstData = try XCTUnwrap(firstBytes)
        let first = try image(firstData)
        XCTAssertEqual(first.width, 384)
        XCTAssertEqual(first.height, 256)
        let redPixel = try pixel(first)
        XCTAssertGreaterThan(redPixel[0], redPixel[2])
        XCTAssertEqual(try Data(contentsOf: item.thumbnailURL), firstData)

        // Reprocessing writes a differently oriented/content JPEG. The same
        // cache URL must now contain this version, rather than the old image.
        try jpeg(width: 600, height: 900, red: 0, blue: 1).write(to: item.jpeg, options: .atomic)
        try CaptureStore.updateThumbnail(for: item)
        let updatedBytes = await CaptureStore.thumbnailData(for: item)
        let updated = try image(XCTUnwrap(updatedBytes))
        XCTAssertEqual(updated.width, 256)
        XCTAssertEqual(updated.height, 384)
        let bluePixel = try pixel(updated)
        XCTAssertGreaterThan(bluePixel[2], bluePixel[0])
        XCTAssertNotEqual(updatedBytes, firstBytes)
        XCTAssertEqual(try Data(contentsOf: item.source), original)

        try CaptureStore.delete([item], baseDirectory: library)
        let staleRowResult = await CaptureStore.thumbnailData(for: item)
        XCTAssertNil(staleRowResult)
        try CaptureStore.updateThumbnail(for: item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.folder.path))
    }

    private func calendar() -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        return value
    }

    private func jpeg(width: Int, height: Int, red: CGFloat, blue: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let bitmap = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    private func image(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixel(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
