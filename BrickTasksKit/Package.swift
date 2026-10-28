// swift-tools-version: 6.0
import PackageDescription

// Layering (see ENGINEERING.md):
//   Domain  <-  Networking  <-  ThirdParty/OpenAPITaskClient
// Only targets under Sources/ThirdParty may depend on third-party packages.
let package = Package(
    name: "BrickTasksKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Networking", targets: ["Networking"]),
        .library(name: "OpenAPITaskClient", targets: ["OpenAPITaskClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.4.0"),
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Networking", dependencies: ["Domain"]),
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
        .testTarget(
            name: "OpenAPITaskClientTests",
            dependencies: ["OpenAPITaskClient", "Networking", "Domain"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
