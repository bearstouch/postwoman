// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PostWoman",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PostWoman", targets: ["PostWoman"])
    ],
    targets: [
        .executableTarget(name: "PostWoman", resources: [.copy("Resources/AppIcon")]),
        .testTarget(name: "PostWomanTests", dependencies: ["PostWoman"])
    ],
    swiftLanguageModes: [.v6]
)
