// swift-tools-version: 6.0
// One WebSocket transport for ACPClient and AppServerClient (D-017, PLAN 2.5).
import PackageDescription

let package = Package(
    name: "AgmenteTransport",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "AgmenteTransport", targets: ["AgmenteTransport"])
    ],
    targets: [
        .target(name: "AgmenteTransport"),
        .testTarget(name: "AgmenteTransportTests", dependencies: ["AgmenteTransport"], resources: [.copy("Fixtures")])
    ]
)
