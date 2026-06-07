// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveWallpaperProWPE",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LiveWallpaperProWPE", targets: ["LiveWallpaperProWPE"])
    ],
    dependencies: [
        .package(name: "LiveWallpaperCore", path: "../LiveWallpaperCore")
    ],
    targets: [
        .target(
            name: "LiveWallpaperProWPE",
            dependencies: [
                .product(name: "LiveWallpaperCore", package: "LiveWallpaperCore")
            ],
            path: "Sources/LiveWallpaperProWPE",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "LiveWallpaperProWPETests",
            dependencies: ["LiveWallpaperProWPE"],
            path: "Tests/LiveWallpaperProWPETests"
        )
    ]
)
