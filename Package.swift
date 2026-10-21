// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "bridgectl",
    platforms: [.macOS(.v13)],
    targets: [
        // Shared logic: config, ssh helpers, provisioning bridges on relays.
        .target(name: "BridgeCore"),
        // The menu bar app (bundled as BridgeCtl.app by scripts/install.sh).
        .executableTarget(name: "BridgeCtlApp", dependencies: ["BridgeCore"]),
        // The command-line interface.
        .executableTarget(name: "bridgectl", dependencies: ["BridgeCore"]),
    ]
)
