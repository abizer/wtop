#!/bin/bash
# Install the wtop privileged helper daemon.
# Run with: sudo wtop-helper-install
set -euo pipefail

HELPER_SRC="$(dirname "$0")/wtop-helper"
HELPER_DEST="/Library/PrivilegedHelperTools/me.abizer.wtop.helper"
PLIST_SRC="$(dirname "$0")/../etc/wtop/me.abizer.wtop.helper.plist"
PLIST_DEST="/Library/LaunchDaemons/me.abizer.wtop.helper.plist"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run with sudo."
    exit 1
fi

mkdir -p /Library/PrivilegedHelperTools
cp "$HELPER_SRC" "$HELPER_DEST"
chmod 755 "$HELPER_DEST"
cp "$PLIST_SRC" "$PLIST_DEST"

launchctl bootout system/me.abizer.wtop.helper 2>/dev/null || true
launchctl bootstrap system "$PLIST_DEST"

echo "wtop helper installed (on-demand — starts when wtop.app opens)"
