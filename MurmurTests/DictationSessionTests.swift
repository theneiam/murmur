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
    /// What the engine claims it detected, independent of the requested language.
    var detectedLanguage: String?
    var delay: Duration = .zero
    var error: Error?
    var ignoresCancellation = false
    private(set) var transcribeCalls = 0
    var loadedModel: WhisperModel? { nil }

    func set(text: String) { self.text = text }
    func setLanguage(_ code: String?) { detectedLanguage = code }
    func set(delay: Duration) { self.delay = delay }
    func set(error: Error?) { self.error = error }
    func setIgnoringCancellation() { ignoresCancellation = true }

    func load(model: WhisperModel, folder: URL, tokenizerFolder: URL) async throws {}
    func unload() async {}
    func transcribe(samples: [Float], language: TranscriptionLanguage) async throws -> Transcript {
        transcribeCalls += 1
        if ignoresCancellation {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) { continuation.resume() }
            }
        } else if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        return Transcript(text: text, language: detectedLanguage, processingTime: 0.1)
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
    var delivery: DeliveryStatus = .verified
    var destination = InsertionDestination(processID: 100, bundleIdentifier: "test.editor")
    var delay: Duration = .zero
    private(set) var receivedDestination: InsertionDestination?
    var error: Error?
    private(set) var inserted: [(text: String, strategy: InsertionStrategy)] = []

    func captureDestination() -> InsertionDestination? { destination }

    func insert(_ text: String, strategy: InsertionStrategy, destination: InsertionDestination?) async throws -> InsertionResult {
        receivedDestination = destination
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        inserted.append((text, strategy))
        return InsertionResult(method: method, delivery: delivery, text: text)
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

    private func makeSession(
        timeout: Duration = .seconds(5),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        session = DictationSession(
            recorder: recorder, models: models, inserter: inserter, presenter: presenter,
            config: { [unowned self] in config }, transcriptionTimeout: timeout, now: now
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
        XCTAssertEqual(events.count, 1)
        guard case let .inserted(outcome) = events[0] else { return XCTFail("expected .inserted, got \(events)") }
        XCTAssertEqual(outcome.characters, 12)
        XCTAssertEqual(outcome.words, 2)
        XCTAssertEqual(outcome.method, .accessibility)
        XCTAssertEqual(outcome.model, .small)
        XCTAssertEqual(outcome.recordedSeconds, 1.0, accuracy: 0.001)
        XCTAssertEqual(outcome.transcriptionSeconds, 0.1, accuracy: 0.001)
        XCTAssertEqual(presenter.calls, ["recording", "cue:start", "cue:stop", "working:Transcribing…", "hide"])
    }

    func testDestinationProfileIsSnapshottedAtPress() async {
        inserter.destination.bundleIdentifier = "com.example.Editor"
        var profiled = config!
        profiled.postProcessing.replacements = [Replacement(find: "hello world", replace: "profile text")]
        session = DictationSession(
            recorder: recorder,
            models: models,
            inserter: inserter,
            presenter: presenter,
            config: { [unowned self] in config },
            destinationConfig: { bundleIdentifier in
                XCTAssertEqual(bundleIdentifier, "com.example.Editor")
                return profiled
            }
        )

        session.press()
        // A later settings mutation cannot change this dictation's snapshot.
        profiled.postProcessing.replacements = []
        session.release()
        await awaitIdle()

        XCTAssertEqual(inserter.inserted.first?.text, "Profile text ")
    }

    func testCancelDuringInsertionStopsLateCompletion() async {
        inserter.delay = .milliseconds(300)
        session.press()
        session.release()
        for _ in 0 ..< 200 where session.phase != .inserting { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.phase, .inserting)

        session.cancel()
        XCTAssertEqual(session.phase, .idle)
        try? await Task.sleep(for: .milliseconds(350))

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertFalse(events.contains { if case .inserted = $0 { return true }
            return false
        })
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

    func testDestinationIsCapturedBeforeTranscriptionAndDoesNotFollowFocus() async {
        await models.scripted.set(delay: .milliseconds(50))
        session.press()
        session.release()
        inserter.destination = InsertionDestination(processID: 200, bundleIdentifier: "other.app")
        await awaitIdle()
        XCTAssertEqual(inserter.receivedDestination?.processID, 100)
    }

    func testRawTranscriptSurvivesPostProcessingAndInsertionFailure() async {
        config.postProcessing.replacements = [Replacement(find: "hello", replace: "Greetings")]
        inserter.error = TestError()
        await dictate()
        XCTAssertEqual(session.lastRawTranscript, "hello world")
        XCTAssertEqual(session.lastTranscript, "Greetings world")
    }

    func testTimingSeparatesEveryStageAndUsesOneDeliveryTimestamp() async {
        var timestamps = [10.0, 12.0, 15.0, 16.0, 20.0].makeIterator()
        makeSession(now: { timestamps.next()! })

        await dictate()

        XCTAssertEqual(session.lastTiming, DictationTiming(
            modelWait: 2,
            transcription: 3,
            postProcessing: 1,
            insertion: 4,
            releaseToDelivery: 10
        ))
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

    func testCancelDuringTranscriptionReturnsImmediatelyAndNeverInserts() async {
        await models.scripted.set(delay: .milliseconds(200))
        session.press()
        session.release()
        await Task.yield()
        session.cancel()
        XCTAssertEqual(session.phase, .idle)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(inserter.inserted.isEmpty)
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
        XCTAssertEqual(events.count, 2)
        guard case .inserted = events[0] else { return XCTFail("expected .inserted first, got \(events)") }
        XCTAssertEqual(events[1], .usedBluetoothInput)
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

    func testTimeoutReturnsBeforeUncooperativeEngineAndRejectsLateResult() async {
        makeSession(timeout: .milliseconds(20))
        await models.scripted.setIgnoringCancellation()
        session.press()
        session.release()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.lastError, TranscriptionError.timedOut.errorDescription)
        XCTAssertTrue(session.hasPendingWork, "the engine remains leased until it actually stops")
        session.press()
        XCTAssertEqual(recorder.startCalls.count, 1, "never pile another inference onto stalled CoreML")
        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertFalse(session.hasPendingWork)
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
