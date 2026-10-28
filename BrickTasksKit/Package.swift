// swift-tools-version: 6.0
import PackageDescription

// Layering (see ENGINEERING.md):
//   Domain  <-  Networking  <-  ThirdParty/OpenAPITaskClient
//   Domain  <-  Persistence (SwiftData)
// Only targets under Sources/ThirdParty may depend on third-party packages.
let package = Package(
    name: "BrickTasksKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Networking", targets: ["Networking"]),
        .library(name: "OpenAPITaskClient", targets: ["OpenAPITaskClient"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Repository", targets: ["Repository"]),
        .library(name: "TaskSimulator", targets: ["TaskSimulator"]),
        .library(name: "Features", targets: ["Features"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.4.0"),
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Networking", dependencies: ["Domain"]),
        .target(name: "Persistence", dependencies: ["Domain"]),
        .target(name: "Repository", dependencies: ["Domain"]),
        // In-memory server for tests and UI-test launches. Never wired into a release build.
        .target(name: "TaskSimulator", dependencies: ["Domain"]),
        // ViewModels. Imports Observation, not SwiftUI, so it builds and tests on macOS too.
        .target(name: "Features", dependencies: ["Domain", "Repository"]),
        .target(
            name: "OpenAPITaskClient",
            dependencies: [
                "Domain",
                "Networking",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            path: "Sources/ThirdParty/OpenAPITaskClient",
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "NetworkingTests", dependencies: ["Networking", "Domain"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "Domain"]),
        .testTarget(name: "TaskSimulatorTests", dependencies: ["TaskSimulator", "Domain"]),
        .testTarget(name: "FeaturesTests", dependencies: ["Features", "Repository", "Persistence", "TaskSimulator", "Domain"]),
        .testTarget(name: "RepositoryTests", dependencies: ["Repository", "Persistence", "TaskSimulator", "Domain"]),
        .testTarget(
            name: "OpenAPITaskClientTests",
            dependencies: ["OpenAPITaskClient", "Networking", "Domain"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
