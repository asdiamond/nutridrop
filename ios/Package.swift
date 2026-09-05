// swift-tools-version: 6.2
import PackageDescription

// Exercise sample construction and durable storage without launching the app
// or requesting access to a real HealthKit database.
let package = Package(
    name: "NutritionCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "NutritionCore", path: "nutridrop",
            exclude: ["APIClient.swift", "AuthSession.swift", "ConnectClient.swift", "ContentView.swift",
                      "nutridropApp.swift", "Info.plist", "nutridrop.entitlements", "Assets.xcassets"],
            sources: ["NutritionStore.swift", "HealthKitClient.swift"]),
        .testTarget(name: "NutritionCoreTests", dependencies: ["NutritionCore"], path: "Tests"),
    ]
)
