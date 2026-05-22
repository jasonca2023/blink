// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlinkMemory",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "BlinkMemory",
            targets: ["BlinkMemory"]
        )
    ],
    dependencies: [
        .package(path: "../BlinkCore"),
        .package(path: "../BlinkUI")
    ],
    targets: [
        .target(
            name: "BlinkMemory",
            dependencies: [
                .product(name: "BlinkCore", package: "BlinkCore"),
                .product(name: "BlinkUI", package: "BlinkUI")
            ],
            path: "Sources/BlinkMemory"
        )
    ]
)
