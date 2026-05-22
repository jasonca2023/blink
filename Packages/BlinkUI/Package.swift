// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlinkUI",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "BlinkUI",
            targets: ["BlinkUI"]
        )
    ],
    dependencies: [
        .package(path: "../BlinkCore")
    ],
    targets: [
        .target(
            name: "BlinkUI",
            dependencies: [
                .product(name: "BlinkCore", package: "BlinkCore")
            ],
            path: "Sources/BlinkUI"
        )
    ]
)
