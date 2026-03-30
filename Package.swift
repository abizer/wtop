// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "wtop",
    platforms: [.macOS(.v14)],
    targets: [
        // Main SwiftUI app
        .executableTarget(
            name: "wtop",
            path: "Sources/App",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        ),
        // Privileged helper daemon (runs as root via SMAppService)
        .executableTarget(
            name: "wtop-helper",
            path: "Sources/Helper"
        ),
    ]
)
