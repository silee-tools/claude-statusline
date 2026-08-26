// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentCore",
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
    ],
    targets: [
        .target(name: "AgentCore"),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
    ]
)
