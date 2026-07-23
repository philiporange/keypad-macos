// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Keypad",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Keypad",
            targets: ["Keypad"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Keypad",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit")
            ],
            path: "Sources/Keypad"
        ),
        .testTarget(
            name: "KeypadTests",
            dependencies: ["Keypad"],
            path: "Tests/KeypadTests"
        )
    ]
)
