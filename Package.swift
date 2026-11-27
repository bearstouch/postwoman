// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PostWoman",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PostWoman", targets: ["PostWoman"]),
        // `postwoman` inside the app bundle; `postwoman-cli` here, since `postwoman` and `PostWoman` would clash in .build.
        .executable(name: "postwoman-cli", targets: ["PostWomanCLIMain"])
    ],
    targets: [
        .executableTarget(name: "PostWoman", resources: [.copy("Resources/AppIcon")]),
        .target(name: "PostWomanCLI"),
        .executableTarget(name: "PostWomanCLIMain", dependencies: ["PostWomanCLI"]),
        .testTarget(name: "PostWomanTests", dependencies: ["PostWoman", "PostWomanCLI"])
    ],
    swiftLanguageModes: [.v6]
)
