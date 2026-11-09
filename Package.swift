// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EventHorizon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EventHorizon", targets: ["EventHorizon"]),
    ],
    targets: [
        .target(name: "HorizonCore"),
        .executableTarget(
            name: "EventHorizon",
            dependencies: ["HorizonCore"]
        ),
        .testTarget(
            name: "HorizonCoreTests",
            dependencies: ["HorizonCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
