// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bullpen",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Bullpen", targets: ["BullpenApp"]),
        .executable(name: "bp", targets: ["bp"]),
        .library(name: "BPCore", targets: ["BPCore"]),
        .library(name: "BPPersistence", targets: ["BPPersistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    ],
    targets: [
        .target(name: "BPCore"),
        .target(
            name: "BPPersistence",
            dependencies: ["BPCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "BullpenApp",
            dependencies: ["BPCore", "BPPersistence"]
        ),
        .executableTarget(
            name: "bp",
            dependencies: ["BPCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "BPCoreTests", dependencies: ["BPCore"]),
        .testTarget(name: "BPPersistenceTests", dependencies: ["BPPersistence"]),
    ]
)
