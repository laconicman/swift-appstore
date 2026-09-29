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
        // Façade: the type you use day-to-day (client factory + middlewares).
        .library(name: "AppStoreKit", targets: ["AppStoreKit"]),
        // The generated client/types, if you want them directly.
        .library(name: "AppStoreOpenAPI", targets: ["AppStoreOpenAPI"]),
        // Workflow layer: pull/diff/apply/validate/preflight over the fastlane metadata layout.
        .library(name: "AppStoreWorkflow", targets: ["AppStoreWorkflow"]),
        .executable(name: "asc", targets: ["asc"]),
    ],
    dependencies: [
        // Generator is a *plugin* — attached via `plugins:`, never `dependencies:` of a target.
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
        // ES256 for the App Store Connect JWT off Apple platforms (CryptoKit is used on-device).
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0"..<"6.0.0"),
        // Reused middleware from the same ecosystem as GitLabKit; compiles to an empty module
        // off Darwin, so AppStoreKit attaches it under `#if canImport(OSLog)`.
        .package(url: "https://github.com/laconicman/OSLogLoggingMiddleware", from: "1.0.0"),
        // DocC catalog rendering via `swift package generate-documentation`.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        // YAML parsing for the maintainer spec tool (tier configs; also used by the generator).
        .package(url: "https://github.com/jpsim/Yams", from: "6.0.0"),
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
        // Thin façade: client factory + JWT auth, retry/rate-limit, pagination, write guard.
        .target(
            name: "AppStoreKit",
            dependencies: [
                "AppStoreOpenAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "OSLogLoggingMiddleware", package: "OSLogLoggingMiddleware"),
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux, .android, .windows])
                ),
            ]
        ),
        // Workflow layer: fastlane-layout metadata sync (pull/diff/apply), validation,
        // archive preflight. Knows nothing about any specific app — LearnWords lives in asc.json.
        .target(
            name: "AppStoreWorkflow",
            dependencies: [
                "AppStoreKit",
                "AppStoreOpenAPI",
                // SHA-256 for the baseline digests; swift-crypto re-exports CryptoKit on Darwin.
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        // `asc` command line: `asc pull|diff|apply|validate|preflight`.
        .executableTarget(
            name: "asc",
            dependencies: [
                "AppStoreKit",
                "AppStoreWorkflow",
            ]
        ),
        // Maintainer tool: fetch Apple's spec zip, re-pin the manifest, report drift.
        // `swift run asc-spec-tool`.
        .executableTarget(
            name: "asc-spec-tool",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                // sha256 for the manifest pin; swift-crypto re-exports CryptoKit on Apple platforms.
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "AppStoreKitTests",
            dependencies: [
                "AppStoreKit",
                "AppStoreOpenAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                // Tests mint a throwaway P-256 key to exercise the JWT signer; never a real .p8.
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "AppStoreWorkflowTests",
            dependencies: [
                "AppStoreWorkflow",
                "AppStoreKit",
                "AppStoreOpenAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "SpecToolTests",
            dependencies: ["asc-spec-tool"]
        ),
        .testTarget(
            name: "ASCTests",
            dependencies: ["asc"]
        ),
    ]
)
