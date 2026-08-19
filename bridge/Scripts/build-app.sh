#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

swift build -c debug

app_dir=".build/Jarvis Call Bridge.app"
contents_dir="$app_dir/Contents"
mkdir -p "$contents_dir/MacOS"
cp Info.plist "$contents_dir/Info.plist"
cp .build/debug/JarvisCallBridge "$contents_dir/MacOS/JarvisCallBridge"

# Ad-hoc (`-`) binds Accessibility to the binary CDHash — every rebuild looks like a
# new app. Prefer the stable local identity created by ensure-dev-signing-identity.sh.
sign_identity="${JARVIS_CODESIGN_IDENTITY:-Jarvis Call Bridge Dev}"
if security find-identity -p codesigning | grep -F -q "$sign_identity"; then
    codesign --force --sign "$sign_identity" --identifier com.jarvis.callbridge "$app_dir"
    print "Signed with: $sign_identity"
else
    echo "warning: no '$sign_identity' identity — falling back to ad-hoc." >&2
    echo "warning: Accessibility will reset on the next rebuild. Run:" >&2
    echo "  ./Scripts/ensure-dev-signing-identity.sh" >&2
    codesign --force --sign - "$app_dir"
fi

print "Built: $PWD/$app_dir"
