// swift-tools-version: 5.9
import PackageDescription
import Foundation
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("desktop/Conversation/Resources/Info.plist").path
let package = Package(
    name: "MISTTConversation", platforms: [.macOS("14.2")],
    products: [.library(name: "MISTTConversation", targets: ["MISTTConversation"]), .executable(name: "mistt-media", targets: ["MISTTMedia"])],
    targets: [
        .target(name: "MISTTConversation", path: "desktop/Conversation/Sources/MISTTConversation"),
        .executableTarget(name: "MISTTMedia", dependencies: ["MISTTConversation"], path: "desktop/Conversation/Sources/MISTTMedia", linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]),
        .testTarget(name: "MISTTConversationTests", dependencies: ["MISTTConversation"], path: "desktop/Conversation/Tests/MISTTConversationTests")
    ]
)
