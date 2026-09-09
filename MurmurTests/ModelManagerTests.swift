@testable import Murmur
import XCTest

/// In-memory engine: records load order and can be slowed down so the
/// manager's queueing behaviour is observable.
actor FakeEngine: TranscriptionEngine {
    private(set) var loaded: WhisperModel?
    private(set) var loadSequence: [WhisperModel] = []
    private(set) var unloadCount = 0
    var loadDelay: Duration = .zero

    var loadedModel: WhisperModel? { loaded }

    func setLoadDelay(_ delay: Duration) { loadDelay = delay }

    func load(model: WhisperModel, folder: URL, tokenizerFolder: URL) async throws {
        loadSequence.append(model)
        if loadDelay > .zero { try? await Task.sleep(for: loadDelay) }
        loaded = model
    }

    func unload() async {
        unloadCount += 1
        loaded = nil
    }

    func transcribe(samples: [Float], language: TranscriptionLanguage) async throws -> Transcript {
        Transcript(text: "hello", language: language.whisperCode, processingTime: 0)
    }
}

@MainActor
final class ModelManagerTests: XCTestCase {
    private var root: URL!
    private var engine: FakeEngine!
    private var manager: ModelManager!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MurmurModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        engine = FakeEngine()
        manager = ModelManager(engine: engine, rootDirectory: root)
        for model in WhisperModel.allCases { try makeBundle(for: model) }
        manager.refreshStatuses()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBundle(for model: WhisperModel) throws {
        let folder = manager.folder(for: model)
        for name in ModelManager.requiredModelDirectories {
            let dir = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("coremldata.bin"))
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
    }

    func testFreshManagerSeesBundlesAsDownloadedButNotReady() {
        for model in WhisperModel.allCases {
            XCTAssertEqual(manager.status(of: model), .downloaded)
            XCTAssertEqual(manager.availability(of: model), .cold, "on disk means usable on demand")
        }
        XCTAssertFalse(manager.isReady)
        XCTAssertNil(manager.activeModel)
    }

    func testActivateLoadsAndBecomesReady() async {
        manager.activate(.small)
        XCTAssertEqual(manager.status(of: .small), .loading, "reflected synchronously")
        let ready = await manager.awaitActivation()
        XCTAssertTrue(ready)
        XCTAssertEqual(manager.status(of: .small), .ready)
        XCTAssertEqual(manager.activeModel, .small)
        let loaded = await engine.loadedModel
        XCTAssertEqual(loaded, .small)
    }

    func testRapidSwitchingBeforeAnythingStartsLoadsOnlyTheLast() async {
        manager.activate(.small)
        manager.activate(.medium)
        manager.activate(.largeV3Turbo)
        XCTAssertEqual(manager.status(of: .largeV3Turbo), .loading, "request is reflected immediately")
        let ready = await manager.awaitActivation()
        XCTAssertTrue(ready)

        let sequence = await engine.loadSequence
        XCTAssertEqual(sequence, [.largeV3Turbo], "requests that never started are skipped outright")
        XCTAssertEqual(manager.status(of: .small), .downloaded, "skipped requests are not left in .loading")
        XCTAssertEqual(manager.status(of: .medium), .downloaded)
        XCTAssertEqual(manager.status(of: .largeV3Turbo), .ready)
    }

    func testRapidSwitchingLoadsFirstAndLastOnly() async {
        await engine.setLoadDelay(.milliseconds(40))
        manager.activate(.small)
        // Let the first load actually begin before switching away from it.
        while await engine.loadSequence.isEmpty { await Task.yield() }
        manager.activate(.medium)
        manager.activate(.largeV3Turbo)
        let ready = await manager.awaitActivation()
        XCTAssertTrue(ready)

        let sequence = await engine.loadSequence
        XCTAssertEqual(sequence, [.small, .largeV3Turbo], "the in-flight load completes, the superseded middle request is skipped")
        XCTAssertEqual(manager.activeModel, .largeV3Turbo)
        XCTAssertEqual(manager.status(of: .largeV3Turbo), .ready)
        XCTAssertEqual(manager.status(of: .small), .downloaded, "no model is left stuck in .loading")
        XCTAssertEqual(manager.status(of: .medium), .downloaded)
        let loaded = await engine.loadedModel
        XCTAssertEqual(loaded, .largeV3Turbo, "engine holds what activeModel reports")
    }

