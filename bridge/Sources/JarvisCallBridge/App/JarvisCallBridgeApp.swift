import SwiftUI

@main
struct JarvisCallBridgeApp: App {
    @StateObject private var model = BridgeViewModel()

    var body: some Scene {
        WindowGroup("Jarvis Call Bridge") {
            ContentView(model: model)
                .frame(minWidth: 640, minHeight: 620)
        }
    }
}
