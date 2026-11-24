// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QamusMac",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "QamusMac", targets: ["QamusMac"])
    ],
    targets: [
        .executableTarget(
            name: "QamusMac",
            path: "Sources/QamusMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("WebKit"),
                .linkedFramework("Network"),
                .linkedFramework("Vision"),
                .linkedFramework("FoundationModels")
            ]
        )
    ]
)
