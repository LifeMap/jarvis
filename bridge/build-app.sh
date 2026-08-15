#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
swift build -c debug

app_dir=".build/Jarvis Call Bridge Feasibility.app"
contents_dir="$app_dir/Contents"
mkdir -p "$contents_dir/MacOS"
cp Info.plist "$contents_dir/Info.plist"
cp .build/debug/JarvisCallBridgeFeasibility "$contents_dir/MacOS/JarvisCallBridgeFeasibility"

# NOTE on tx-sample.wav / Bundle.module: SwiftPM's generated resource_bundle_accessor.swift falls
# back to a hardcoded absolute path under .build/arm64-apple-macosx/debug/ when the resource
# bundle isn't found next to Bundle.main (which, for this hand-assembled .app, it never is — see
# below). That fallback resolves correctly as long as this checkout's .build/ directory isn't
# deleted, so nothing needs to be copied here. Copying the resource bundle into the .app instead
# was tried and reverted: codesign rejects both Contents/MacOS/*.bundle ("bundle format
# unrecognized") and a bare .app-root copy ("unsealed contents present in the bundle root"),
# because Bundle.module's primary lookup path (Bundle.main.bundleURL + name) assumes running the
# raw SwiftPM binary, not a packaged .app — a real product target would need its own resource
# accessor / Xcode-managed Copy Bundle Resources step, out of scope for this Phase 0 spike.
codesign --force --sign - "$app_dir"

print "Built: $PWD/$app_dir"
