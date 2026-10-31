// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ETOS",
    platforms: [.iOS(.v17), .macOS("26.0")],
    products: [
        .library(name: "ETOSApp", targets: ["ETOSApp"]),
        .library(name: "ETOSShare", targets: ["ETOSShare"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
        .package(url: "https://github.com/Eric-Terminal/GRDB.swift", revision: "df4f8771227282425ed59a38a9487a9ff306df27"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", from: "4.16.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.3"),
    ],
    targets: [
        .target(
            name: "ETOSCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "ETOSCore/ETOSCore",
            exclude: ["ETOSCore.docc"],
            swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")],
            // The host ZIPFoundation manifest may add Linux zlib paths during cross-builds.
            // Search the target SDK's /usr/lib before those host paths.
            linkerSettings: [.unsafeFlags(["-L/usr/lib/"], .when(platforms: [.iOS]))]
        ),
        .target(
            name: "ETOSApp",
            dependencies: [
                "ETOSCore",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "SwiftMath", package: "SwiftMath"),
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
            ],
            path: "ETOS LLM Studio/ETOS LLM Studio iOS App",
            exclude: ["ETOS LLM Studio iOS App.entitlements", "Assets.xcassets", "PrivacyInfo.xcprivacy", "ar.lproj", "en.lproj", "es.lproj", "fr.lproj", "ja.lproj", "ru.lproj", "zh-Hans.lproj", "zh-Hant-HK.lproj"],
            swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("MemberImportVisibility")]
        ),
        .target(
            name: "ETOSShare",
            dependencies: ["ETOSCore"],
            path: "ETOS LLM Studio/ETOS Agent Share",
            exclude: ["Info.plist", "ETOS Agent ShareDebug.entitlements", "ETOS Agent ShareRelease.entitlements", "PrivacyInfo.xcprivacy", "Base.lproj", "ar.lproj", "en.lproj", "es.lproj", "fr.lproj", "ja.lproj", "ru.lproj", "zh-Hans.lproj", "zh-Hant-HK.lproj"],
            swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")],
            // xtool's extension wrapper has no source references to plist principal classes.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-u", "-Xlinker", "_OBJC_CLASS_$__TtC9ETOSShare19ShareViewController",
            ], .when(platforms: [.iOS]))]
        ),
    ],
    swiftLanguageModes: [.v5]
)
