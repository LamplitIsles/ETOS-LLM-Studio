// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ETOSAssetCompiler",
    dependencies: [
        .package(url: "https://github.com/TartanLeGrand/AssetKit.git", revision: "90281d6dc0c4edef6176f9283283271198e4bafd"),
    ],
    targets: [
        .executableTarget(name: "ETOSAssetCompiler", dependencies: [
            .product(name: "AssetKit", package: "AssetKit"),
        ]),
    ]
)
