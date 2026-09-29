// swift-tools-version: 6.2

// Concurrency dialect: every target here is nonisolated by default — deliberately, not
// by omission. Two reasons, either of which would suffice: a client library must not
// impose an executor on its callers (all shared types are Sendable; the only mutable
// state sits behind an actor or a lock), and the generated OpenAPI target cannot compile
// under `-default-isolation MainActor` (apple/swift-openapi-generator#796/#823 — inferred
// MainActor conformances fail the nonisolated Codable/APIProtocol requirements). An app
// that adopts MainActor default + approachable concurrency consumes this package as-is:
// its public async functions take and return Sendable values only. `.defaultIsolation(nil)`
// spells the policy on each target; REVIEW.md flags adding a MainActor default anywhere.
// Sibling packages (SimKDSKit, YandexDeliveryExpressAPI, YooMoneyAPIClient) carry the same
// default; see Design → Concurrency.
import PackageDescription

/// The one setting every target shares — see the header comment.
let nonisolated: [SwiftSetting] = [.defaultIsolation(nil)]

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
            swiftSettings: nonisolated,
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
            ],
            swiftSettings: nonisolated
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
            ],
            swiftSettings: nonisolated
        ),
        // `asc` command line: `asc pull|diff|apply|validate|preflight`.
        .executableTarget(
            name: "asc",
            dependencies: [
                "AppStoreKit",
                "AppStoreWorkflow",
            ],
            swiftSettings: nonisolated
        ),
        // Maintainer tool: fetch Apple's spec zip, re-pin the manifest, report drift.
        // `swift run asc-spec-tool`.
        .executableTarget(
            name: "asc-spec-tool",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                // sha256 for the manifest pin; swift-crypto re-exports CryptoKit on Apple platforms.
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: nonisolated
        ),
        .testTarget(
            name: "AppStoreKitTests",
            dependencies: [
                "AppStoreKit",
                "AppStoreOpenAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                // Tests mint a throwaway P-256 key to exercise the JWT signer; never a real .p8.
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: nonisolated
        ),
        .testTarget(
            name: "AppStoreWorkflowTests",
            dependencies: [
                "AppStoreWorkflow",
                "AppStoreKit",
                "AppStoreOpenAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: nonisolated
        ),
        .testTarget(
            name: "SpecToolTests",
            dependencies: ["asc-spec-tool"],
            swiftSettings: nonisolated
        ),
        .testTarget(
            name: "ASCTests",
            dependencies: ["asc"],
            swiftSettings: nonisolated
        ),
    ]
)
