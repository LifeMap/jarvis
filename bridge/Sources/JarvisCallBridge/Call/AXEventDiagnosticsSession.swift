import ApplicationServices
import Foundation

/// PRD §8 diagnostic: distinguishes (A) no AX notification ever arrives, (B) a notification
/// arrives but the resolver would reject the element, or (C) the wrong process is being watched.
/// Strictly read-only — registers `AXObserver` notifications and logs them; never calls
/// `AXUIElementPerformAction` or touches focus/UI. Auto-stops after `durationSeconds` so it can
/// never silently run forever, and throttles logging so a noisy process can't flood the log.
///
/// Secondary to the raw discovery dump (which is what the CHECKPOINT 2 retest steps actually
/// call for) — this exists for follow-up investigation if the raw dump alone isn't conclusive.
final class AXEventDiagnosticsSession {
    // Plain `[String]` rather than `[CFString]` — `CFString` isn't `Sendable`, and this static
    // constant only needs the values converted to `CFString` at the point of use.
    private static let watchedNotifications: [String] = [
        kAXWindowCreatedNotification as String,
        kAXFocusedWindowChangedNotification as String,
        kAXApplicationActivatedNotification as String,
        kAXUIElementDestroyedNotification as String,
        kAXValueChangedNotification as String
    ]

    private static let maxLoggedEvents = 200

    private var registrations: [(observer: AXObserver, source: CFRunLoopSource)] = []
    private var onEvent: ((String) -> Void)?
    private var onStopped: (() -> Void)?
    private var stopWorkItem: DispatchWorkItem?
    private var loggedCount = 0

    /// Diagnostic Fix #2: exposes whether a session is actually running, so callers (the
    /// Start/Stop button state in `ContentView`, via `BridgeViewModel`) never show "Stop" as
    /// actionable when there is nothing to stop.
    var isRunning: Bool { !registrations.isEmpty }

    func start(processes: [AXProcessSummary], durationSeconds: TimeInterval, onEvent: @escaping (String) -> Void, onStopped: @escaping () -> Void) {
        stop()
        guard AXIsProcessTrusted() else {
            onEvent("[AX-EVENT] not started — Accessibility not trusted")
            onStopped()
            return
        }

        self.onEvent = onEvent
        self.onStopped = onStopped
        self.loggedCount = 0
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for process in processes {
            var observer: AXObserver?
            let status = AXObserverCreate(process.pid, axEventDiagnosticsCallback, &observer)
            guard status == .success, let observer else { continue }

            let appElement = AXUIElementCreateApplication(process.pid)
            for notification in Self.watchedNotifications {
                AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            }

            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            registrations.append((observer, source))
        }

        onEvent("[AX-EVENT] session started, watching \(registrations.count) process(es) for \(Int(durationSeconds))s")

        let workItem = DispatchWorkItem { [weak self] in self?.stop() }
        stopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + durationSeconds, execute: workItem)
    }

    func stop() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        for registration in registrations {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), registration.source, .defaultMode)
        }
        let wasRunning = !registrations.isEmpty
        registrations.removeAll()
        if wasRunning {
            onEvent?("[AX-EVENT] session stopped")
        }
        onEvent = nil
        let stoppedCallback = onStopped
        onStopped = nil
        if wasRunning {
            stoppedCallback?()
        }
    }

    fileprivate func handleEvent(element: AXUIElement, notification: CFString) {
        guard loggedCount < Self.maxLoggedEvents else { return }
        loggedCount += 1

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let role = SystemAccessibilityClient.attribute(element, kAXRoleAttribute) as? String
        let title = AXRedaction.redact(SystemAccessibilityClient.attribute(element, kAXTitleAttribute) as? String)

        onEvent?("[AX-EVENT] pid=\(pid) notification=\(notification as String) role=\(role ?? "?") title=\(title ?? "-")")
    }
}

/// Must be a context-free function (no captures) to be usable as an `AXObserverCallback` C
/// function pointer — `refcon` is how it gets back to the owning `AXEventDiagnosticsSession`.
private let axEventDiagnosticsCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let session = Unmanaged<AXEventDiagnosticsSession>.fromOpaque(refcon).takeUnretainedValue()
    session.handleEvent(element: element, notification: notification)
}
