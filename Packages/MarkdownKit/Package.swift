// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MarkdownKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "MarkdownKit",
            targets: ["MarkdownKit"]
        ),
    ],
    dependencies: [
        // External dependencies must remain pinned by revision per repository policy.
        // Do not switch these dependencies to a branch.
        .package(url: "https://github.com/swiftlang/swift-markdown", revision: "27b7fc1a19068bcea3d2072db0ce86360d1400ed"),
        .package(url: "https://github.com/raspu/Highlightr", revision: "05e7fcc63b33925cd0c1faaa205cdd5681e7bbef"),
    ],
    targets: [
        .target(
            name: "MarkdownKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Highlightr", package: "Highlightr"),
            ],
            path: "Sources/MarkdownKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),

            ]
        ),
        .testTarget(
            name: "MarkdownKitTests",
            dependencies: [
                "MarkdownKit",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Tests/MarkdownKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
    ]
)
