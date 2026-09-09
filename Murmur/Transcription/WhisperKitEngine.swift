import Foundation
import os
import WhisperKit

/// Local Whisper inference through WhisperKit (CoreML, Apple Neural Engine +
/// GPU). The loaded pipeline is kept in memory for the lifetime of the app so
/// repeated dictations pay no reload cost.
actor WhisperKitEngine: TranscriptionEngine {
    private var pipeline: WhisperKit?
    private var model: WhisperModel?
    /// Incremented by every `load`/`unload`. The actor is re-entrant while
    /// awaiting `WhisperKit(config)`, so a load that finishes after a newer
    /// load or unload began must not install its pipeline over theirs.
    private var generation = 0
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "murmur", category: "whisper")

    var loadedModel: WhisperModel? { model }

    func load(model: WhisperModel, folder: URL, tokenizerFolder: URL) async throws {
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw TranscriptionError.modelFolderMissing(model)
        }
        generation += 1
        let myGeneration = generation

        // Drop the previous pipeline first so two large models never coexist.
        if let old = pipeline {
            await old.unloadModels()
            pipeline = nil
            self.model = nil
        }

        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: tokenizerFolder,
            // Default compute options: mel on GPU, encoder + decoder on the
            // Neural Engine — the fastest combination on Apple Silicon.
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )

        let started = Date()
        let pipe = try await WhisperKit(config)
        guard myGeneration == generation else {
            await pipe.unloadModels()
            throw CancellationError()
        }
        pipeline = pipe
        self.model = model
        log.info("Loaded \(model.rawValue, privacy: .public) in \(Date().timeIntervalSince(started), privacy: .public) s")
    }

    func unload() async {
        generation += 1
        if let pipe = pipeline {
            await pipe.unloadModels()
        }
        pipeline = nil
        model = nil
    }

    func transcribe(samples: [Float], language: TranscriptionLanguage) async throws -> Transcript {
        guard let pipeline else { throw TranscriptionError.modelNotLoaded }

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language.whisperCode
        options.detectLanguage = language.whisperCode == nil
        options.usePrefillPrompt = true
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.temperatureFallbackCount = 2
        options.compressionRatioThreshold = 2.4
        options.logProbThreshold = -1.0
        options.noSpeechThreshold = 0.6
        // Long recordings (up to the 2-minute cap) are split on silence and
        // the chunks decoded concurrently; short utterances are a single chunk.
        options.chunkingStrategy = .vad
        options.concurrentWorkerCount = 4

        let started = Date()
        do {
            let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
            let text = results
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let elapsed = Date().timeIntervalSince(started)
            log.info("Transcribed \(samples.count / 16_000, privacy: .public) s of audio in \(elapsed, privacy: .public) s")
            return Transcript(text: text, language: results.first?.language, processingTime: elapsed)
        } catch {
            throw TranscriptionError.failed(underlying: error)
        }
    }
}
