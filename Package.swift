// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "wtop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "wtop",
            path: "Sources",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
    ]
)
