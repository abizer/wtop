#!/bin/bash
# Build wtop.app in the current directory: release binaries, bundle layout,
# version stamp, ad-hoc signature. Used by both `just app` and the release workflow.
#
#   support/make-app.sh <version>
set -euo pipefail

VERSION="${1:?usage: make-app.sh <version>}"
cd "$(dirname "$0")/.."

swift build -c release --disable-sandbox
BIN="$(swift build -c release --disable-sandbox --show-bin-path)"

rm -rf wtop.app
mkdir -p wtop.app/Contents/{MacOS,Helpers,Resources}
cp "$BIN/wtop" wtop.app/Contents/MacOS/
cp "$BIN/wtop-helper" wtop.app/Contents/Helpers/
cp Info.plist wtop.app/Contents/
# Shell scripts must live in Resources — anywhere else breaks codesign.
cp support/me.abizer.wtop.helper.plist support/install-helper.sh wtop.app/Contents/Resources/
chmod +x wtop.app/Contents/Resources/install-helper.sh

/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $VERSION" \
    wtop.app/Contents/Info.plist

codesign --force --sign - wtop.app/Contents/Helpers/wtop-helper
codesign --force --sign - wtop.app

echo "Built wtop.app $VERSION"
