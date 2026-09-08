import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import os

enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case noInputDevice
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already in progress."
        case .noInputDevice: return "No audio input device is available."
        case .converterUnavailable: return "The input format could not be converted to 16 kHz mono."
        }
    }
}

struct Recording {
    /// 16 kHz, mono, Float32 PCM in [-1, 1] — exactly what Whisper expects.
    let samples: [Float]
    /// How long the engine was running, regardless of how much audio arrived.
    let wallClockDuration: TimeInterval

    init(samples: [Float], wallClockDuration: TimeInterval = 0) {
        self.samples = samples
        self.wallClockDuration = wallClockDuration
    }

    var duration: TimeInterval { Double(samples.count) / AudioRecorder.sampleRate }

    /// The engine ran long enough for a real utterance but delivered nothing.
    /// On macOS this is what a microphone grant that no longer matches the
    /// app's code signature looks like: `AVCaptureDevice.authorizationStatus`
    /// still says authorized, the engine starts, and coreaudiod refuses IO
    /// (`HALC_ProxyIOContext … StartIO … error 35`). Must not be mistaken
    /// for a too-short tap and dismissed silently.
    func isSilentCaptureFailure(minimumUtterance: TimeInterval) -> Bool {
        samples.isEmpty && wallClockDuration >= minimumUtterance
    }
}

/// Captures microphone audio with `AVAudioEngine`, resamples it to 16 kHz
/// mono on the fly, publishes a smoothed input level for the indicator, and
/// enforces a maximum duration.
///
/// A fresh `AVAudioEngine` is created per recording so that input-device
/// changes made in settings take effect immediately and the engine never
/// carries stale state between utterances.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    /// Called on the main thread with a level in 0…1.
    var onLevel: ((Float) -> Void)?
    /// Called on the main thread when the maximum duration is reached.
    var onAutoStop: ((Recording) -> Void)?

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "murmur", category: "audio")
    private let lock = NSLock()

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var maxSamples = Int.max
    private var autoStopFired = false
    private var startedAt: Date?

    private(set) var isRecording = false

    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!

    // MARK: Control

    func start(inputDeviceUID: String?, maxDuration: TimeInterval) throws {
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let uid = inputDeviceUID, let deviceID = AudioDevices.deviceID(forUID: uid) {
            setInputDevice(deviceID, on: input)
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            throw AudioRecorderError.converterUnavailable
        }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(maxDuration * Self.sampleRate))
        maxSamples = Int(maxDuration * Self.sampleRate)
        autoStopFired = false
        lock.unlock()

        self.engine = engine
        self.converter = converter

        let ratio = Self.sampleRate / inputFormat.sampleRate
        // The converter is captured by the tap block so the render thread never
        // reads a property that the main thread may be clearing in `stop()`.
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self, converter] buffer, _ in
            self?.process(buffer: buffer, converter: converter, ratio: ratio)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            self.converter = nil
            throw error
        }
        isRecording = true
        startedAt = Date()
        log.debug("Recording started (\(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch)")
    }

    @discardableResult
    func stop() -> Recording {
        guard isRecording, let engine else {
            return Recording(samples: [])
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
        isRecording = false
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil

        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        if captured.isEmpty {
            log.error("Recording stopped after \(elapsed, privacy: .public) s with no audio; the HAL never delivered buffers")
        } else {
            log.debug("Recording stopped: \(captured.count, privacy: .public) samples")
        }
        return Recording(samples: captured, wallClockDuration: elapsed)
    }

    // MARK: Processing

    private func process(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, ratio: Double) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }

        let frames = Int(output.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel, count: frames))

        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        let rms = (sum / Float(max(frames, 1))).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let level = min(1, max(0, (db + 50) / 50)) // map -50 dBFS…0 dBFS → 0…1

        var reachedLimit = false
        lock.lock()
        if samples.count < maxSamples {
            let room = maxSamples - samples.count
            samples.append(contentsOf: chunk.prefix(room))
        }
        if samples.count >= maxSamples, !autoStopFired {
            autoStopFired = true
            reachedLimit = true
        }
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onLevel?(level)
            if reachedLimit {
                let recording = self.stop()
                self.onAutoStop?(recording)
            }
        }
    }

    /// Points the engine's input node at a specific device. The current-device
    /// property can only be changed while the underlying AudioUnit is
    /// uninitialised, and `AVAudioEngine` may already have initialised it, so
    /// bracket the write with uninitialise/initialise.
    private func setInputDevice(_ deviceID: AudioDeviceID, on node: AVAudioInputNode) {
        guard let unit = node.audioUnit else { return }
        var id = deviceID
        AudioUnitUninitialize(unit)
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        AudioUnitInitialize(unit)
        if status != noErr {
            log.error("Failed to select input device \(deviceID, privacy: .public): \(status, privacy: .public); using the system default")
            return
        }
        // Read the property back so the log says definitively whether the
        // override took effect (the only way to verify without a UI).
        var actual: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let readStatus = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size)
        if readStatus != noErr {
            log.error("Could not read back the input device (\(readStatus, privacy: .public))")
        } else if actual != deviceID {
            log.error("Input device override did not stick: requested \(deviceID, privacy: .public), unit reports \(actual, privacy: .public)")
        } else {
            log.info("Input device set to \(deviceID, privacy: .public) (\(AudioDevices.name(of: deviceID) ?? "unnamed", privacy: .public))")
        }
    }
}
