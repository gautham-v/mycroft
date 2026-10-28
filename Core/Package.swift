// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenDispatchCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "OpenDispatchCore", targets: ["OpenDispatchCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "OpenDispatchCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
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
            name: "OpenDispatchCoreTests",
            dependencies: ["OpenDispatchCore"],
            resources: [.copy("Fixtures/ApplePodcasts"), .copy("Fixtures/Explore")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
    ]
)
