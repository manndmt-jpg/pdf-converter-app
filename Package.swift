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
    targets: [
        .executableTarget(
            name: "PDFConverter",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
