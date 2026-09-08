import XCTest
@testable import Murmur

final class ModelBundleTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MurmurBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeCompleteBundle() throws {
        for name in ModelManager.requiredModelDirectories {
            let dir = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("coremldata.bin"))
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
    }

    func testCompleteBundleIsDetected() throws {
        try makeCompleteBundle()
        XCTAssertTrue(ModelManager.isCompleteBundle(at: folder))
    }

    func testMissingFolderIsIncomplete() {
        XCTAssertFalse(ModelManager.isCompleteBundle(at: folder.appendingPathComponent("nope")))
        XCTAssertFalse(ModelManager.isCompleteBundle(at: folder), "empty directory")
    }

    func testEncoderAloneIsIncomplete() throws {
        // The exact situation an interrupted download leaves behind.
        let encoder = folder.appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: encoder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: encoder.appendingPathComponent("coremldata.bin"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        XCTAssertFalse(ModelManager.isCompleteBundle(at: folder))
    }

    func testModelDirectoryWithoutCompiledDataIsIncomplete() throws {
        try makeCompleteBundle()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("TextDecoder.mlmodelc/coremldata.bin"))
        XCTAssertFalse(ModelManager.isCompleteBundle(at: folder))
    }

    func testMissingConfigIsIncomplete() throws {
        try makeCompleteBundle()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("config.json"))
        XCTAssertFalse(ModelManager.isCompleteBundle(at: folder))
    }

    func testFileWhereDirectoryExpectedIsIncomplete() throws {
        try makeCompleteBundle()
        let mel = folder.appendingPathComponent("MelSpectrogram.mlmodelc")
        try FileManager.default.removeItem(at: mel)
        try Data("x".utf8).write(to: mel)
        XCTAssertFalse(ModelManager.isCompleteBundle(at: folder))
    }
}
