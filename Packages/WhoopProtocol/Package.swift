// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhoopProtocol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "WhoopProtocol", targets: ["WhoopProtocol"])],
    targets: [
        .target(
            name: "WhoopProtocol",
            resources: [.process("Resources/whoop_protocol.json")]
        ),
        .testTarget(
            name: "WhoopProtocolTests",
            dependencies: ["WhoopProtocol"],
            resources: [.process("Resources")]
        ),
    ]
)
