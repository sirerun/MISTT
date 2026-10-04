// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MISTTDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MISTTDesktop", targets: ["MISTTDesktop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "NativeAudioQueue", publicHeadersPath: "include"),
        .executableTarget(
            name: "MISTTDesktop",
            dependencies: ["NativeAudioQueue", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/MISTTDesktop"
        ),
        .testTarget(
            name: "MISTTDesktopTests",
            dependencies: ["MISTTDesktop"],
            path: "Tests/MISTTDesktopTests",
            resources: [.copy("Fixtures/fake-mistt")]
        ),
    ]
)
