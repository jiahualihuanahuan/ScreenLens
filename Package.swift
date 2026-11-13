// swift-tools-version: 5.9
import PackageDescription

// ScreenLensCore holds the platform-independent logic (geometry, chrome trimming, OCR planning,
// de-duplication). It only needs Foundation, so `swift test` runs it on macOS and Linux.
var products: [Product] = []
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "ScreenLensCore"),
    .testTarget(name: "ScreenLensCoreTests", dependencies: ["ScreenLensCore"])
]

#if os(macOS)
// The menu bar app itself needs AppKit / Vision / ScreenCaptureKit, so it is macOS-only.
products.append(.executable(name: "ScreenLens", targets: ["ScreenLens"]))
dependencies.append(.package(url: "https://github.com/soffes/HotKey", from: "0.2.0"))
targets.append(
    .executableTarget(
        name: "ScreenLens",
        dependencies: ["HotKey", "ScreenLensCore"]
    )
)
#endif

let package = Package(
    name: "ScreenLens",
    platforms: [
        .macOS(.v13)
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
