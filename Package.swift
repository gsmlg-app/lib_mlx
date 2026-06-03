// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "lib_mlx_workspace",
    platforms: [
        .iOS("17.0"),
        .macOS("10.14")
    ],
    products: [
        .library(name: "MlxCore", targets: ["MlxCore"]),
        .library(name: "MlxServer", targets: ["MlxServer"]),
        .library(name: "lib-mlx", targets: ["lib_mlx"])
    ],
    targets: [
        .target(name: "MlxCore", path: "ios/lib_mlx/Sources/MlxCore"),
        .target(
            name: "MlxServer",
            dependencies: ["MlxCore"],
            path: "ios/lib_mlx/Sources/MlxServer"
        ),
        .target(
            name: "lib_mlx",
            dependencies: ["MlxCore", "MlxServer"],
            path: "ios/lib_mlx/Sources/lib_mlx",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "MlxServerTests",
            dependencies: ["MlxCore", "MlxServer"],
            path: "Tests/MlxServerTests"
        )
    ]
)
