// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "wtop",
    platforms: [.macOS(.v14)],
    targets: [
        // XPC protocol + process-table reader, compiled into both executables
        .target(
            name: "WtopShared",
            path: "Sources/Shared"
        ),
        // Main SwiftUI app (runs as the current user)
        .executableTarget(
            name: "wtop",
            dependencies: ["WtopShared"],
            path: "Sources/App",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Privileged helper daemon (root, launched on demand by launchd)
        .executableTarget(
            name: "wtop-helper",
            dependencies: ["WtopShared"],
            path: "Sources/Helper"
        ),
        .testTarget(
            name: "WtopSharedTests",
            dependencies: ["WtopShared"],
            path: "Tests/SharedTests"
        ),
        .testTarget(
            name: "WtopTests",
            dependencies: ["wtop"],
            path: "Tests/AppTests"
        ),
    ]
)
