#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."   # bridge/ root

# ============================================================================
# RUN THIS YOURSELF. An automated agent must not execute this script.
#
# This installs the "JarvisCallAudio" HAL driver system-wide and restarts the CoreAudio daemon,
# which will briefly interrupt all system audio (including any call in progress). Only run this
# when you deliberately want to load the driver for local loopback testing, not while on an
# active call.
#
# This script ONLY ever touches JarvisCallAudio.driver at an exact, hardcoded path. It never uses
# a wildcard and never removes any other driver you have installed (AITakeCallAudioDriver.driver,
# JumpAudio.driver, JumpAudioMic.driver, ParrotAudioPlugin.driver, TVRemoteAudio.driver, etc.).
# ============================================================================

driver_name="JarvisCallAudio"
built_bundle="AudioDriver/build/$driver_name.driver"
install_dir="/Library/Audio/Plug-Ins/HAL"
target_path="$install_dir/$driver_name.driver"

if [[ ! -d "$built_bundle" ]]; then
    echo "error: $built_bundle not found. Run ./Scripts/build-driver.sh first." >&2
    exit 1
fi

echo "Target path (exact, no wildcard): $target_path"
echo ""
echo "This will:"
echo "  1. sudo mkdir -p $install_dir"
echo "  2. sudo cp -R $built_bundle $install_dir/"
echo "  3. sudo chown -R root:wheel $target_path"
echo "  4. sudo killall coreaudiod   (restarts audio system-wide — will interrupt any active call)"
echo ""
echo "No other file under $install_dir will be touched."
echo ""
read "confirm?Proceed? [y/N] "
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

sudo mkdir -p "$install_dir"
sudo cp -R "$built_bundle" "$install_dir/"
sudo chown -R root:wheel "$target_path"
sudo killall coreaudiod

echo ""
echo "Installed. coreaudiod restarted."
echo "Verify with: swift run JarvisAudioDriverTool status"
echo "Or check Audio MIDI Setup.app / System Settings > Sound (devices start hidden by design —"
echo "see docs/Call_Bridge_v2_Phase_1_Report.md for how to activate them for testing)."
