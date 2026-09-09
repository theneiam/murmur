@testable import Murmur
import XCTest

// MARK: - Fakes (one per seam)

@MainActor
final class FakeRecorder: AudioCapturing {
    var onLevel: ((Float) -> Void)?
    var onAutoStop: ((Recording) -> Void)?
    var startError: Error?
    var nextRecording = Recording(samples: [], wallClockDuration: 0)
    private(set) var startCalls: [(uid: String?, maxDuration: TimeInterval)] = []
    private(set) var stopCalls = 0

    func start(inputDeviceUID: String?, maxDuration: TimeInterval) throws {
        startCalls.append((inputDeviceUID, maxDuration))
        if let startError { throw startError }
    }

    @discardableResult
    func stop() -> Recording {
        stopCalls += 1
        return nextRecording
    }

    func triggerAutoStop() { onAutoStop?(nextRecording) }
}

actor ScriptedEngine: TranscriptionEngine {
    var text = "hello world"
    var delay: Duration = .zero
    var error: Error?
    private(set) var transcribeCalls = 0
    var loadedModel: WhisperModel? { nil }

    func set(text: String) { self.text = text }
    func set(delay: Duration) { self.delay = delay }
    func set(error: Error?) { self.error = error }

    func load(model: WhisperModel, folder: URL, tokenizerFolder: URL) async throws {}
    func unload() async {}
    func transcribe(samples: [Float], language: TranscriptionLanguage) async throws -> Transcript {
        transcribeCalls += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        return Transcript(text: text, language: language.whisperCode, processingTime: 0.1)
    }
}

@MainActor
final class FakeModels: ModelProviding {
    let scripted = ScriptedEngine()
    var engine: any TranscriptionEngine { scripted }
    var availabilityValue: ModelAvailability = .warm
    var awaitResult = true
    private(set) var activateCalls: [WhisperModel] = []
    private(set) var awaitCalls: [WhisperModel] = []

    func availability(of model: WhisperModel) -> ModelAvailability { availabilityValue }
    func activate(_ model: WhisperModel) { activateCalls.append(model)
        availabilityValue = .loading
    }

    func awaitActivation(of model: WhisperModel) async -> Bool {
        awaitCalls.append(model)
        if awaitResult { availabilityValue = .warm }
        return awaitResult
    }
}

@MainActor
final class FakeInserter: TextInserting {
    var method: InsertionMethod = .accessibility
    var error: Error?
    private(set) var inserted: [(text: String, strategy: InsertionStrategy)] = []

    func insert(_ text: String, strategy: InsertionStrategy) async throws -> InsertionMethod {
        if let error { throw error }
        inserted.append((text, strategy))
        return method
    }
}

@MainActor
final class FakePresenter: DictationPresenting {
    private(set) var calls: [String] = []
    func showRecording() { calls.append("recording") }
    func showWorking(_ label: String) { calls.append("working:\(label)") }
    func showMessage(_ text: String, for duration: TimeInterval) { calls.append("message:\(text)") }
    func hide() { calls.append("hide") }
    func push(level: Float) { calls.append("level") }
    func playCue(_ cue: SoundCue) { calls.append("cue:\(cue)") }
}

struct TestError: LocalizedError { var errorDescription: String? { "boom" } }

// MARK: - Tests

@MainActor
final class DictationSessionTests: XCTestCase {
    private var recorder: FakeRecorder!
    private var models: FakeModels!
    private var inserter: FakeInserter!
    private var presenter: FakePresenter!
    private var config: DictationConfig!
    private var events: [DictationEvent] = []
    private var session: DictationSession!

    private static let oneSecond = Recording(samples: [Float](repeating: 0.1, count: 16_000), wallClockDuration: 1.0)

    override func setUp() {
        recorder = FakeRecorder()
        models = FakeModels()
        inserter = FakeInserter()
        presenter = FakePresenter()
        events = []
        config = DictationConfig(
            model: .small, language: .english, postProcessing: PostProcessingOptions(),
            insertionStrategy: .accessibilityThenPasteboard, inputDeviceUID: "mic-1",
            maxRecordingSeconds: 120, playSounds: true, microphoneAuthorized: true
        )
        recorder.nextRecording = Self.oneSecond
        makeSession()
    }

