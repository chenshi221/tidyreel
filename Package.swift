// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tidyreel",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "tidyreel", targets: ["TidyreelApp"]),
    ],
    targets: [
        // Layer 0: Shared domain models, protocols, codecs, l10n & text utils
        .target(
            name: "TidyreelModels",
            dependencies: []
        ),
        .target(
            name: "TidyreelFakes",
            dependencies: ["TidyreelModels"]
        ),

        // Layer 1: 7 Core Engine Modules
        .target(
            name: "TidyreelParser",
            dependencies: ["TidyreelModels"]
        ),
        .testTarget(
            name: "TidyreelParserTests",
            dependencies: ["TidyreelParser", "TidyreelModels"]
        ),

        .target(
            name: "TidyreelProbe",
            dependencies: ["TidyreelModels"]
        ),
        .testTarget(
            name: "TidyreelProbeTests",
            dependencies: ["TidyreelProbe", "TidyreelModels", "TidyreelFakes"]
        ),

        .target(
            name: "TidyreelMetadata",
            dependencies: ["TidyreelModels"]
        ),
        .testTarget(
            name: "TidyreelMetadataTests",
            dependencies: ["TidyreelMetadata", "TidyreelModels"]
        ),

        .target(
            name: "TidyreelStorage",
            dependencies: ["TidyreelModels"],
            linkerSettings: [
                .linkedFramework("NetFS"),
            ]
        ),
        .testTarget(
            name: "TidyreelStorageTests",
            dependencies: ["TidyreelStorage", "TidyreelModels", "TidyreelFakes"]
        ),

        .target(
            name: "TidyreelPlanner",
            dependencies: ["TidyreelModels"]
        ),
        .testTarget(
            name: "TidyreelPlannerTests",
            dependencies: ["TidyreelPlanner", "TidyreelModels", "TidyreelFakes"]
        ),

        .target(
            name: "TidyreelExecution",
            dependencies: ["TidyreelModels"]
        ),
        .testTarget(
            name: "TidyreelExecutionTests",
            dependencies: ["TidyreelExecution", "TidyreelModels", "TidyreelFakes"]
        ),

        .target(
            name: "TidyreelPersistence",
            dependencies: ["TidyreelModels"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "TidyreelPersistenceTests",
            dependencies: ["TidyreelPersistence", "TidyreelModels", "TidyreelFakes"]
        ),

        // Layer 2: Native macOS Design System, Background Scanners & AppStore
        .target(
            name: "TidyreelDesign",
            dependencies: ["TidyreelModels"]
        ),
        .testTarget(
            name: "TidyreelDesignTests",
            dependencies: ["TidyreelDesign", "TidyreelModels"]
        ),
        .target(
            name: "TidyreelServices",
            dependencies: [
                "TidyreelModels",
                "TidyreelFakes",
                "TidyreelParser",
                "TidyreelProbe",
                "TidyreelMetadata",
                "TidyreelStorage",
                "TidyreelPlanner",
                "TidyreelExecution",
                "TidyreelPersistence",
            ]
        ),
        .testTarget(
            name: "TidyreelServicesTests",
            dependencies: [
                "TidyreelServices",
                "TidyreelModels",
                "TidyreelFakes",
                "TidyreelPersistence",
            ]
        ),

        // Layer 3 (Wave 2): 5 Independent Native macOS UI Feature Modules
        .target(
            name: "TidyreelSourcesUI",
            dependencies: [
                "TidyreelModels",
                "TidyreelDesign",
                "TidyreelServices",
                "TidyreelParser",
                "TidyreelStorage",
            ]
        ),
        .target(
            name: "TidyreelReviewUI",
            dependencies: [
                "TidyreelModels",
                "TidyreelDesign",
                "TidyreelServices",
                "TidyreelPlanner",
            ]
        ),
        .target(
            name: "TidyreelTasksUI",
            dependencies: [
                "TidyreelModels",
                "TidyreelDesign",
                "TidyreelServices",
            ]
        ),
        .target(
            name: "TidyreelHealthUI",
            dependencies: [
                "TidyreelModels",
                "TidyreelDesign",
                "TidyreelServices",
            ]
        ),
        .target(
            name: "TidyreelSettingsUI",
            dependencies: [
                "TidyreelModels",
                "TidyreelDesign",
                "TidyreelServices",
                "TidyreelPlanner",
                "TidyreelMetadata",
            ]
        ),

        // Layer 4: Native macOS App Shell & Entrypoint
        .executableTarget(
            name: "TidyreelApp",
            dependencies: [
                "TidyreelModels",
                "TidyreelDesign",
                "TidyreelServices",
                "TidyreelSourcesUI",
                "TidyreelReviewUI",
                "TidyreelTasksUI",
                "TidyreelHealthUI",
                "TidyreelSettingsUI",
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
