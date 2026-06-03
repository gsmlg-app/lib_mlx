// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "lib_mlx",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .library(name: "MlxCore", targets: ["MlxCore"]),
        .library(name: "MlxServer", targets: ["MlxServer"]),
        .library(name: "lib-mlx", targets: ["lib_mlx"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(name: "MlxCore"),
        .target(name: "MlxServer", dependencies: ["MlxCore"]),
        .target(
            name: "lib_mlx",
            dependencies: [
                "MlxCore",
                "MlxServer",
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            publicHeadersPath: "include"
        )
    ]
)
