// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GrindIsland",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GrindIsland", targets: ["GrindIsland"])
    ],
    dependencies: [
        // In-app updates (MIT), fed from GitHub Releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "GrindIsland",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/GrindIsland",
            // Sparkle.framework: in GrindIsland.app/Contents/Frameworks (scripts/build-app.sh), or next to the bare
            // executable in .build (development runs).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        ),
        .testTarget(
            name: "GrindIslandTests",
            dependencies: ["GrindIsland"],
            path: "Tests/GrindIslandTests"
        )
    ]
)
