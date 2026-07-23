// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "BannyStudio",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BannyCore", targets: ["BannyCore"]),
        .library(name: "BannyRender", targets: ["BannyRender"]),
        .library(name: "BannyMedia", targets: ["BannyMedia"]),
        .library(name: "BannyCLI", targets: ["BannyCLI"]),
        .executable(name: "banny", targets: ["banny-tool"]),
    ],
    targets: [
        .target(name: "BannyCore"),
        .target(name: "BannyRender", dependencies: ["BannyCore"]),
        .target(name: "BannyMedia", dependencies: ["BannyCore", "BannyRender"]),
        .target(name: "BannyCLI", dependencies: ["BannyCore", "BannyRender", "BannyMedia"]),
        .executableTarget(name: "banny-tool", dependencies: ["BannyCLI"]),
        .testTarget(
            name: "BannyCoreTests",
            dependencies: ["BannyCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "BannyRenderTests", dependencies: ["BannyRender"]),
        .testTarget(name: "BannyMediaTests", dependencies: ["BannyMedia"]),
        .testTarget(
            name: "BannyCLITests",
            dependencies: ["BannyCLI", "BannyCore", "BannyRender", "BannyMedia"]
        ),
    ]
)
