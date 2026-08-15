#!/bin/zsh
set -euo pipefail

# ============================================================================
# RUN THIS YOURSELF. An automated agent must not execute this script.
#
# This removes the "Jarvis Virtual Mic" HAL driver and restarts coreaudiod,
# which will briefly interrupt all system audio. Do not run during an active
# call.
# ============================================================================

driver_name="JarvisVirtualMic"
install_dir="/Library/Audio/Plug-Ins/HAL"
installed_bundle="$install_dir/$driver_name.driver"

echo "This will:"
echo "  1. sudo rm -rf $installed_bundle"
echo "  2. sudo killall coreaudiod   (restarts audio system-wide — will interrupt any active call)"
echo ""
read "confirm?Proceed? [y/N] "
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

sudo rm -rf "$installed_bundle"
sudo killall coreaudiod

echo ""
echo "Uninstalled. coreaudiod restarted."
echo ""
echo "If \"Jarvis Virtual Mic\" was selected as your system default input device, macOS should"
echo "fall back to another available input automatically. If Sound Input still looks wrong"
echo "afterward, open System Settings > Sound > Input and pick your normal microphone (e.g."
echo "the built-in mic) by hand — this script does not touch that setting."
