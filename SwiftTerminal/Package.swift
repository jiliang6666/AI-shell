// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftTerminal",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SwiftTerminal", targets: ["SwiftTerminal"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", branch: "v1.x"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .executableTarget(
            name: "SwiftTerminal",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
                "CSQLite"
            ]
        ),
        .testTarget(
            name: "SwiftTerminalTests",
            dependencies: ["SwiftTerminal"]
        )
    ]
)
