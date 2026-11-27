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
    dependencies: [
        // In-place updates, as in Trellis. Linked only by the app target; packaging embeds Sparkle.framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "PostWoman", dependencies: [.product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources/AppIcon")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .target(name: "PostWomanCLI"),
        .executableTarget(name: "PostWomanCLIMain", dependencies: ["PostWomanCLI"]),
        .testTarget(name: "PostWomanTests", dependencies: ["PostWoman", "PostWomanCLI"])
    ],
    swiftLanguageModes: [.v6]
)
