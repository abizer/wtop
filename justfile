set positional-arguments

tap_repo := "../homebrew-tap"

default: build

# Build both app and helper
build:
    swift build -c release --disable-sandbox

# Build debug
build-debug:
    swift build

# Build .app bundle with embedded helper
app: build
    rm -rf wtop.app
    mkdir -p wtop.app/Contents/{MacOS,Helpers,Resources}
    cp .build/release/wtop wtop.app/Contents/MacOS/
    cp .build/release/wtop-helper wtop.app/Contents/Helpers/
    cp support/install-helper.sh wtop.app/Contents/Helpers/
    cp Info.plist wtop.app/Contents/
    cp support/me.abizer.wtop.helper.plist wtop.app/Contents/Resources/
    codesign --force --sign - wtop.app/Contents/Helpers/wtop-helper
    codesign --force --sign - wtop.app

# Install .app to ~/Applications (user-writable, Spotlight-indexed)
install: app
    mkdir -p ~/Applications
    rm -rf ~/Applications/wtop.app
    cp -R wtop.app ~/Applications/wtop.app

# Install privileged helper daemon (requires sudo, enables full system process energy)
install-helper: build
    sudo mkdir -p /Library/PrivilegedHelperTools
    sudo cp .build/release/wtop-helper /Library/PrivilegedHelperTools/me.abizer.wtop.helper
    sudo cp support/me.abizer.wtop.helper.plist /Library/LaunchDaemons/
    sudo launchctl bootout system/me.abizer.wtop.helper 2>/dev/null || true
    sudo launchctl bootstrap system /Library/LaunchDaemons/me.abizer.wtop.helper.plist
    @echo "Helper daemon registered (on-demand — starts when wtop.app opens)"

# Uninstall helper daemon
uninstall-helper:
    sudo launchctl bootout system/me.abizer.wtop.helper 2>/dev/null || true
    sudo rm -f /Library/PrivilegedHelperTools/me.abizer.wtop.helper
    sudo rm -f /Library/LaunchDaemons/me.abizer.wtop.helper.plist
    @echo "Helper daemon removed"

# Uninstall everything
uninstall: uninstall-helper
    rm -rf ~/Applications/wtop.app

# Run debug build
run:
    swift build && .build/debug/wtop

# Tag and push — CI handles the rest (tap PR + bottle build)
release version:
    #!/bin/bash
    set -euo pipefail
    if ! git diff --quiet HEAD; then
        echo "Error: uncommitted changes. Commit first."
        exit 1
    fi
    git tag "v{{version}}"
    git push origin master --tags
    echo "Tagged v{{version}} — CI will create a tap PR and build bottles"

# Clean build artifacts
clean:
    swift package clean
    rm -rf .build wtop.app wtop.app.zip
