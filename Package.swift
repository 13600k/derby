// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Derby",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DerbyCore", targets: ["DerbyCore"]),
        .executable(name: "DerbyApp", targets: ["DerbyApp"]),
        .executable(name: "DerbyTests", targets: ["DerbyTests"]),
    ],
    targets: [
        .target(
            name: "DerbyCore",
            path: "Sources/DerbyCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DerbyApp",
            dependencies: ["DerbyCore"],
            path: "Sources/DerbyApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Xcode is not installed in every environment Derby is built in, and
        // Command Line Tools ship neither XCTest nor swift-testing. The suite is
        // therefore a plain executable with a small harness (`Harness.swift`),
        // run with `swift run DerbyTests`.
        .executableTarget(
            name: "DerbyTests",
            dependencies: ["DerbyCore"],
            path: "Tests/DerbyTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
