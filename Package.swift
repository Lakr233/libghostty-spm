// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GhosttyKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .macCatalyst(.v15),
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
            url: "https://github.com/Lakr233/libghostty-spm/releases/download/storage.1.3.2/GhosttyKit.xcframework.zip",
            checksum: "96f7c968ec94aaa1ac9ae11bc10d23f82ff9b8d80f62e1b2f94c43dbb685277c"
        ),
        .testTarget(
            name: "GhosttyKitTest",
            dependencies: ["GhosttyKit", "GhosttyTerminal", "GhosttyTheme", "ShellCraftKit"]
        ),
    ]
)
