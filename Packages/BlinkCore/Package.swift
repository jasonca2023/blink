// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlinkCore",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "BlinkCore",
            targets: ["BlinkCore"]
        )
    ],
    targets: [
        .target(
            name: "BlinkCore",
            dependencies: [],
            path: "Sources/BlinkCore"
        )
    ]
)
