// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudTune",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "CloudTuneCore", targets: ["CloudTuneCore"]),
        .library(name: "CloudTuneUI", targets: ["CloudTuneUI"]),
        .executable(name: "CloudTune", targets: ["CloudTuneMac"])
    ],
    targets: [
        .target(
            name: "CloudTuneCore",
            dependencies: []
        ),
        .target(
            name: "CloudTuneUI",
            dependencies: ["CloudTuneCore"]
        ),
        .executableTarget(
            name: "CloudTuneMac",
            dependencies: ["CloudTuneCore", "CloudTuneUI"]
        ),
        .testTarget(
            name: "CloudTuneCoreTests",
            dependencies: ["CloudTuneCore"]
        ),
        .testTarget(
            name: "CloudTuneUITests",
            dependencies: ["CloudTuneCore", "CloudTuneUI"]
        )
    ]
)
