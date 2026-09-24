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
        .executable(name: "SensoriumLocalHostScreenProbe", targets: ["SensoriumLocalHostScreenProbe"]),
        .executable(name: "SensoriumViewerProbe", targets: ["SensoriumViewerProbe"])
    ],
    targets: [
        .systemLibrary(
            name: "COpenSSL",
            path: "Sources/COpenSSL",
            pkgConfig: "openssl",
            providers: [.yum(["openssl-devel"]), .apt(["libssl-dev"])]
        ),
        .systemLibrary(
            name: "CAVCodec",
            path: "Sources/CAVCodec",
            pkgConfig: "libavcodec",
            providers: [.yum(["ffmpeg-free-devel", "libva-devel"]), .apt(["libavcodec-dev", "libva-dev"])]
        ),
        .systemLibrary(
            name: "CWayland",
            path: "Sources/CWayland",
            pkgConfig: "wayland-client",
            providers: [
                .yum(["wayland-devel"]),
                .apt(["libwayland-dev", "libwayland-egl1"])
            ]
        ),
        .systemLibrary(
            name: "CEGL",
            path: "Sources/CEGL",
            pkgConfig: "egl",
            providers: [
                .yum(["libglvnd-devel"]),
                .apt(["libegl1-mesa-dev", "libgles2-mesa-dev"])
            ]
        ),
        .systemLibrary(
            name: "CXkbcommon",
            path: "Sources/CXkbcommon",
            pkgConfig: "xkbcommon",
            providers: [.yum(["libxkbcommon-devel"]), .apt(["libxkbcommon-dev"])]
        ),
        .systemLibrary(
            name: "CGLib",
            path: "Sources/CGLib",
            pkgConfig: "glib-2.0",
            providers: [.yum(["glib2-devel"]), .apt(["libglib2.0-dev"])]
        ),
        .systemLibrary(
            name: "CGtk4",
            path: "Sources/CGtk4",
            pkgConfig: "gtk4",
            providers: [.yum(["gtk4-devel"]), .apt(["libgtk-4-dev"])]
        ),
        .systemLibrary(
            name: "CCairo",
            path: "Sources/CCairo",
            pkgConfig: "pangocairo",
            providers: [.yum(["cairo-devel", "pango-devel"]), .apt(["libcairo2-dev", "libpango1.0-dev"])]
        ),
        // Generated, never hand-written -- see its own README.md.
        .target(
            name: "CWaylandProtocols",
            dependencies: ["CWayland"],
            path: "Sources/CWaylandProtocols",
            exclude: ["README.md"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "CGLibDispatchBridge",
            dependencies: ["CGLib"],
            path: "Sources/CGLibDispatchBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CWaylandGlue",
            dependencies: ["CWayland", "CWaylandProtocols"],
            path: "Sources/CWaylandGlue",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CVASurfaceExport",
            path: "Sources/CVASurfaceExport",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("va", .when(platforms: [.linux]))]
        ),
        .target(
            name: "SensoriumCore",
            dependencies: [.target(name: "COpenSSL", condition: .when(platforms: [.linux]))]
        ),
        .executableTarget(name: "SensoriumCoreTestRunner", dependencies: ["SensoriumCore"]),
        .target(name: "SensoriumVirtualDisplayBridge", path: "Sources/SensoriumVirtualDisplayBridge", publicHeadersPath: "include"),
        .target(name: "SensoriumHost", dependencies: ["SensoriumCore", "SensoriumVirtualDisplayBridge"]),
        .target(
            name: "SensoriumClient",
            dependencies: [
                "SensoriumCore",
                .target(name: "COpenSSL", condition: .when(platforms: [.linux])),
                .target(name: "CAVCodec", condition: .when(platforms: [.linux])),
                .target(name: "CWayland", condition: .when(platforms: [.linux])),
                .target(name: "CWaylandProtocols", condition: .when(platforms: [.linux])),
                .target(name: "CEGL", condition: .when(platforms: [.linux])),
                .target(name: "CXkbcommon", condition: .when(platforms: [.linux])),
                .target(name: "CGLib", condition: .when(platforms: [.linux])),
                .target(name: "CGtk4", condition: .when(platforms: [.linux])),
                .target(name: "CCairo", condition: .when(platforms: [.linux])),
                .target(name: "CGLibDispatchBridge", condition: .when(platforms: [.linux])),
                .target(name: "CWaylandGlue", condition: .when(platforms: [.linux])),
                .target(name: "CVASurfaceExport", condition: .when(platforms: [.linux]))
            ]
        ),
        .executableTarget(name: "SensoriumHostTestRunner", dependencies: ["SensoriumHost"]),
        .executableTarget(
            name: "SensoriumClientTestRunner",
            dependencies: [
                "SensoriumClient",
                .target(name: "COpenSSL", condition: .when(platforms: [.linux])),
                .target(name: "CAVCodec", condition: .when(platforms: [.linux])),
                .target(name: "CGLib", condition: .when(platforms: [.linux])),
                .target(name: "CCairo", condition: .when(platforms: [.linux]))
            ],
            exclude: ["Fixtures"]
        ),
        .executableTarget(name: "SensoriumIntegrationTestRunner", dependencies: ["SensoriumClient", "SensoriumHost", "SensoriumCore"]),
        .executableTarget(name: "sensoriumd", dependencies: ["SensoriumHost", "SensoriumCore"]),
        .executableTarget(
            name: "Sensorium",
            dependencies: [
                "SensoriumClient",
                "SensoriumCore",
                .target(name: "CGtk4", condition: .when(platforms: [.linux]))
            ]
        ),
        .executableTarget(name: "SensoriumVirtualDisplayPreflight", dependencies: ["SensoriumHost"]),
        .executableTarget(name: "SensoriumQuicProbe", dependencies: ["SensoriumCore", "SensoriumClient"]),
        .executableTarget(name: "SensoriumCanvasExerciser", dependencies: ["SensoriumCore"]),
        .executableTarget(name: "SensoriumLocalWorkspaceInputProbe", dependencies: ["SensoriumCore", "SensoriumClient"]),
        // Depends on SensoriumHost for the arming record and display inventory
        // this rig has to write and read exactly as the host does.
        .executableTarget(name: "SensoriumLocalHostScreenProbe", dependencies: ["SensoriumCore", "SensoriumClient", "SensoriumHost"]),
        // The Linux viewer's own check rig: the one entry point that dials a
        // host from a machine with no AppKit viewer to launch.
        .executableTarget(
            name: "SensoriumViewerProbe",
            dependencies: [
                "SensoriumClient",
                "SensoriumCore",
                .target(name: "CCairo", condition: .when(platforms: [.linux]))
            ]
        )
    ]
)
