// swift-tools-version: 6.0
// Local-only terminal engine benchmark (ADR 0002). Not part of the app.
import Foundation
import PackageDescription

// SwiftTerm >= 1.12 ships Metal shaders, which only build with full Xcode (`metal` compiler).
// With only Command Line Tools, fall back to 1.11.2 (CoreGraphics renderer only).
let hasXcode = ProcessInfo.processInfo.environment["TERMINALBENCH_XCODE"] == "1"
let swiftTerm: Package.Dependency = hasXcode
    ? .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0")
    : .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.11.2")

let package = Package(
    name: "TerminalBench",
    platforms: [.macOS(.v14)],
    dependencies: [
        swiftTerm,
    ],
    targets: [
        .executableTarget(
            name: "TerminalBench",
            dependencies: ["SwiftTerm"],
            swiftSettings: hasXcode ? [.define("SWIFTTERM_METAL")] : []
        ),
    ]
)