    private func makeSession(timeout: Duration = .seconds(5)) {
        session = DictationSession(
            recorder: recorder, models: models, inserter: inserter, presenter: presenter,
            config: { [unowned self] in config }, transcriptionTimeout: timeout
        )
        session.onEvent = { [weak self] in self?.events.append($0) }
    }

    /// Runs the loop until the session is idle again (or fails after ~3 s).
    private func awaitIdle(file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0 ..< 600 {
            if session.phase == .idle { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("session did not return to idle (phase \(session.phase))", file: file, line: line)
    }

    private func dictate() async {
        session.press()
        XCTAssertEqual(session.phase, .recording)
        session.release()
        await awaitIdle()
    }

    // MARK: Happy path

    func testFullDictationRecordsTranscribesPostProcessesAndInserts() async {
        session.press()
        XCTAssertEqual(session.phase, .recording)
        XCTAssertEqual(recorder.startCalls.count, 1)
        XCTAssertEqual(recorder.startCalls.first?.uid, "mic-1")
        XCTAssertEqual(recorder.startCalls.first?.maxDuration, 120)
        XCTAssertEqual(presenter.calls, ["recording", "cue:start"])

        session.release()
        XCTAssertEqual(recorder.stopCalls, 1)
        XCTAssertEqual(session.phase, .transcribing)
        await awaitIdle()

        XCTAssertEqual(inserter.inserted.count, 1)
        XCTAssertEqual(inserter.inserted.first?.text, "Hello world ", "capitalised, trailing space")
        XCTAssertEqual(inserter.inserted.first?.strategy, .accessibilityThenPasteboard)
        XCTAssertEqual(session.lastTranscript, "Hello world")
        XCTAssertEqual(session.lastInsertionMethod, .accessibility)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(events, [.inserted(characters: 12, method: .accessibility)])
        XCTAssertEqual(presenter.calls, ["recording", "cue:start", "cue:stop", "working:Transcribing…", "hide"])
    }

    func testLevelsAreForwardedToThePresenter() {
        recorder.onLevel?(0.5)
        XCTAssertEqual(presenter.calls, ["level"])
    }

    func testSoundsRespectTheSetting() async {
        config.playSounds = false
        await dictate()
        XCTAssertFalse(presenter.calls.contains { $0.hasPrefix("cue:") })
    }

    // MARK: Guards before recording

    func testPressIsIgnoredWhileBusy() async {
        await models.scripted.set(delay: .milliseconds(200))
        session.press()
        session.release()
        XCTAssertEqual(session.phase, .transcribing)
        session.press()
        XCTAssertEqual(recorder.startCalls.count, 1, "second press while transcribing does nothing")
        await awaitIdle()
    }

    func testMicrophoneDeniedShowsMessageAndDoesNotStartRecording() {
        config.microphoneAuthorized = false
        session.press()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(recorder.startCalls.count, 0)
        XCTAssertEqual(presenter.calls, ["message:Microphone access is required"])
    }

    func testBlockedModelShowsItsReason() {
        models.availabilityValue = .blocked(reason: "Choose and download a model in Settings")
        session.press()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(recorder.startCalls.count, 0)
        XCTAssertEqual(presenter.calls, ["message:Choose and download a model in Settings"])
    }

    func testRecorderFailureReportsAndReturnsToIdle() {
        recorder.startError = TestError()
        session.press()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.lastError, "boom")
        XCTAssertEqual(presenter.calls, ["message:boom"])
    }

    // MARK: Cold model

    func testColdModelIsActivatedOnPressAndAwaitedAfterRelease() async {
        models.availabilityValue = .cold
        session.press()
        XCTAssertEqual(models.activateCalls, [.small], "loading starts while the user speaks")
        session.release()
        await awaitIdle()
        XCTAssertEqual(models.awaitCalls, [.small])
        XCTAssertEqual(inserter.inserted.count, 1)
        XCTAssertEqual(presenter.calls, ["recording", "cue:start", "cue:stop", "working:Loading model…", "working:Transcribing…", "hide"])
    }

    func testModelThatNeverBecomesReadyFails() async {
        models.availabilityValue = .cold
        models.awaitResult = false
        await dictate()
        XCTAssertEqual(inserter.inserted.count, 0)
        XCTAssertEqual(session.lastError, TranscriptionError.modelNotLoaded.errorDescription)
        XCTAssertEqual(events, [.failed(TranscriptionError.modelNotLoaded.errorDescription!)])
    }

    // MARK: Short, silent, empty

    func testTapShorterThanMinimumUtteranceIsDismissedSilently() async {
        recorder.nextRecording = Recording(samples: [Float](repeating: 0, count: 1_600), wallClockDuration: 0.1)
        await dictate()
        XCTAssertEqual(inserter.inserted.count, 0)
        let calls = await models.scripted.transcribeCalls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(presenter.calls.last, "hide")
        XCTAssertTrue(events.isEmpty)
    }

    func testSilentCaptureFailureIsReported() async {
        recorder.nextRecording = Recording(samples: [], wallClockDuration: 2.0, deviceName: "AirPods")
        await dictate()
        XCTAssertEqual(inserter.inserted.count, 0)
        XCTAssertTrue(session.lastError?.contains("“AirPods”") ?? false)
        XCTAssertEqual(events.count, 1)
        if case .failed = events[0] {} else { XCTFail("expected .failed, got \(events)") }
    }

    func testEmptyTranscriptShowsDidntCatchThat() async {
        await models.scripted.set(text: "   ")
        await dictate()
        XCTAssertEqual(inserter.inserted.count, 0)
        XCTAssertEqual(session.lastTranscript, "")
        XCTAssertEqual(presenter.calls.last, "message:Didn't catch that")
        XCTAssertEqual(events, [.noSpeech])
    }

    // MARK: Cancel, auto-stop, Bluetooth

    func testCancelWhileRecordingStopsWithoutTranscribing() async {
        session.press()
        session.cancel()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(recorder.stopCalls, 1)
        XCTAssertEqual(presenter.calls.last, "hide")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(inserter.inserted.count, 0)
        XCTAssertTrue(events.isEmpty)
    }

    func testAutoStopFinishesTheDictation() async {
        session.press()
        recorder.triggerAutoStop()
        await awaitIdle()
        XCTAssertEqual(inserter.inserted.count, 1)
        XCTAssertEqual(recorder.stopCalls, 0, "the recorder stopped itself")
    }

    func testBluetoothInputEmitsAnEventAfterInsertion() async {
        recorder.nextRecording = Recording(samples: Self.oneSecond.samples, wallClockDuration: 1, deviceName: "AirPods", deviceIsBluetooth: true)
        await dictate()
        XCTAssertEqual(events, [.inserted(characters: 12, method: .accessibility), .usedBluetoothInput])
    }

    // MARK: Failures after recording

    func testInsertionFailureIsReported() async {
        inserter.error = TestError()
        await dictate()
        XCTAssertEqual(session.lastError, "boom")
        XCTAssertEqual(events, [.failed("boom")])
        XCTAssertEqual(presenter.calls.last, "message:boom")
    }

    func testTranscriptionTimeoutReturnsToIdle() async {
        makeSession(timeout: .milliseconds(50))
        await models.scripted.set(delay: .seconds(2))
        await dictate()
        XCTAssertEqual(session.lastError, TranscriptionError.timedOut.errorDescription)
        XCTAssertEqual(inserter.inserted.count, 0)
        XCTAssertEqual(events, [.failed(TranscriptionError.timedOut.errorDescription!)])
    }

    func testTranscriptionErrorIsReported() async {
        await models.scripted.set(error: TestError())
        await dictate()
        // The fake throws raw; WhisperKitEngine wraps as TranscriptionError.failed.
        XCTAssertEqual(session.lastError, "boom")
        XCTAssertEqual(events, [.failed("boom")])
        XCTAssertEqual(inserter.inserted.count, 0)
    }

    // MARK: Sample insertion (Settings → Test insertion)

    func testInsertSampleUsesTheInserterAndReportsTheMethod() async {
        session = DictationSession(recorder: recorder, models: models, inserter: inserter, presenter: presenter,
                                   config: { [unowned self] in config }, sampleDelay: .milliseconds(10))
        inserter.method = .pasteboard
        session.insertSample()
        for _ in 0 ..< 200 where inserter.inserted.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(inserter.inserted.count, 1)
        XCTAssertTrue(inserter.inserted.first?.text.hasPrefix("Murmur insertion test") ?? false)
        XCTAssertEqual(session.lastInsertionMethod, .pasteboard)
        XCTAssertTrue(presenter.calls.last?.hasPrefix("message:Inserted via paste") ?? false)
    }
}
