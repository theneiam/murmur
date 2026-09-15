import Foundation
import os

enum InsertionStrategy: String, CaseIterable, Codable, Identifiable {
    /// Try the Accessibility API; if the focused app does not accept it,
    /// paste instead. Recommended.
    case accessibilityThenPasteboard
    /// Accessibility only. Never touches the clipboard; fails silently in
    /// apps that do not support it.
    case accessibilityOnly
    /// Always paste (⌘V) and restore the previous clipboard afterwards.
    case pasteboardOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accessibilityThenPasteboard: return "Accessibility, fall back to paste"
        case .accessibilityOnly: return "Accessibility only"
        case .pasteboardOnly: return "Paste (⌘V) only"
        }
    }

    var detail: String {
        switch self {
        case .accessibilityThenPasteboard:
            return "Inserts directly at the caret without using the clipboard; pastes only in apps that don't support it."
        case .accessibilityOnly:
            return "Never touches the clipboard. Some apps (terminals, a few editors) will not receive text."
        case .pasteboardOnly:
            return "Sends ⌘V to the intended app. Murmur reports the paste event, but cannot verify that every app accepted it; your previous clipboard contents are restored when safe."
        }
    }
}

/// Which path actually delivered the text.
enum InsertionMethod: String {
    case accessibility
    case pasteboard

    var displayName: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .pasteboard: return "paste (⌘V)"
        }
    }
}

enum InsertionError: LocalizedError, Equatable {
    case accessibilityRejected, pasteRejected, destinationChanged, destinationUnavailable
    var errorDescription: String? {
        switch self {
        case .accessibilityRejected: return "The focused app did not accept text via Accessibility. Try the paste fallback in Settings."
        case .pasteRejected: return "The paste could not be sent. Copy the last transcript from Murmur's menu."
        case .destinationChanged: return "The destination changed. Nothing more was inserted. Return to your text field and use Paste Last Transcript."
        case .destinationUnavailable: return "Click into a text field in another app first. Your last transcript is available in Murmur's menu."
        }
    }
}

enum DeliveryStatus: String, Codable { case verified, unverified }

enum TextWriteResult { case rejected, verified, unverified }

struct InsertionResult: Equatable {
    var method: InsertionMethod
    var delivery: DeliveryStatus
    /// Exact text offered to the destination, after its layout policy.
    var text: String

    var summary: String {
        delivery == .verified ? "Inserted via \(method.displayName)" : "Sent via \(method.displayName); delivery unverified"
    }
}

@MainActor
protocol TextWriting: AnyObject {
    func write(_ text: String, to destination: InsertionDestination?) async -> TextWriteResult
}

@MainActor
final class AccessibilityWriter: TextWriting {
    func write(_ text: String, to destination: InsertionDestination?) async -> TextWriteResult {
        guard let destination, FrontmostDestination().matches(destination) else { return .rejected }
        return await Task.detached(priority: .userInitiated) {
            AccessibilityInserter.insert(text, into: destination)
        }.value
    }
}

@MainActor
final class PasteboardWriter: TextWriting {
    func write(_ text: String, to destination: InsertionDestination?) async -> TextWriteResult {
        guard let destination else { return .rejected }
        let sent = await PasteboardInserter.insert(text) { FrontmostDestination().matches(destination) }
        return sent ? .unverified : .rejected
    }
}

/// Resolves delivery and fallback without ever treating a successful OS call
/// as proof of delivery. An ambiguous AX write is not pasted a second time.
@MainActor
final class StrategyInserter: TextInserting {
    private let accessibility: any TextWriting
    private let pasteboard: any TextWriting
    private let destinations: (any DestinationChecking)?

    init(accessibility: any TextWriting, pasteboard: any TextWriting, destinations: (any DestinationChecking)? = nil) {
        self.accessibility = accessibility
        self.pasteboard = pasteboard
        self.destinations = destinations
    }

    static func live() -> StrategyInserter {
        StrategyInserter(accessibility: AccessibilityWriter(), pasteboard: PasteboardWriter(), destinations: FrontmostDestination())
    }

    func captureDestination() -> InsertionDestination? { destinations?.capture() }

    func insert(_ text: String, strategy: InsertionStrategy) async throws -> InsertionResult {
        try await insert(text, strategy: strategy, destination: captureDestination())
    }

    func insert(_ input: String, strategy: InsertionStrategy, destination: InsertionDestination?) async throws -> InsertionResult {
        guard !input.isEmpty else { return InsertionResult(method: .accessibility, delivery: .verified, text: "") }
        try validate(destination)
        let text = destination.map { LayoutPolicy.adapt(input, for: $0.layoutTarget) } ?? input
        if strategy != .pasteboardOnly {
            let result = await accessibility.write(text, to: destination)
            switch result {
            case .verified: return InsertionResult(method: .accessibility, delivery: .verified, text: text)
            case .unverified: return InsertionResult(method: .accessibility, delivery: .unverified, text: text)
            case .rejected:
                if strategy == .accessibilityOnly { throw InsertionError.accessibilityRejected }
            }
        }
        try Task.checkCancellation()
        try validate(destination)
        switch await pasteboard.write(text, to: destination) {
        case .rejected: throw InsertionError.pasteRejected
        case .verified: return InsertionResult(method: .pasteboard, delivery: .verified, text: text)
        case .unverified: return InsertionResult(method: .pasteboard, delivery: .unverified, text: text)
        }
    }

    private func validate(_ destination: InsertionDestination?) throws {
        guard let destinations else { return } // pure test adapters
        guard let destination else { throw InsertionError.destinationUnavailable }
        guard destinations.matches(destination) else { throw InsertionError.destinationChanged }
    }
}
