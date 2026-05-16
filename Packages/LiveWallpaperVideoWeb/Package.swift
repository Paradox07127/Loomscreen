// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveWallpaperVideoWeb",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LiveWallpaperVideoWeb", targets: ["LiveWallpaperVideoWeb"])
    ],
    dependencies: [
        .package(name: "LiveWallpaperCore", path: "../LiveWallpaperCore")
    ],
    targets: [
        .target(
            name: "LiveWallpaperVideoWeb",
            dependencies: [
                .product(name: "LiveWallpaperCore", package: "LiveWallpaperCore")
            ],
            path: "Sources/LiveWallpaperVideoWeb",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "LiveWallpaperVideoWebTests",
            dependencies: ["LiveWallpaperVideoWeb"],
            path: "Tests/LiveWallpaperVideoWebTests"
        )
    ]
)
