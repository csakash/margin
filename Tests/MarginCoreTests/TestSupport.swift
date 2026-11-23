import XCTest

/// Gives each test its own empty folder, removed afterwards.
class TempDirTestCase: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Spins the main run loop (so main-queue work runs) for `seconds`.
    func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func mdFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "md" }
    }
}
