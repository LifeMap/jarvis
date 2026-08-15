import AppKit
import ApplicationServices
import Combine
import Foundation

enum AXCallStateGuess: String {
    case unknown = "Unknown"
    case idleGuess = "Guess: Idle"
    case ringingGuess = "Guess: Ringing"
    case activeGuess = "Guess: Active"
    case endedGuess = "Guess: Ended"
}

/// Best-effort candidate for call-state detection via the Accessibility API, since CXCallObserver
/// is unavailable on native macOS (see CallStateMonitor.swift, which stays the authoritative,
/// honest "Public API Not Available" signal). This probe NEVER upgrades CallStateMonitor's
/// signal — its output is always prefixed "Guess" in the UI/logs so it can't be mistaken for a
/// verified call-state API. Per PRD §10.3/§22, Manual Start/Stop remains the required fallback
/// regardless of what this probe reports, and it is expected to stay `.unknown` in any
/// environment where nobody is present to grant the Accessibility permission prompt.
@MainActor
final class PhoneAppAccessibilityProbe: ObservableObject {
    @Published private(set) var state: AXCallStateGuess = .unknown
    @Published private(set) var trusted = false
    @Published private(set) var running = false

    private let logger: ProbeLogger
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var pollTask: Task<Void, Never>?

    init(logger: ProbeLogger) {
        self.logger = logger
    }

    func start() {
        guard !running else { return }
        running = true

        // Using the documented literal key value directly rather than the imported
        // `kAXTrustedCheckOptionPrompt` global, which the Swift 6 concurrency checker flags as
        // non-Sendable shared mutable state.
        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        logger.write("[CALL-AX] Accessibility trust=\(trusted). If false, grant this app access in System Settings > Privacy & Security > Accessibility, then Start again.")

        guard trusted else {
            state = .unknown
            return
        }

        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mobilephone").first else {
            logger.write("[CALL-AX] Phone.app is not running; guess probe idle until it launches")
            state = .unknown
            return
        }

        let element = AXUIElementCreateApplication(runningApp.processIdentifier)
        appElement = element
        logger.write("[CALL-AX] attached to Phone.app pid=\(runningApp.processIdentifier)")

        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.pollGuess(element: element)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        appElement = nil
        observer = nil
        running = false
        state = .unknown
        logger.write("[CALL-AX] guess probe stopped")
    }

    /// Walks the AX tree looking for button titles that plausibly indicate call UI state. This
    /// is inherently speculative — Phone.app's real AX hierarchy is unknown until a human
    /// inspects it live via dumpAXTree() during the real-device test, so these keyword matches
    /// are a starting point to refine, not a verified mapping.
    private func pollGuess(element: AXUIElement) {
        let titles = Self.collectButtonTitles(from: element, maxDepth: 6, maxNodes: 400)

        let ringingKeywords = ["decline", "answer", "거절", "수신"]
        let activeKeywords = ["end call", "hang up", "통화 종료", "mute"]

        let lowered = titles.map { $0.lowercased() }
        if lowered.contains(where: { title in ringingKeywords.contains(where: title.contains) }) {
            state = .ringingGuess
        } else if lowered.contains(where: { title in activeKeywords.contains(where: title.contains) }) {
            state = .activeGuess
        } else {
            state = .idleGuess
        }
    }

    /// Debug helper for the human tester: dumps role/title/description of the AX tree so stable
    /// anchors for real call states can be found live, since this cannot be discovered without a
    /// running Phone.app in an actual call.
    func dumpAXTree() {
        guard let appElement else {
            logger.write("[CALL-AX] dumpAXTree: not attached to Phone.app")
            return
        }
        logger.write("[CALL-AX] --- AX tree dump start ---")
        Self.dump(element: appElement, depth: 0, maxDepth: 8, logger: logger)
        logger.write("[CALL-AX] --- AX tree dump end ---")
    }

    private static func dump(element: AXUIElement, depth: Int, maxDepth: Int, logger: ProbeLogger) {
        guard depth <= maxDepth else { return }
        let role = stringAttribute(element, kAXRoleAttribute) ?? "?"
        let title = stringAttribute(element, kAXTitleAttribute) ?? ""
        let value = stringAttribute(element, kAXValueAttribute) ?? ""
        let indent = String(repeating: "  ", count: depth)
        logger.write("[CALL-AX] \(indent)role=\(role) title=\"\(title)\" value=\"\(value)\"")

        guard let children = childrenAttribute(element) else { return }
        for child in children {
            dump(element: child, depth: depth + 1, maxDepth: maxDepth, logger: logger)
        }
    }

    private static func collectButtonTitles(from element: AXUIElement, maxDepth: Int, maxNodes: Int) -> [String] {
        var titles: [String] = []
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth, visited < maxNodes else { return }
            visited += 1
            if let role = stringAttribute(element, kAXRoleAttribute), role == kAXButtonRole as String,
               let title = stringAttribute(element, kAXTitleAttribute), !title.isEmpty {
                titles.append(title)
            }
            guard let children = childrenAttribute(element) else { return }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(element, depth: 0)
        return titles
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private static func childrenAttribute(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? [AXUIElement]
    }
}
