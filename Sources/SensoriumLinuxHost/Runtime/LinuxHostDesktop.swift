#if os(Linux)
import Foundation
import SensoriumHost

/// The parts of the real desktop the host keeps running beside the runtime.
public struct LinuxHostDesktop {
    public let platform: LinuxHostPlatform
    /// Polls the screen saver for the lock state and idle time. Stop it when
    /// the host quits.
    public let screenSaver: ScreenSaverMonitor
}

extension LinuxHostPlatform {
    /// The desktop the host runs on: the portal and the screen saver on the
    /// session bus, logind on the system bus, and the layer-shell indicator.
    ///
    /// Throws when there is no session bus, which means there is no graphical
    /// login to host. logind is optional: without it the session's age is
    /// unknown and the host never locks the screen at launch.
    public static func desktop(
        dataFolder: URL,
        askFirst: @escaping @MainActor (AskFirstPromptContent) -> AskFirstOutcome = LinuxHostPlatform.nobodyToAsk
    ) throws -> LinuxHostDesktop {
        let sessionBus = try GDBusConnecting.connectToSessionBus()
        let systemBus = try? GDBusConnecting.connectToSystemBus()
        let screenSaverClient = ScreenSaverClient(bus: sessionBus)
        let screenSaver = ScreenSaverMonitor(reading: screenSaverClient)
        screenSaver.start()
        let platform = LinuxHostPlatform(
            grantOpener: PortalScreenGrantOpener(bus: sessionBus, tokenStore: RestoreTokenStore(dataRoot: dataFolder)),
            makeIndicator: { LinuxHostIndicator() },
            indicatorSupport: { LayerShellSupport.probe() },
            lockState: screenSaver,
            localActivity: screenSaver,
            relocker: screenSaverClient,
            sessionAge: {
                guard let systemBus else { return nil }
                return await LogindSessionAge.read(bus: systemBus)
            },
            askFirst: askFirst
        )
        return LinuxHostDesktop(platform: platform, screenSaver: screenSaver)
    }
}
#endif
