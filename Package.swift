// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "agent-lens",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "IPC",                targets: ["IPC"]),
        .library(name: "LSPClient",          targets: ["LSPClient"]),
        .library(name: "LSPServerDetection", targets: ["LSPServerDetection"]),
        .library(name: "FileSystemWatcher",  targets: ["FileSystemWatcher"]),
        .library(name: "Linter",             targets: ["Linter"]),
        .library(name: "DaemonCore",         targets: ["DaemonCore"]),
        .executable(name: "alensd",   targets: ["alensd"]),
        .executable(name: "alens",            targets: ["alens"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser",    from: "1.3.0"),
        // Chunk 3: add swiftlang/swift-tools-protocols for LanguageServerProtocol
        // (requires swift-tools-version 6.2 — defer until toolchain upgrade)
        .package(url: "https://github.com/apple/swift-log",                from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio",                from: "2.65.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess",     from: "0.1.0"),
        .package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", from: "0.14.0"),
        .package(url: "https://github.com/ChimeHQ/JSONRPC",                from: "0.9.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-clocks",       from: "1.0.0"),
    ],
    targets: [
        // MARK: Libraries
        .target(
            name: "IPC",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .target(
            name: "LSPClient",
            dependencies: [
                "IPC",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
                .product(name: "JSONRPC", package: "JSONRPC"),
            ]
        ),
        .target(
            name: "LSPServerDetection",
            dependencies: ["LSPClient"]
        ),
        .target(
            name: "FileSystemWatcher",
            dependencies: []
        ),
        .target(
            name: "Linter",
            dependencies: [
                "IPC",
                "LSPClient",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
        .target(
            name: "DaemonCore",
            dependencies: [
                "IPC",
                "LSPClient",
                "LSPServerDetection",
                "FileSystemWatcher",
                "Linter",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Clocks",       package: "swift-clocks"),
                .product(name: "Logging",      package: "swift-log"),
                .product(name: "NIOCore",      package: "swift-nio"),
                .product(name: "NIOPosix",     package: "swift-nio"),
            ]
        ),

        // MARK: Executables
        .executableTarget(
            name: "alensd",
            dependencies: [
                "DaemonCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging",        package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "alens",
            dependencies: [
                "IPC",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIOCore",        package: "swift-nio"),
                .product(name: "NIOPosix",       package: "swift-nio"),
            ]
        ),

        // MARK: Tests
        .testTarget(
            name: "BuildSmokeTests",
            dependencies: [
                "IPC",
                "LSPClient",
                "LSPServerDetection",
                "FileSystemWatcher",
                "DaemonCore",
            ]
        ),
        .testTarget(
            name: "IPCTests",
            dependencies: ["IPC"]
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["IPC"]
        ),
        .testTarget(
            name: "SocketRoundtripTests",
            dependencies: ["IPC"]
        ),
        .testTarget(
            name: "DaemonCoreTests",
            dependencies: [
                "DaemonCore",
                "IPC",
                "LSPClient",
                "LSPServerDetection",
                "FileSystemWatcher",
                "Linter",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Clocks",       package: "swift-clocks"),
            ]
        ),
        .testTarget(
            name: "LSPClientTests",
            dependencies: [
                "LSPClient",
                "IPC",
                .product(name: "JSONRPC", package: "JSONRPC"),
                .product(name: "Clocks", package: "swift-clocks"),
            ]
        ),
        .testTarget(
            name: "LSPDetectionTests",
            dependencies: [
                "LSPServerDetection",
                "DaemonCore",
                "LSPClient",
                "IPC",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["IPC"]
        ),
    ]
)
