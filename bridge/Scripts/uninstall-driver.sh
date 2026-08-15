#!/bin/zsh
set -euo pipefail

# ============================================================================
# RUN THIS YOURSELF. An automated agent must not execute this script.
#
# This removes ONLY the "JarvisCallAudio" HAL driver at its exact, hardcoded path and restarts
# coreaudiod, which will briefly interrupt all system audio. Do not run during an active call.
# No wildcard is used and no other installed driver is touched.
# ============================================================================

driver_name="JarvisCallAudio"
install_dir="/Library/Audio/Plug-Ins/HAL"
target_path="$install_dir/$driver_name.driver"

echo "Target path (exact, no wildcard): $target_path"
echo ""
echo "This will:"
echo "  1. sudo rm -rf $target_path"
echo "  2. sudo killall coreaudiod   (restarts audio system-wide — will interrupt any active call)"
echo ""
read "confirm?Proceed? [y/N] "
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

sudo rm -rf "$target_path"
sudo killall coreaudiod

echo ""
echo "Uninstalled. coreaudiod restarted."
echo "Default Input/Output/System Output should be unaffected — these devices were never"
echo "eligible to be a default device (DeviceCanBeDefaultDevice/System = false always)."
