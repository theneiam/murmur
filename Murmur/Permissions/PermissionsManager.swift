import Foundation
import AVFoundation
import AppKit
import ApplicationServices

/// Tracks the two permissions Murmur needs and offers the right remediation
/// for each state (request, or send the user to System Settings when denied).
@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var microphone: AVAuthorizationStatus = .notDetermined
    @Published private(set) var accessibility = false

    private var pollTimer: Timer?

    init() {
        refresh()
    }

    var allGranted: Bool { microphone == .authorized && accessibility }

    func refresh() {
        // Only publish real changes; this runs on a timer and every write
        // would otherwise re-render each observing view.
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphone { microphone = mic }
        let ax = AXIsProcessTrusted()
        if ax != accessibility { accessibility = ax }
    }

    // MARK: Microphone

    func requestMicrophone() async {
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refresh()
    }

    // MARK: Accessibility

    /// Shows the system prompt the first time; afterwards macOS only lists the
    /// app in System Settings, so we also offer a direct link.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: System Settings deep links

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Polling

    /// Accessibility grants don't notify the app, so poll. Each client
    /// registers the interval it needs and the timer runs at the fastest one
    /// currently requested: the app keeps a slow background poll alive for
    /// its whole lifetime and onboarding adds a faster one while it is on
    /// screen. Stop with the same interval you started with.
    private var requestedIntervals: [TimeInterval] = []
    /// Interval the timer is currently armed at; `nil` when not polling.
    private(set) var pollInterval: TimeInterval?

    func startPolling(interval: TimeInterval) {
        requestedIntervals.append(interval)
        rearmTimer()
    }

    func stopPolling(interval: TimeInterval) {
        if let index = requestedIntervals.firstIndex(of: interval) {
            requestedIntervals.remove(at: index)
        }
        rearmTimer()
    }

    private func rearmTimer() {
        let target = requestedIntervals.min()
        guard target != pollInterval else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = target
        guard let target else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: target, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }
}
