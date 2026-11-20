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
        .library(name: "SensoriumUpdate", targets: ["SensoriumUpdate"]),
        .executable(name: "SensoriumUpdateTestRunner", targets: ["SensoriumUpdateTestRunner"]),
        .library(name: "SensoriumLinuxUpdate", targets: ["SensoriumLinuxUpdate"]),
        .executable(name: "SensoriumLinuxUpdateTestRunner", targets: ["SensoriumLinuxUpdateTestRunner"]),
        .library(name: "SensoriumLinuxHost", targets: ["SensoriumLinuxHost"]),
        .executable(name: "SensoriumLinuxHostTestRunner", targets: ["SensoriumLinuxHostTestRunner"]),
        .executable(name: "SensoriumPortalProbe", targets: ["SensoriumPortalProbe"]),
        .executable(name: "sensoriumd", targets: ["sensoriumd"]),
        .executable(name: "Sensorium", targets: ["Sensorium"]),
        .executable(name: "SensoriumVirtualDisplayPreflight", targets: ["SensoriumVirtualDisplayPreflight"]),
        .executable(name: "SensoriumQuicProbe", targets: ["SensoriumQuicProbe"]),
        .executable(name: "SensoriumCanvasExerciser", targets: ["SensoriumCanvasExerciser"]),
        .executable(name: "SensoriumBenchHost", targets: ["SensoriumBenchHost"]),
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
        // GDBus and the Unix file-descriptor list the portal hands a
        // PipeWire remote over. Both ship in the GLib development package.
        .systemLibrary(
            name: "CGio",
            path: "Sources/CGio",
            pkgConfig: "gio-unix-2.0",
            providers: [.yum(["glib2-devel"]), .apt(["libglib2.0-dev"])]
        ),
        .systemLibrary(
            name: "CPipeWire",
            path: "Sources/CPipeWire",
            pkgConfig: "libpipewire-0.3",
            providers: [.yum(["pipewire-devel"]), .apt(["libpipewire-0.3-dev"])]
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
        // The PipeWire stream callbacks and format pods are C macros and
        // inline functions Swift cannot import; this wraps them behind a plain
        // C interface. Empty off Linux.
        .target(
            name: "CSensoriumPipeWireGlue",
            dependencies: ["CPipeWire"],
            path: "Sources/CSensoriumPipeWireGlue",
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
        .target(name: "SensoriumHost", dependencies: ["SensoriumCore", "SensoriumVirtualDisplayBridge", "SensoriumUpdate"]),
        .target(
            name: "SensoriumClient",
            dependencies: [
                "SensoriumCore",
                .target(name: "SensoriumUpdate", condition: .when(platforms: [.macOS])),
                .target(name: "SensoriumLinuxUpdate", condition: .when(platforms: [.linux])),
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
        .executableTarget(name: "SensoriumHostTestRunner", dependencies: ["SensoriumHost", "SensoriumUpdate"]),
        .executableTarget(
            name: "SensoriumClientTestRunner",
            dependencies: [
                "SensoriumClient",
                .target(name: "SensoriumUpdate", condition: .when(platforms: [.macOS])),
                .target(name: "SensoriumLinuxUpdate", condition: .when(platforms: [.linux])),
                .target(name: "COpenSSL", condition: .when(platforms: [.linux])),
                .target(name: "CAVCodec", condition: .when(platforms: [.linux])),
                .target(name: "CGLib", condition: .when(platforms: [.linux])),
                .target(name: "CCairo", condition: .when(platforms: [.linux]))
            ],
            exclude: ["Fixtures"]
        ),
        .executableTarget(name: "SensoriumIntegrationTestRunner", dependencies: ["SensoriumClient", "SensoriumHost", "SensoriumCore"]),
        // macOS only: every source is inside `#if os(macOS)`. The Linux viewer
        // updates itself through `SensoriumLinuxUpdate` instead.
        .target(name: "SensoriumUpdate", dependencies: ["SensoriumCore"]),
        .executableTarget(name: "SensoriumUpdateTestRunner", dependencies: ["SensoriumUpdate", "SensoriumCore"]),
        // The Linux viewer's update engine. Platform-neutral, so its runner
        // also passes on macOS.
        .target(name: "SensoriumLinuxUpdate", dependencies: ["SensoriumCore"]),
        .executableTarget(name: "SensoriumLinuxUpdateTestRunner", dependencies: ["SensoriumLinuxUpdate", "SensoriumCore"]),
        // The Linux host's portal session, PipeWire capture and input
        // injection. Every source is inside `#if os(Linux)`.
        .target(
            name: "SensoriumLinuxHost",
            dependencies: [
                "SensoriumCore",
                .target(name: "CGio", condition: .when(platforms: [.linux])),
                .target(name: "CSensoriumPipeWireGlue", condition: .when(platforms: [.linux]))
            ]
        ),
        // SensoriumClient is only here to check the key map against the
        // Linux viewer's own table.
        .executableTarget(
            name: "SensoriumLinuxHostTestRunner",
            dependencies: [
                "SensoriumLinuxHost",
                "SensoriumCore",
                .target(name: "SensoriumClient", condition: .when(platforms: [.linux]))
            ]
        ),
        // Test scaffolding: asks the portal for a session and reports what it
        // granted. Refuses to run outside a nested session bus.
        .executableTarget(
            name: "SensoriumPortalProbe",
            dependencies: ["SensoriumLinuxHost", "SensoriumCore"]
        ),
        .executableTarget(name: "sensoriumd", dependencies: ["SensoriumHost", "SensoriumCore", "SensoriumUpdate"]),
        .executableTarget(
            name: "Sensorium",
            dependencies: [
                "SensoriumClient",
                "SensoriumCore",
                .target(name: "SensoriumUpdate", condition: .when(platforms: [.macOS])),
                .target(name: "SensoriumLinuxUpdate", condition: .when(platforms: [.linux])),
                .target(name: "CGtk4", condition: .when(platforms: [.linux]))
            ]
        ),
        .executableTarget(name: "SensoriumVirtualDisplayPreflight", dependencies: ["SensoriumHost"]),
        .executableTarget(name: "SensoriumQuicProbe", dependencies: ["SensoriumCore", "SensoriumClient"]),
        .executableTarget(name: "SensoriumCanvasExerciser", dependencies: ["SensoriumCore"]),
        // Test scaffolding, never bundled: streams synthetic frames through the
        // real host pipeline and listener.
        .executableTarget(name: "SensoriumBenchHost", dependencies: ["SensoriumHost", "SensoriumCore", "SensoriumClient"]),
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
                .target(name: "SensoriumLinuxUpdate", condition: .when(platforms: [.linux])),
                .target(name: "CCairo", condition: .when(platforms: [.linux])),
                .target(name: "CGtk4", condition: .when(platforms: [.linux]))
            ]
        )
    ]
)
