#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

# ============================================================================
# RUN THIS YOURSELF. An automated agent must not execute this script.
#
# This installs the "Jarvis Virtual Mic" HAL driver system-wide and restarts
# the CoreAudio daemon, which will briefly interrupt all system audio
# (including any call in progress). Only run this when you deliberately want
# to load the driver for a real-device test, not while on an active call.
# ============================================================================

driver_name="JarvisVirtualMic"
built_bundle="build/$driver_name.driver"
install_dir="/Library/Audio/Plug-Ins/HAL"

if [[ ! -d "$built_bundle" ]]; then
    echo "error: $built_bundle not found. Run ./build-driver.sh first." >&2
    exit 1
fi

echo "This will:"
echo "  1. sudo mkdir -p $install_dir"
echo "  2. sudo cp -R $built_bundle $install_dir/"
echo "  3. sudo chown -R root:wheel $install_dir/$driver_name.driver"
echo "  4. sudo killall coreaudiod   (restarts audio system-wide — will interrupt any active call)"
echo ""
read "confirm?Proceed? [y/N] "
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

sudo mkdir -p "$install_dir"
sudo cp -R "$built_bundle" "$install_dir/"
sudo chown -R root:wheel "$install_dir/$driver_name.driver"
sudo killall coreaudiod

echo ""
echo "Installed. coreaudiod restarted."
echo "Verify in System Settings > Sound > Input, or Audio MIDI Setup.app, for a device named"
echo "\"Jarvis Virtual Mic\". If it does not appear, check Console.app for coreaudiod errors"
echo "mentioning JarvisVirtualMic, and record them in the Phase 0 report."
