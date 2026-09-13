// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sensorium",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SensoriumCore", targets: ["SensoriumCore"]),
        .executable(name: "SensoriumCoreTestRunner", targets: ["SensoriumCoreTestRunner"]),
        .library(name: "SensoriumHost", targets: ["SensoriumHost"]),
        .library(name: "SensoriumClient", targets: ["SensoriumClient"]),
        .executable(name: "SensoriumHostTestRunner", targets: ["SensoriumHostTestRunner"]),
        .executable(name: "SensoriumClientTestRunner", targets: ["SensoriumClientTestRunner"]),
        .executable(name: "SensoriumIntegrationTestRunner", targets: ["SensoriumIntegrationTestRunner"]),
        .executable(name: "sensoriumd", targets: ["sensoriumd"]),
        .executable(name: "Sensorium", targets: ["Sensorium"]),
        .executable(name: "SensoriumVirtualDisplayPreflight", targets: ["SensoriumVirtualDisplayPreflight"]),
        .executable(name: "SensoriumQuicProbe", targets: ["SensoriumQuicProbe"]),
        .executable(name: "SensoriumCanvasExerciser", targets: ["SensoriumCanvasExerciser"]),
        .executable(name: "SensoriumLocalWorkspaceInputProbe", targets: ["SensoriumLocalWorkspaceInputProbe"]),
        .executable(name: "SensoriumLocalHostScreenProbe", targets: ["SensoriumLocalHostScreenProbe"])
    ],
    targets: [
        .target(name: "SensoriumCore"),
        .executableTarget(name: "SensoriumCoreTestRunner", dependencies: ["SensoriumCore"]),
        .target(name: "SensoriumVirtualDisplayBridge", path: "Sources/SensoriumVirtualDisplayBridge", publicHeadersPath: "include"),
        .target(name: "SensoriumHost", dependencies: ["SensoriumCore", "SensoriumVirtualDisplayBridge"]),
        .target(name: "SensoriumClient", dependencies: ["SensoriumCore"]),
        .executableTarget(name: "SensoriumHostTestRunner", dependencies: ["SensoriumHost"]),
        .executableTarget(name: "SensoriumClientTestRunner", dependencies: ["SensoriumClient"]),
        .executableTarget(name: "SensoriumIntegrationTestRunner", dependencies: ["SensoriumClient", "SensoriumHost", "SensoriumCore"]),
        .executableTarget(name: "sensoriumd", dependencies: ["SensoriumHost", "SensoriumCore"]),
        .executableTarget(name: "Sensorium", dependencies: ["SensoriumClient", "SensoriumCore"]),
        .executableTarget(name: "SensoriumVirtualDisplayPreflight", dependencies: ["SensoriumHost"]),
        .executableTarget(name: "SensoriumQuicProbe", dependencies: ["SensoriumCore", "SensoriumClient"]),
        .executableTarget(name: "SensoriumCanvasExerciser", dependencies: ["SensoriumCore"]),
        .executableTarget(name: "SensoriumLocalWorkspaceInputProbe", dependencies: ["SensoriumCore", "SensoriumClient"]),
        // Depends on SensoriumHost for the arming record and display inventory
        // this rig has to write and read exactly as the host does.
        .executableTarget(name: "SensoriumLocalHostScreenProbe", dependencies: ["SensoriumCore", "SensoriumClient", "SensoriumHost"])
    ]
)
