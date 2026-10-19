// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenLens",
    platforms: [
        .macOS(.v13)
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
