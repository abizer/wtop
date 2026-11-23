set positional-arguments

# A machine with only the Command Line Tools (no Xcode) can't build against the macOS 27
# SDK: SwiftUI's @State became a macro there and its compiler plugin ships with Xcode
# alone. The same toolchain also intermittently drops the Swift Testing plugin from the
# compile command. So on CLT, build against the 26 SDK and name the plugin directory.
clt := "/Library/Developer/CommandLineTools"
on_clt := `[ "$(xcode-select -p 2>/dev/null)" = /Library/Developer/CommandLineTools ] && echo true || echo false`
export SDKROOT := if on_clt == "true" { if path_exists(clt / "SDKs/MacOSX26.sdk") == "true" { clt / "SDKs/MacOSX26.sdk" } else { clt / "SDKs/MacOSX.sdk" } } else { `xcrun --show-sdk-path` }
# The CLT linker also stamps the binary with the deployment target (14.0) as its SDK
# version instead of the SDK it was built with. macOS picks an app's look from that stamp,
# so without the real one a local build renders in the pre-Liquid Glass style.
sdk_version := `plutil -extract Version raw /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk/SDKSettings.json 2>/dev/null || echo 26.0`
export WTOP_BUILD_FLAGS := if on_clt == "true" { "-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker " + sdk_version } else { "" }
test_flags := if on_clt == "true" { "-Xswiftc -plugin-path -Xswiftc " + clt / "usr/lib/swift/host/plugins/testing" } else { "" }

# Version of the last release tag, e.g. 0.4.4
version := `git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0`

default: build

# Build both app and helper
build:
    swift build -c release --disable-sandbox {{WTOP_BUILD_FLAGS}}

# Build debug
build-debug:
    swift build {{WTOP_BUILD_FLAGS}}

# Run the test suite (the sampler tests pin a core for a few seconds)
test:
    swift test {{test_flags}}

# Build .app bundle with embedded helper
app:
    support/make-app.sh {{version}}

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
    swift build {{WTOP_BUILD_FLAGS}} && .build/debug/wtop

# Tag and push — CI builds the .app, publishes the release and bumps the cask
release new_version: test
    #!/bin/bash
    set -euo pipefail
    if ! git diff --quiet HEAD; then
        echo "Error: uncommitted changes. Commit first."
        exit 1
    fi
    git tag "v{{new_version}}"
    git push origin master --tags
    echo "Tagged v{{new_version}} — CI will publish the release and bump the cask"

# Clean build artifacts
clean:
    swift package clean
    rm -rf .build wtop.app wtop.app.zip
