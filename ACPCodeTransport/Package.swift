// swift-tools-version: 6.0
// One WebSocket transport for ACPClient and AppServerClient (D-017, PLAN 2.5).
import PackageDescription

let package = Package(
    name: "ACPCodeTransport",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "ACPCodeTransport", targets: ["ACPCodeTransport"])
    ],
    targets: [
        .target(name: "ACPCodeTransport"),
        .testTarget(name: "ACPCodeTransportTests", dependencies: ["ACPCodeTransport"], resources: [.copy("Fixtures")])
    ]
)
