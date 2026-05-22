// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlinkMarkdown",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "BlinkMarkdown",
            targets: ["BlinkMarkdown"]
        )
    ],
    dependencies: [
        .package(path: "../BlinkUI")
    ],
    targets: [
        .target(
            name: "BlinkMarkdown",
            dependencies: [
                .product(name: "BlinkUI", package: "BlinkUI")
            ],
            path: "Sources/BlinkMarkdown"
        )
    ]
)
