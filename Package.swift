// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GhosttyKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .macCatalyst(.v16),
    ],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
        .library(name: "ShellCraftKit", targets: ["ShellCraftKit"]),
        .library(name: "GhosttyTheme", targets: ["GhosttyTheme"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/MSDisplayLink.git", from: "2.1.0"),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", "MSDisplayLink"],
            path: "Sources/GhosttyTerminal"
        ),
        .target(
            name: "ShellCraftKit",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/ShellCraftKit"
        ),
        .target(
            name: "GhosttyTheme",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/GhosttyTheme",
            exclude: ["LICENSE"]
        ),
        .binaryTarget(
            name: "libghostty",
            url: "https://github.com/Lakr233/libghostty-spm/releases/download/storage.1.0.1779090382/GhosttyKit.xcframework.zip",
            checksum: "4871c6a2813f54d264250c91230faae30177d230b1e1cdc3b19fd620a8daea63"
        ),
        .testTarget(
            name: "GhosttyKitTest",
            dependencies: ["GhosttyKit", "GhosttyTerminal", "GhosttyTheme", "ShellCraftKit"]
        ),
    ]
)
