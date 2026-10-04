// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HondaAnalyzerCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "HondaAnalyzerCore", targets: ["HondaAnalyzerCore"])],
    targets: [
        .target(name: "HondaAnalyzerCore"),
        .testTarget(name: "HondaAnalyzerCoreTests", dependencies: ["HondaAnalyzerCore"])
    ]
)
