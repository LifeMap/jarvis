#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

/// Lists Phone.app AX controls that look like an in-call audio-route picker.
/// Does not change CoreAudio defaults. Press is opt-in.
///
///   swift probe-phone-audio-route.swift list
///   swift probe-phone-audio-route.swift press --text "통신 오디오"

let keywords = ["오디오", "출력", "스피커", "수화기", "소리", "audio", "speaker", "output", "capture", "jarvis", "m80c", "수신"]

func attribute(_ element: AXUIElement, _ name: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success, let names else { return [] }
    return (names as NSArray).compactMap { $0 as? String }
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
    return (value as? [AXUIElement]) ?? []
}

struct Row {
    let role: String
    let title: String
    let description: String
    let value: String
    let identifier: String
    let actions: [String]
    var text: String { [role, title, description, value, identifier].joined(separator: " ") }
}

func walk(_ element: AXUIElement, depth: Int, limit: Int, into rows: inout [Row]) {
    guard rows.count < limit, depth < 18 else { return }
    let row = Row(
        role: attribute(element, kAXRoleAttribute as String) ?? "",
        title: attribute(element, kAXTitleAttribute as String) ?? "",
        description: attribute(element, kAXDescriptionAttribute as String) ?? "",
        value: attribute(element, kAXValueAttribute as String) ?? "",
        identifier: attribute(element, kAXIdentifierAttribute as String) ?? "",
        actions: actions(element)
    )
    let hay = row.text.lowercased()
    if keywords.contains(where: { hay.contains($0.lowercased()) }) {
        rows.append(row)
    }
    for child in children(element) {
        walk(child, depth: depth + 1, limit: limit, into: &rows)
    }
}

func phonePID() -> pid_t? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.mobilephone" }?.processIdentifier
}

func parseArgs() -> (mode: String, text: String) {
    let args = Array(CommandLine.arguments.dropFirst())
    let mode = args.first ?? "list"
    var text = "통신 오디오"
    if let index = args.firstIndex(of: "--text"), index + 1 < args.count {
        text = args[index + 1]
    }
    return (mode, text)
}

guard AXIsProcessTrusted() else {
    fputs("FAIL Terminal/swift is not Accessibility-trusted. Use Jarvis Focused Call AX Snapshot instead.\n", stderr)
    exit(1)
}

guard let pid = phonePID() else {
    fputs("FAIL Phone.app is not running\n", stderr)
    exit(1)
}

let app = AXUIElementCreateApplication(pid)
var rows: [Row] = []
walk(app, depth: 0, limit: 200, into: &rows)
print("phone pid=\(pid) audio-like controls=\(rows.count)")
for row in rows {
    print("  role=\(row.role) title=\"\(row.title)\" description=\"\(row.description)\" value=\"\(row.value)\" id=\(row.identifier) actions=\(row.actions.joined(separator: ","))")
}

let parsed = parseArgs()
if parsed.mode == "press" {
    func find(_ element: AXUIElement) -> AXUIElement? {
        let title = attribute(element, kAXTitleAttribute as String) ?? ""
        let description = attribute(element, kAXDescriptionAttribute as String) ?? ""
        if title.contains(parsed.text) || description.contains(parsed.text) {
            return element
        }
        for child in children(element) {
            if let match = find(child) { return match }
        }
        return nil
    }
    guard let target = find(app) else {
        print("FAIL no control matching \(parsed.text)")
        exit(2)
    }
    let status = AXUIElementPerformAction(target, kAXPressAction as CFString)
    print("press text=\(parsed.text) status=\(status.rawValue)")
}
