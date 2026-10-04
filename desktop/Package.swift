// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MISTTDesktop",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "MISTTDesktop", targets: ["MISTTDesktop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "NativeAudioQueue", publicHeadersPath: "include"),
        .target(name: "NativePairAtomics", publicHeadersPath: "include"),
        .executableTarget(
            name: "MISTTDesktop",
            dependencies: ["NativeAudioQueue", "NativePairAtomics", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/MISTTDesktop"
        ),
        .testTarget(
            name: "MISTTDesktopTests",
            dependencies: ["MISTTDesktop", "NativeAudioQueue"],
            path: "Tests/MISTTDesktopTests"
        ),
    ]
)
