/// Capture and engine generations keep delayed buffers and watchdogs from
/// affecting a replacement engine or a later dictation. Used under the
/// recorder's lock; no hardware is needed to exercise the recovery policy.
struct AudioRestartPolicy {
    let maxRestarts: Int
    private(set) var captureGeneration = 0
    private(set) var engineGeneration = 0
    private(set) var restartCount = 0
    private var active = false
    private var receivedBuffer = false

    init(maxRestarts: Int) {
        self.maxRestarts = maxRestarts
    }

    mutating func beginCapture() {
        captureGeneration += 1
        restartCount = 0
        active = true
    }

    mutating func beginEngine() -> Int {
        engineGeneration += 1
        receivedBuffer = false
        return engineGeneration
    }

    mutating func acceptBuffer(generation: Int) -> Bool {
        guard isCurrentEngine(generation) else { return false }
        receivedBuffer = true
        return true
    }

    func isCurrentEngine(_ generation: Int) -> Bool {
        active && generation == engineGeneration
    }

    func isCurrentCapture(_ generation: Int) -> Bool {
        active && generation == captureGeneration
    }

    func shouldRestartAfterSilence(generation: Int) -> Bool {
        isCurrentEngine(generation) && !receivedBuffer
    }

    mutating func requestRestart() -> Bool {
        guard active, restartCount < maxRestarts else { return false }
        restartCount += 1
        return true
    }

    mutating func endCapture() {
        active = false
    }
}
