set positional-arguments

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

# Uninstall
uninstall:
    rm -rf ~/Applications/wtop.app

# Run debug build
run:
    swift build && .build/debug/wtop

# Create release zip for GitHub
release version:
    #!/bin/bash
    set -euo pipefail
    just app
    ditto -c -k --keepParent wtop.app "wtop.app.zip"
    SHA=$(shasum -a 256 wtop.app.zip | cut -d' ' -f1)
    echo "wtop.app.zip ready — sha256: $SHA"
    echo ""
    echo "  git tag v{{version}} && git push --tags"
    echo "  gh release create v{{version}} wtop.app.zip --title 'v{{version}}'"

# Clean build artifacts
clean:
    swift package clean
    rm -rf .build wtop.app wtop.app.zip
