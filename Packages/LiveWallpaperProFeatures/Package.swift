// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveWallpaperProFeatures",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LiveWallpaperProFeatures", targets: ["LiveWallpaperProFeatures"])
    ],
    dependencies: [
        .package(name: "LiveWallpaperCore", path: "../LiveWallpaperCore"),
        .package(name: "LiveWallpaperSharedUI", path: "../LiveWallpaperSharedUI")
    ],
    targets: [
        .target(
            name: "LiveWallpaperProFeatures",
            dependencies: [
                .product(name: "LiveWallpaperCore", package: "LiveWallpaperCore"),
                .product(name: "LiveWallpaperSharedUI", package: "LiveWallpaperSharedUI")
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
