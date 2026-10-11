// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Weatherglass",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic: weather mapping, Open-Meteo client, window geometry, snow model.
        // No AppKit, so it is fast to test.
        .target(name: "WeatherglassCore"),
        // The menu bar app and the Core Animation effects.
        .executableTarget(
            name: "Weatherglass",
            dependencies: ["WeatherglassCore"]
        ),
        .testTarget(
            name: "WeatherglassCoreTests",
            dependencies: ["WeatherglassCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
