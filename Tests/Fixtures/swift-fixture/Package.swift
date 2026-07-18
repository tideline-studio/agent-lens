// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-fixture",
    targets: [
        .target(name: "Greeter", path: "Sources/Greeter"),
        .executableTarget(name: "App", dependencies: ["Greeter"], path: "Sources/App")
    ]
)
