// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "brouter",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "brouter",
            path: "Sources/brouter",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("JavaScriptCore")
            ]
        )
    ]
)
