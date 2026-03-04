
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimpleTonerBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SimpleTonerBar", targets: ["SimpleTonerBar"])
    ],
    dependencies: [
        .package(url: "https://github.com/darrellroot/SwiftSnmpKit", from: "0.2.0")
    ],
    targets: [
        .executableTarget(
            name: "SimpleTonerBar",
            dependencies: ["SwiftSnmpKit"],
            path: "Sources/SimpleTonerBar"
        )
    ]
)
