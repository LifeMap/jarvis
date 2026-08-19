import AppKit
import SwiftUI

@main
struct JarvisCallBridgeApp: App {
    @StateObject private var model = BridgeViewModel()
    private let appDelegate: AppDelegate

    init() {
        let model = BridgeViewModel()
        _model = StateObject(wrappedValue: model)
        let delegate = AppDelegate(model: model)
        appDelegate = delegate
        NSApplication.shared.delegate = delegate
    }

    var body: some Scene {
        WindowGroup("Jarvis Call Bridge") {
            ContentView(model: model)
                .frame(minWidth: 640, minHeight: 620)
        }
    }
}

/// Phase 3 §16 — "app is intentionally quitting" is one of the immediate safety-restore
/// conditions: if a call is routed through the Jarvis devices when the app quits, the user's
/// original routes must come back before the process actually exits. `emergencyRestore` is
/// `async` (route convergence polling), so this can't happen inside the synchronous
/// `applicationWillTerminate` notification — `applicationShouldTerminate` + `.terminateLater` is
/// AppKit's sanctioned way to delay quitting for exactly this kind of bounded async cleanup.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: BridgeViewModel

    init(model: BridgeViewModel) {
        self.model = model
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.callAudioSession.emergencyRestore(reason: "app-quit")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
