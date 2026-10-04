// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NativeCapturePreflight",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "NativeCapturePreflight", targets: ["NativeCapturePreflight"])],
    targets: [
        .target(name: "PreflightAtomics", publicHeadersPath: "include"),
        .executableTarget(name: "NativeCapturePreflight", dependencies: ["PreflightAtomics"], path: "Sources/NativeCapturePreflight"),
        .testTarget(
            name: "NativeCapturePreflightTests",
            dependencies: ["NativeCapturePreflight", "PreflightAtomics"],
            path: "Tests/NativeCapturePreflightTests"
        ),
    ]
)
