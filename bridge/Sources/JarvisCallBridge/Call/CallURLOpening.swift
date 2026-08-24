import AppKit
import Foundation

@MainActor
protocol CallURLOpening: AnyObject {
    func open(_ url: URL) -> Bool
}

@MainActor
final class WorkspaceCallURLOpener: CallURLOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
