// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveWallpaperCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LiveWallpaperCore", targets: ["LiveWallpaperCore"])
    ],
    targets: [
        .target(
            name: "LiveWallpaperCore",
            path: "Sources/LiveWallpaperCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "LiveWallpaperCoreTests",
            dependencies: ["LiveWallpaperCore"],
            path: "Tests/LiveWallpaperCoreTests"
        )
    ]
)
