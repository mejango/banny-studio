// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "BannyStudio",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "BannyCore", targets: ["BannyCore"])],
    targets: [
        .target(name: "BannyCore"),
        .testTarget(
            name: "BannyCoreTests",
            dependencies: ["BannyCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
