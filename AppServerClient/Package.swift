// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppServerClient",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "AppServerClient",
            targets: ["AppServerClient"]
        )
    ],
    dependencies: [
        .package(path: "../AgmenteTransport")
    ],
    targets: [
        .target(
            name: "AppServerClient",
            dependencies: [
                .product(name: "AgmenteTransport", package: "AgmenteTransport")
            ]
        ),
        .target(
            name: "AppServerClientMocks",
            dependencies: ["AppServerClient"],
            path: "Sources/AppServerClientMocks"
        ),
        .testTarget(
            name: "AppServerClientTests",
            dependencies: ["AppServerClient", "AppServerClientMocks"]
        )
    ]
)