// swift-tools-version: 6.0
// StudyGraph: every piece of Thuban Study that talks to the Thuban Graph engine (Thuban Graph
// docs/STUDY_INTEGRATION.md §3.1). The app imports only this module in the graph pane, the calculator panel, the
// settings and tool execution; the Graph modules are imported `internal`ly here so their type names (MathEngine,
// ResolvedTheme, ThemeSelection, …) and view extensions (`12.z`, `\.thubanTheme`) never reach the app, where
// ThubanCore owns those names.
//
// ThubanGraphCore is reached through the gitignored symlink `Vendor/ThubanGraph` that scripts/link-graph.sh creates
// (THUBAN_GRAPH_ROOT overrides the default Graph checkout).
import PackageDescription

let package = Package(
    name: "StudyGraph",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StudyGraph", targets: ["StudyGraph"]),
    ],
    dependencies: [
        .package(path: "../ThubanCore"),
        .package(path: "../../Vendor/ThubanGraph/Packages/ThubanGraphCore"),
    ],
    targets: [
        .target(
            name: "StudyGraph",
            dependencies: [
                "ThubanCore",
                .product(name: "ThubanGraphKit", package: "ThubanGraphCore"),
                .product(name: "GraphModel", package: "ThubanGraphCore"),
                .product(name: "GraphTypes", package: "ThubanGraphCore"),
                .product(name: "GraphEngine", package: "ThubanGraphCore"),
                .product(name: "GraphTheme", package: "ThubanGraphCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "StudyGraphTests",
            dependencies: [
                "StudyGraph",
                "ThubanCore",
                .product(name: "ThubanGraphKit", package: "ThubanGraphCore"),
                .product(name: "GraphModel", package: "ThubanGraphCore"),
                .product(name: "GraphTypes", package: "ThubanGraphCore"),
                .product(name: "GraphEngine", package: "ThubanGraphCore"),
                .product(name: "GraphTheme", package: "ThubanGraphCore"),
            ],
            // Golden/ holds the tool-schema golden files, read from the source tree (#filePath).
            exclude: ["Golden"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
