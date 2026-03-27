// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BatteryCountdown",
    platforms: [.macOS(.v13)],
    products: [
        .executable(
            name: "BatteryCountdown",
            targets: ["BatteryCountdown"]
        )
    ],
    targets: [
        .executableTarget(
            name: "BatteryCountdown",
            path: "Sources"
        )
    ]
)
