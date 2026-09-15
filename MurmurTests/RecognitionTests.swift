@testable import Murmur
import XCTest

/// WhisperKit's decode loop never runs when the audio is 1.0 s or shorter, so
/// short confirmations ("да", "ok", "ship it") came back empty and were
/// reported as "Didn't catch that". Padding with silence costs nothing: the
/// mel window is zero-padded to 30 s regardless.
final class AudioPaddingTests: XCTestCase {
    private let rate = Int(AudioRecorder.sampleRate)

    func testAudioShorterThanTheFloorIsPaddedUpToIt() {
        let half = [Float](repeating: 0.5, count: rate / 2)
        let padded = AudioPadding.padded(half)
        XCTAssertGreaterThan(padded.count, rate, "must clear WhisperKit's 16 000-frame floor")
        XCTAssertEqual(padded.count, AudioPadding.minimumFrames)
    }

    func testExactlyOneSecondIsStillPadded() {
        // The loop condition is `> 16000`, so exactly 1.0 s also decodes to nothing.
        let padded = AudioPadding.padded([Float](repeating: 0.5, count: rate))
        XCTAssertGreaterThan(padded.count, rate)
    }

    func testTheOriginalSamplesAreKeptAtTheFrontUnchanged() {
        let original: [Float] = [0.1, -0.2, 0.3]
        let padded = AudioPadding.padded(original)
        XCTAssertEqual(Array(padded.prefix(3)), original)
        XCTAssertTrue(padded.dropFirst(3).allSatisfy { $0 == 0 }, "padding is silence")
    }

    func testAudioAlreadyLongEnoughIsReturnedUntouched() {
        let long = [Float](repeating: 0.5, count: rate * 3)
        XCTAssertEqual(AudioPadding.padded(long).count, long.count)
    }

    func testEmptyAudioIsLeftAlone() {
        XCTAssertTrue(AudioPadding.padded([]).isEmpty, "nothing to transcribe; the caller handles this")
    }
}

/// A muted microphone delivers buffers full of zeros, which clears the
/// minimum-utterance gate and produces "Didn't catch that" — identical to
/// saying nothing. The recorder already computes a level per buffer.
final class SilentInputTests: XCTestCase {
    private func recording(peak: Float, seconds: Double = 2) -> Recording {
        Recording(samples: [Float](repeating: 0.1, count: Int(AudioRecorder.sampleRate * seconds)),
                  wallClockDuration: seconds, deviceName: "MacBook Pro Microphone", peakLevel: peak)
    }

    func testAudioWithNoSignalIsTreatedAsACaptureFailure() {
        XCTAssertTrue(recording(peak: 0).hasNoAudibleSignal)
        XCTAssertTrue(recording(peak: 0.0005).hasNoAudibleSignal, "below about -45 dBFS is silence")
    }

    func testNormalSpeechIsNotACaptureFailure() {
        XCTAssertFalse(recording(peak: 0.02).hasNoAudibleSignal)
        XCTAssertFalse(recording(peak: 0.8).hasNoAudibleSignal)
    }

    func testTheMessageNamesTheDeviceSoTheUserKnowsWhereToLook() {
        let message = recording(peak: 0).silentInputMessage
        XCTAssertTrue(message.contains("MacBook Pro Microphone"))
        XCTAssertTrue(message.lowercased().contains("mute"), "points at the actual likely cause")
    }

    func testPeakDefaultsToUnknownSoOlderCallSitesAreUnaffected() {
        XCTAssertFalse(Recording(samples: [0.1], wallClockDuration: 1).hasNoAudibleSignal,
                       "no measurement means no accusation")
    }
}

/// Whisper reports which language it decoded. Murmur discarded it, so a
/// bilingual user could not tell a mis-detection from a mis-hearing.
@MainActor
final class DetectedLanguageTests: XCTestCase {
    func testTheDetectedLanguageReachesTheDictationOutcome() async {
        let recorder = FakeRecorder()
        let models = FakeModels()
        let inserter = FakeInserter()
        let presenter = FakePresenter()
        await models.scripted.setLanguage("ru")
        recorder.nextRecording = Recording(samples: [Float](repeating: 0.1, count: 16_000),
                                           wallClockDuration: 1, peakLevel: 0.3)
        var events: [DictationEvent] = []
        let session = DictationSession(
            recorder: recorder, models: models, inserter: inserter, presenter: presenter,
            config: {
                DictationConfig(model: .small, language: .auto, postProcessing: PostProcessingOptions(),
                                insertionStrategy: .accessibilityThenPasteboard, inputDeviceUID: nil,
                                maxRecordingSeconds: 120, playSounds: false, microphoneAuthorized: true)
            }
        )
        session.onEvent = { events.append($0) }
        session.press()
        session.release()
        for _ in 0 ..< 400 where session.phase != .idle { try? await Task.sleep(for: .milliseconds(5)) }

        guard case let .inserted(outcome) = events.first else { return XCTFail("no insertion: \(events)") }
        XCTAssertEqual(outcome.detectedLanguage, "ru")
    }
}

final class TranscriptionLanguageCatalogTests: XCTestCase {
    func testCatalogExposesTheWhisperLanguageSetWithoutDuplicateCodes() {
        let languages = TranscriptionLanguage.allCases
        XCTAssertGreaterThanOrEqual(languages.count, 99)
        XCTAssertEqual(Set(languages.map(\.rawValue)).count, languages.count)
        for language in [TranscriptionLanguage.english, .russian, .ukrainian, .polish, .japanese, .arabic] {
            XCTAssertTrue(languages.contains(language))
            XCTAssertFalse(language.displayName.isEmpty)
        }
    }

    func testLanguageStillEncodesAsItsLegacySingleString() throws {
        let data = try JSONEncoder().encode(TranscriptionLanguage.polish)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #""pl""#)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionLanguage.self, from: data), .polish)
    }
}

final class RecognitionMetricsTests: XCTestCase {
    func testCountsDeletionInsertionAndSubstitution() {
        XCTAssertEqual(RecognitionMetrics.score(reference: "the quick brown fox", hypothesis: "the quick fox"),
                       RecognitionScore(substitutions: 0, deletions: 1, insertions: 0, referenceWords: 4))
        XCTAssertEqual(RecognitionMetrics.score(reference: "hello world", hypothesis: "hello brave world"),
                       RecognitionScore(substitutions: 0, deletions: 0, insertions: 1, referenceWords: 2))
        XCTAssertEqual(RecognitionMetrics.score(reference: "ship right now", hypothesis: "ship it now"),
                       RecognitionScore(substitutions: 1, deletions: 0, insertions: 0, referenceWords: 3))
    }

    func testNormalizationIgnoresCaseAndPunctuationButPreservesWordsAcrossLanguages() {
        XCTAssertEqual(RecognitionMetrics.score(reference: "Hello, WORLD!", hypothesis: "hello world").wordErrorRate, 0)
        XCTAssertEqual(RecognitionMetrics.score(reference: "Привіт, світе!", hypothesis: "привіт світе").wordErrorRate, 0)
    }

    func testEmptyReferenceHasDefinedErrorRate() {
        XCTAssertEqual(RecognitionMetrics.score(reference: "", hypothesis: "").wordErrorRate, 0)
        XCTAssertEqual(RecognitionMetrics.score(reference: "", hypothesis: "extra words").wordErrorRate, 2)
    }
}
