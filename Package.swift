// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Isthmus",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IsthmusKit", targets: ["IsthmusKit"]),
        .executable(name: "isthmus", targets: ["isthmus"]),
        .executable(name: "IsthmusApp", targets: ["IsthmusApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "IsthmusKit",
            resources: [.copy("Resources/recipes"), .copy("Resources/launchers.json"), .copy("Resources/components.json")]
        ),
        .executableTarget(
            name: "isthmus",
            dependencies: ["IsthmusKit", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .executableTarget(
            name: "IsthmusApp",
            dependencies: ["IsthmusKit"]
        ),
        .testTarget(
            name: "IsthmusKitTests",
            dependencies: ["IsthmusKit"],
            // Explicit lowercase path: git stores it as tests/ (it shares the
            // folder with tests/winprobes), which matters on case-sensitive checkouts.
            path: "tests/IsthmusKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
