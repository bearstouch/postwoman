// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reqs",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Reqs", targets: ["Reqs"]),
        // `reqs` inside the app bundle; `reqs-cli` here, since `reqs` and `Reqs` would clash in .build.
        .executable(name: "reqs-cli", targets: ["ReqsCLIMain"])
    ],
    dependencies: [
        // In-place updates, as in Trellis. Linked only by the app target; packaging embeds Sparkle.framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Reqs", dependencies: [.product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources/AppIcon")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .target(name: "ReqsCLI"),
        .executableTarget(name: "ReqsCLIMain", dependencies: ["ReqsCLI"]),
        .testTarget(name: "ReqsTests", dependencies: ["Reqs", "ReqsCLI"])
    ],
    swiftLanguageModes: [.v6]
)
