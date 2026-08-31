// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TokenBar", targets: ["TokenBar"]),
    ],
    targets: [
        .executableTarget(name: "TokenBar", path: "Sources/TokenBar"),
        .testTarget(
            name: "TokenBarTests",
            dependencies: ["TokenBar"],
            path: "Tests/TokenBarTests"
        ),
    ]
)