    func testActivatingTheReadyModelAgainIsANoOp() async {
        manager.activate(.small)
        _ = await manager.awaitActivation()
        manager.activate(.small)
        _ = await manager.awaitActivation()
        let sequence = await engine.loadSequence
        XCTAssertEqual(sequence, [.small])
    }

    func testIdleUnloadDropsTheModelAndActivateBringsItBack() async {
        manager.activate(.small)
        _ = await manager.awaitActivation()

        await manager.unloadForIdle()
        XCTAssertNil(manager.activeModel)
        XCTAssertEqual(manager.status(of: .small), .downloaded)
        XCTAssertEqual(manager.availability(of: .small), .cold)
        let unloads = await engine.unloadCount
        XCTAssertEqual(unloads, 1)

        manager.activate(.small)
        let ready = await manager.awaitActivation()
        XCTAssertTrue(ready)
        XCTAssertEqual(manager.status(of: .small), .ready)
    }

    func testIdleUnloadIsANoOpWhileNothingIsWarm() async {
        await manager.unloadForIdle()
        let unloads = await engine.unloadCount
        XCTAssertEqual(unloads, 0)
    }

    func testAwaitActivationWithNothingQueuedReturnsCurrentState() async {
        let ready = await manager.awaitActivation()
        XCTAssertFalse(ready)
    }

    func testDeleteWaitsForInFlightLoadAndUnloads() async {
        await engine.setLoadDelay(.milliseconds(40))
        manager.activate(.small)
        await manager.delete(.small)
        XCTAssertEqual(manager.status(of: .small), .notDownloaded)
        XCTAssertNil(manager.activeModel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.folder(for: .small).path))
        let loaded = await engine.loadedModel
        XCTAssertNil(loaded)
    }

    func testFreeSpaceRequirementIncludesHeadroom() {
        let needed = ModelManager.requiredFreeBytes(for: .largeV3Turbo)
        XCTAssertGreaterThan(needed, Int64(WhisperModel.largeV3Turbo.approximateSizeMB) * 1_000_000)
        XCTAssertTrue(ModelManager.hasEnoughFreeSpace(for: .largeV3Turbo, availableBytes: needed))
        XCTAssertFalse(ModelManager.hasEnoughFreeSpace(for: .largeV3Turbo, availableBytes: needed - 1))
        XCTAssertFalse(ModelManager.hasEnoughFreeSpace(for: .medium, availableBytes: 1_000_000_000), "1 GB is not enough for a 1.5 GB model")
    }

    func testCancellingWhenNothingIsDownloadingIsHarmless() {
        manager.cancelDownload(.small)
        XCTAssertEqual(manager.status(of: .small), .downloaded)
    }

    func testAvailabilityFollowsTheLifecycle() async {
        XCTAssertEqual(manager.availability(of: .small), .cold)
        manager.activate(.small)
        XCTAssertEqual(manager.availability(of: .small), .loading)
        _ = await manager.awaitActivation()
        XCTAssertEqual(manager.availability(of: .small), .warm)
        XCTAssertEqual(manager.availability(of: .medium), .cold, "only the active model is warm")

        await manager.delete(.small)
        XCTAssertEqual(manager.availability(of: .small), .blocked(reason: "Choose and download a model in Settings"))
    }

    func testAwaitActivationOfReportsTheRequestedModelOnly() async {
        manager.activate(.small)
        let small = await manager.awaitActivation(of: .small)
        let medium = await manager.awaitActivation(of: .medium)
        XCTAssertTrue(small)
        XCTAssertFalse(medium)
    }
}
