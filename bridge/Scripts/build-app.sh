#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

swift build -c debug

app_dir=".build/Jarvis Call Bridge.app"
contents_dir="$app_dir/Contents"
mkdir -p "$contents_dir/MacOS"
cp Info.plist "$contents_dir/Info.plist"
cp .build/debug/JarvisCallBridge "$contents_dir/MacOS/JarvisCallBridge"
codesign --force --sign - "$app_dir"

print "Built: $PWD/$app_dir"
