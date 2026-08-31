// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nikita",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Nikita",
            targets: ["Nikita"])
    ],
    targets: [
        .target(
            name: "Nikita",
            path: "Sources"),
        .testTarget(
            name: "NikitaTests",
            dependencies: ["Nikita"],
            path: "Tests")
    ]
)
