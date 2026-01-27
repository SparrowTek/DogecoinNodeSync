// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DogecoinNodeSync",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
//        .package(path: "../../DogecoinKit"),
        .package(url: "https://github.com/SparrowTek/DogecoinKit", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "DogecoinNodeSync",
            dependencies: [
                .product(name: "DogecoinKit", package: "DogecoinKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
