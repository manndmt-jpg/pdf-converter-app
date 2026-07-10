// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PDFConverter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "PDFConverter",
            targets: ["PDFConverter"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "PDFConverter",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
