// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveWallpaperProFeatures",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LiveWallpaperProFeatures", targets: ["LiveWallpaperProFeatures"])
    ],
    dependencies: [
        .package(name: "LiveWallpaperCore", path: "../LiveWallpaperCore")
    ],
    targets: [
        .target(
            name: "LiveWallpaperProFeatures",
            dependencies: [
                .product(name: "LiveWallpaperCore", package: "LiveWallpaperCore")
            ],
            path: "Sources/LiveWallpaperProFeatures",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "LiveWallpaperProFeaturesTests",
            dependencies: ["LiveWallpaperProFeatures"],
            path: "Tests/LiveWallpaperProFeaturesTests"
        )
    ]
)
