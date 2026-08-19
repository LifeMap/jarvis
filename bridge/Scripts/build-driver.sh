#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."   # bridge/ root

# CB v2 Phase 1. Compiles the "JarvisCallAudio" HAL Audio Server Plug-in (Jarvis Call Capture +
# Jarvis Call Inject) with plain clang — no Xcode project, no DriverKit system extension — and
# assembles it into a .driver bundle.
#
# This script ONLY compiles and assembles the bundle locally under AudioDriver/build/. It never
# copies anything into /Library/Audio/Plug-Ins/HAL and never touches coreaudiod. Run
# Scripts/install-driver.sh yourself afterward, on purpose, as a separate step.

driver_name="JarvisCallAudio"
plugin_dir="AudioDriver/Plugin"
shared_dir="AudioDriver/Shared"
build_dir="AudioDriver/build"
driver_bundle="$build_dir/$driver_name.driver"

rm -rf "$build_dir"
mkdir -p "$build_dir" "$driver_bundle/Contents/MacOS"

echo "Compiling..."
clang -Wall -Wextra -std=c11 -c -I "$shared_dir/include" -I "$plugin_dir" \
    -o "$build_dir/JarvisLoopbackBuffer.o" "$shared_dir/JarvisLoopbackBuffer.c"
clang -Wall -Wextra -std=c11 -c -I "$shared_dir/include" -I "$plugin_dir" \
    -o "$build_dir/JarvisCaptureRXRing.o" "$shared_dir/JarvisCaptureRXRing.c"
clang -Wall -Wextra -std=c11 -c -I "$shared_dir/include" -I "$plugin_dir" \
    -o "$build_dir/PlugInEntry.o" "$plugin_dir/PlugInEntry.c"
clang -Wall -Wextra -std=c11 -c -I "$shared_dir/include" -I "$plugin_dir" \
    -o "$build_dir/PlugInInterface.o" "$plugin_dir/PlugInInterface.c"

echo "Linking bundle executable..."
clang -bundle \
    -o "$driver_bundle/Contents/MacOS/$driver_name" \
    "$build_dir/JarvisLoopbackBuffer.o" "$build_dir/JarvisCaptureRXRing.o" "$build_dir/PlugInEntry.o" "$build_dir/PlugInInterface.o" \
    -framework CoreFoundation \
    -framework CoreAudio

cp "$plugin_dir/Info.plist" "$driver_bundle/Contents/Info.plist"

echo "Ad-hoc code signing..."
codesign --force --sign - "$driver_bundle"

echo "Building selftest (dlopen-based in-process verification, no coreaudiod/no sudo)..."
clang -Wall -Wextra -std=c11 -I "$shared_dir/include" -I "$plugin_dir" \
    -o "$build_dir/selftest" "$plugin_dir/selftest.c" "$shared_dir/JarvisCaptureRXRing.c" \
    -framework CoreFoundation \
    -framework CoreAudio

echo ""
echo "Built: $PWD/$driver_bundle"
echo ""
echo "Running selftest against the built bundle (in-process, no coreaudiod, no install)..."
echo "----------------------------------------------------------------------"
selftest_status=0
"$build_dir/selftest" "$driver_bundle/Contents/MacOS/$driver_name" || selftest_status=$?
echo "----------------------------------------------------------------------"
echo ""
echo "NOT INSTALLED — this build step never copies anything into"
echo "/Library/Audio/Plug-Ins/HAL and never restarts coreaudiod."
echo "Run Scripts/install-driver.sh yourself when you are ready to load it."

exit $selftest_status
