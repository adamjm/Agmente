// swift-tools-version: 5.10
// The Live Activity types for a pending approval, shared by the app and the ACPCodeLiveActivity widget (la-decision).
// Holds no tool title and no command: the content state is the only data ActivityKit shows on the Lock Screen.
import PackageDescription

let package = Package(
    name: "ACPCodeLiveApproval",
    platforms: [
        .iOS("18.0")
    ],
    products: [
        .library(name: "ACPCodeLiveApproval", targets: ["ACPCodeLiveApproval"])
    ],
    targets: [
        .target(name: "ACPCodeLiveApproval"),
        .testTarget(name: "ACPCodeLiveApprovalTests", dependencies: ["ACPCodeLiveApproval"])
    ]
)
