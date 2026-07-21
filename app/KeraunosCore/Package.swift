// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KeraunosCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "KeraunosCore", targets: ["KeraunosCore"]),
    ],
    targets: [
        .target(
            name: "KeraunosCore",
            swiftSettings: [.swiftLanguageMode(.v6)]   // Swift 6 mode; default isolation stays `nonisolated`
        ),
        .testTarget(
            name: "KeraunosCoreTests",
            dependencies: ["KeraunosCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
