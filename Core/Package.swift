// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenfeedCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "OpenfeedCore", targets: ["OpenfeedCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "10.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "OpenfeedCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FeedKit", package: "FeedKit"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            resources: [
                .copy("Resources/Readability.js"),
                .copy("Resources/Readability-LICENSE.md"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "OpenfeedCoreTests",
            dependencies: ["OpenfeedCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
    ]
)
