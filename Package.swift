// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "glance",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "glance",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            // Highlight.js assets are copied straight into Contents/Resources/
            // by build.sh and loaded via Bundle.main at runtime — see WebView.swift.
            exclude: [
                "Resources",
            ]
        ),
    ]
)
