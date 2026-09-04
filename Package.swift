// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FinderFix",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "FinderFixCore", targets: ["FinderFixCore"]),
        .executable(name: "FinderFix", targets: ["FinderFixApp"]),
    ],
    targets: [
        .target(
            name: "FinderFixCore",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "FinderFixApp",
            dependencies: ["FinderFixCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "FinderFixCoreTests",
            dependencies: ["FinderFixCore"]
        ),
        .testTarget(
            name: "FinderFixAppTests",
            dependencies: ["FinderFixApp", "FinderFixCore"]
        ),
    ]
)
