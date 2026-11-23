import CryptoKit
import XCTest
@testable import MarginCore

final class AssetStoreTests: TempDirTestCase {

    private var assetsDir: URL { dir.appendingPathComponent("assets") }

    func testImportDataNamesBySHA256AndDedupes() throws {
        let store = AssetStore(folder: assetsDir)
        let data = Data("pixels".utf8)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let rel = try store.importData(data, ext: "PNG")
        XCTAssertEqual(rel, "assets/\(hex.prefix(16)).png")
        XCTAssertEqual(try Data(contentsOf: store.url(for: rel)), data)
        XCTAssertEqual(try store.importData(data, ext: "png"), rel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: assetsDir.path).count, 1)
        XCTAssertNotEqual(try store.importData(Data("other".utf8), ext: "png"), rel)
    }

    func testImportFileCopiesOnceAndMatchesDataHash() throws {
        let store = AssetStore(folder: assetsDir)
        // Larger than one read chunk, to exercise streaming.
        var bytes = Data(count: (1 << 20) * 2 + 123)
        for i in stride(from: 0, to: bytes.count, by: 997) { bytes[i] = UInt8(i % 251) }
        let src = dir.appendingPathComponent("Clip.MOV")
        try bytes.write(to: src)

        let rel = try store.importFile(at: src)
        XCTAssertTrue(rel.hasPrefix("assets/"))
        XCTAssertTrue(rel.hasSuffix(".mov"))
        XCTAssertEqual((rel as NSString).lastPathComponent.count, 16 + 4)
        XCTAssertEqual(try Data(contentsOf: store.url(for: rel)), bytes)
        XCTAssertEqual(store.url(for: rel).path, assetsDir.appendingPathComponent((rel as NSString).lastPathComponent).path)

        let mtime = try FileManager.default.attributesOfItem(atPath: store.url(for: rel).path)[.modificationDate] as? Date
        pumpBriefly()
        XCTAssertEqual(try store.importFile(at: src), rel)
        let mtime2 = try FileManager.default.attributesOfItem(atPath: store.url(for: rel).path)[.modificationDate] as? Date
        XCTAssertEqual(mtime, mtime2, "an existing asset is not copied again")
        // Same bytes imported as data resolve to the same file.
        XCTAssertEqual(try store.importData(bytes, ext: "mov"), rel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "source is left in place")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: assetsDir.path).count, 1)
    }

    func testFileWithoutExtension() throws {
        let store = AssetStore(folder: assetsDir)
        let src = dir.appendingPathComponent("README")
        try Data("x".utf8).write(to: src)
        let rel = try store.importFile(at: src)
        XCTAssertEqual((rel as NSString).lastPathComponent.count, 16)
    }

    func testNoteStoreAssetsLiveInNotesFolder() throws {
        let notes = try NoteStore(folder: dir)
        let rel = try notes.assets.importData(Data("img".utf8), ext: "jpg")
        XCTAssertTrue(rel.hasPrefix("assets/"))
        XCTAssertEqual(notes.assets.url(for: rel).deletingLastPathComponent().standardizedFileURL.path,
                       assetsDir.standardizedFileURL.path)
        XCTAssertTrue(notes.list().isEmpty, "assets are not notes")
    }

    private func pumpBriefly() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}
