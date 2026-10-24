// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JS8Core",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JS8Core", targets: ["JS8Core"]),
    ],
    targets: [
        .target(
            name: "JS8Core",
            resources: [.copy("Resources/jsc.bin")],
            // The modem is DSP-heavy; always build it optimised so Debug app
            // builds still decode in real time.
            swiftSettings: [
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .testTarget(name: "JS8CoreTests", dependencies: ["JS8Core"]),
    ]
)
