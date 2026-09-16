// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThubanCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ThubanCore", targets: ["ThubanCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/CoreOffice/CoreXLSX.git", from: "0.14.0"),
    ],
    targets: [
        .target(
            name: "ThubanCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "CoreXLSX", package: "CoreXLSX"),
            ],
            resources: [.copy("Resources/compute-engine.umd.cjs")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ThubanCoreTests",
            dependencies: ["ThubanCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
