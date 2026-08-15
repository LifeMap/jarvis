#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

# CB Phase 0-B. Compiles the "Jarvis Virtual Mic" CoreAudio HAL Audio Server Plug-in with plain
# clang (no Xcode project, no DriverKit system extension) and assembles it into a .driver bundle.
#
# This script ONLY compiles and assembles the bundle locally in this directory. It never copies
# anything into /Library/Audio/Plug-Ins/HAL and never touches coreaudiod. Run install.sh yourself
# afterward, on purpose, as a separate step.

build_dir="build"
driver_name="JarvisVirtualMic"
driver_bundle="$build_dir/$driver_name.driver"

rm -rf "$build_dir"
mkdir -p "$build_dir" "$driver_bundle/Contents/MacOS"

echo "Compiling..."
clang -Wall -Wextra -std=c11 -c -I Shared/include -o "$build_dir/JarvisVMicRing.o" Shared/JarvisVMicRing.c
clang -Wall -Wextra -std=c11 -c -I Shared/include -o "$build_dir/PlugInEntry.o" PlugInEntry.c
clang -Wall -Wextra -std=c11 -c -I Shared/include -o "$build_dir/PlugInInterface.o" PlugInInterface.c

echo "Linking bundle executable..."
clang -bundle \
    -o "$driver_bundle/Contents/MacOS/$driver_name" \
    "$build_dir/JarvisVMicRing.o" "$build_dir/PlugInEntry.o" "$build_dir/PlugInInterface.o" \
    -framework CoreFoundation \
    -framework CoreAudio

cp Info.plist "$driver_bundle/Contents/Info.plist"

echo "Ad-hoc code signing..."
codesign --force --sign - "$driver_bundle"

echo "Building selftest (dlopen-based in-process verification, no coreaudiod/no sudo)..."
clang -Wall -Wextra -std=c11 -o "$build_dir/selftest" selftest.c \
    -framework CoreFoundation \
    -framework CoreAudio

echo ""
echo "Built: $PWD/$driver_bundle"
echo ""
echo "Running selftest against the built bundle (in-process, no coreaudiod, no install)..."
echo "----------------------------------------------------------------------"
"$build_dir/selftest" "$driver_bundle/Contents/MacOS/$driver_name"
echo "----------------------------------------------------------------------"
echo ""
echo "NOT INSTALLED — this build step never copies anything into"
echo "/Library/Audio/Plug-Ins/HAL and never restarts coreaudiod."
echo "Run ./install.sh yourself when you are ready to load it."
