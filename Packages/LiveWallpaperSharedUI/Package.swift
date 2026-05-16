// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveWallpaperSharedUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LiveWallpaperSharedUI", targets: ["LiveWallpaperSharedUI"])
    ],
    dependencies: [
        .package(name: "LiveWallpaperCore", path: "../LiveWallpaperCore")
    ],
    targets: [
        .target(
            name: "LiveWallpaperSharedUI",
            dependencies: [
                .product(name: "LiveWallpaperCore", package: "LiveWallpaperCore")
            ],
            path: "Sources/LiveWallpaperSharedUI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "LiveWallpaperSharedUITests",
            dependencies: ["LiveWallpaperSharedUI"],
            path: "Tests/LiveWallpaperSharedUITests"
        )
    ]
)
