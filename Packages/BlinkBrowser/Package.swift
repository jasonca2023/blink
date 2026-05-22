// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlinkBrowser",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "BlinkBrowser",
            targets: ["BlinkBrowser"]
        )
    ],
    dependencies: [
        .package(path: "../BlinkCore"),
        .package(path: "../BlinkUI")
    ],
    targets: [
        .target(
            name: "BlinkBrowser",
            dependencies: [
                .product(name: "BlinkCore", package: "BlinkCore"),
                .product(name: "BlinkUI", package: "BlinkUI")
            ],
            path: "Sources/BlinkBrowser"
        )
    ]
)
