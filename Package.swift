// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "BannyStudio",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BannyCore", targets: ["BannyCore"]),
        .library(name: "BannyRender", targets: ["BannyRender"]),
        .executable(name: "banny-tool", targets: ["banny-tool"]),
    ],
    targets: [
        .target(name: "BannyCore"),
        .target(name: "BannyRender", dependencies: ["BannyCore"]),
        .executableTarget(name: "banny-tool", dependencies: ["BannyCore", "BannyRender"]),
        .testTarget(
            name: "BannyCoreTests",
            dependencies: ["BannyCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "BannyRenderTests", dependencies: ["BannyRender"]),
    ]
)
