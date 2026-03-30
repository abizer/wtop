set positional-arguments

default: build

# Build release binary
build:
    swift build -c release --disable-sandbox

# Build .app bundle
app: build
    rm -rf wtop.app
    mkdir -p wtop.app/Contents/{MacOS,Resources}
    cp .build/release/wtop wtop.app/Contents/MacOS/
    cp Info.plist wtop.app/Contents/
    codesign --force --sign - wtop.app

# Install .app to /Applications
install: app
    rm -rf /Applications/wtop.app
    cp -R wtop.app /Applications/wtop.app
    chmod -R a+rX /Applications/wtop.app

# Uninstall
uninstall:
    rm -rf /Applications/wtop.app

# Run debug build
run:
    swift build && .build/debug/wtop

# Run with sudo (full per-process energy data)
run-sudo:
    swift build && sudo .build/debug/wtop

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
    echo "  Update Casks/wtop.rb sha256"

# Clean build artifacts
clean:
    swift package clean
    rm -rf .build wtop.app wtop.app.zip
