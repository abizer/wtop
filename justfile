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
    cp Info.plist wtop.app/Contents/
    cp Resources/me.abizer.wtop.helper.plist wtop.app/Contents/Resources/
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
    sudo cp Resources/me.abizer.wtop.helper.plist /Library/LaunchDaemons/
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

# Tag, push, and update the Homebrew tap formula
release version:
    #!/bin/bash
    set -euo pipefail

    # Ensure clean working tree
    if ! git diff --quiet HEAD; then
        echo "Error: uncommitted changes. Commit first."
        exit 1
    fi

    # Update Info.plist version
    sed -i '' 's|<string>[0-9]*\.[0-9]*\.[0-9]*</string><!-- CFBundleVersion -->|<string>{{version}}</string><!-- CFBundleVersion -->|' Info.plist 2>/dev/null || true

    # Tag and push
    git tag "v{{version}}"
    git push origin master --tags
    echo "Tagged and pushed v{{version}}"

    # Update tap formula
    TAP="{{tap_repo}}"
    if [ ! -d "$TAP/Formula" ]; then
        echo "Error: tap repo not found at $TAP"
        exit 1
    fi
    sed -i '' 's|tag: "v[0-9]*\.[0-9]*\.[0-9]*"|tag: "v{{version}}"|' "$TAP/Formula/wtop.rb"
    cd "$TAP"
    git add Formula/wtop.rb
    git commit -m "wtop v{{version}}"
    git push
    echo "Tap updated to v{{version}}"

# Clean build artifacts
clean:
    swift package clean
    rm -rf .build wtop.app wtop.app.zip
