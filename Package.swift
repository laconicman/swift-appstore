// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppStoreKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        // The generated client/types, if you want them directly.
        .library(name: "AppStoreOpenAPI", targets: ["AppStoreOpenAPI"]),
    ],
    dependencies: [
        // Generator is a *plugin* — attached via `plugins:`, never `dependencies:` of a target.
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        // DocC catalog rendering via `swift package generate-documentation`.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        // Generated target: holds only openapi.json + the generator config.
        // The build plugin emits Client.swift + Types.swift at build time (not committed).
        .target(
            name: "AppStoreOpenAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            // Preserved tier templates and the spec manifest live beside the active config
            // for reference, but must not be seen by SwiftPM or the generator plugin (which
            // loads the file named exactly `openapi-generator-config.yaml`).
            exclude: [
                "openapi-generator-config.full.yaml",
                "spec-manifest.json",
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
    ]
)
