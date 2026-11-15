// swift-tools-version: 6.0
import PackageDescription

// Pure geometry and settings/storage QA only. The macOS app is built from project.yml.
let package = Package(
    name: "TuanTuanGeometryQA",
    platforms: [.macOS(.v15)],
    products: [.library(name: "TuanTuanGeometryQA", targets: ["TuanTuan"])],
    targets: [
        .target(
            name: "TuanTuan",
            path: "Sources/TuanTuan",
            exclude: ["AppDelegate.swift", "PetView.swift", "PetWindowController.swift", "SettingsWindowController.swift", "ChatWindowController.swift", "AgentRuntimeValidation.swift", "CompanionMemoryPane.swift", "main.swift"],
            sources: ["PetGeometry.swift", "AppSettings.swift", "KeychainAPIKeyStore.swift", "AgentTypes.swift", "OpenRouterClient.swift", "ResearchWorker.swift", "ResearchTaskStore.swift", "AgentCoordinator.swift", "MemoryTypes.swift", "CompanionRhythm.swift", "MemoryStore.swift"]
        ),
        .testTarget(name: "TuanTuanTests", dependencies: ["TuanTuan"], path: "Tests/TuanTuanTests")
    ]
)
