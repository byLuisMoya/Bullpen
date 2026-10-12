// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bullpen",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Bullpen", targets: ["BullpenApp"]),
        .executable(name: "bp", targets: ["bp"]),
        .executable(name: "bpd", targets: ["bpd"]),
        .library(name: "BPCore", targets: ["BPCore"]),
        .library(name: "BPPersistence", targets: ["BPPersistence"]),
        .library(name: "BPGit", targets: ["BPGit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        // Pinned: 1.12+ ships Metal shaders that only build with full Xcode (ADR 0002).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.11.2"),
    ],
    targets: [
        .target(name: "BPCore"),
        .target(
            name: "BPPersistence",
            dependencies: ["BPCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "BPGit"),
        .target(name: "BPSessions"),
        .target(name: "BPAgents", dependencies: ["BPCore", "BPSessions"]),
        .target(name: "BPHabitat", dependencies: ["BPCore"]),
        .target(name: "BPEnv"),
        .target(name: "BPProviders"),
        .target(name: "BPWorkspace", dependencies: ["BPCore", "BPGit", "BPEnv", "BPAgents", "BPPersistence", "BPSessions"]),
        .executableTarget(name: "bpd", dependencies: ["BPCore", "BPSessions"]),
        .executableTarget(
            name: "BullpenApp",
            dependencies: ["BPCore", "BPPersistence", "BPGit", "BPSessions", "BPAgents", "BPHabitat", "BPEnv", "BPWorkspace", "BPProviders", "SwiftTerm"]
        ),
        .executableTarget(
            name: "bp",
            dependencies: ["BPCore", "BPSessions", "BPAgents", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "BPCoreTests", dependencies: ["BPCore"]),
        .testTarget(name: "BPPersistenceTests", dependencies: ["BPPersistence"]),
        .testTarget(name: "BPGitTests", dependencies: ["BPGit"]),
        .testTarget(name: "BPSessionsTests", dependencies: ["BPSessions"]),
        .testTarget(name: "BPAgentsTests", dependencies: ["BPAgents"]),
        .testTarget(name: "BPHabitatTests", dependencies: ["BPHabitat"]),
        .testTarget(name: "BPEnvTests", dependencies: ["BPEnv"]),
        .testTarget(name: "BPProvidersTests", dependencies: ["BPProviders"]),
        .testTarget(name: "BPWorkspaceTests", dependencies: ["BPWorkspace", "BPGit", "BPSessions", "BPPersistence", "BPAgents", "BPEnv"]),
    ]
)
