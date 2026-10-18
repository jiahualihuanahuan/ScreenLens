// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenLens",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ScreenLens", targets: ["ScreenLens"])
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.0")
    ],
    targets: [
        .executableTarget(
            name: "ScreenLens",
            dependencies: ["HotKey"]
        )
    ]
)
