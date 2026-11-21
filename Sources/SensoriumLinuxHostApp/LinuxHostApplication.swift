#if os(Linux)
import CGLib
import CGtk4
import Foundation
import SensoriumLinuxHost

@MainActor
final class LinuxHostApplication {
    private let gtk: UnsafeMutablePointer<GtkApplication>
    private let autostart = HostAutostart()
    private let appearance: IndicatorAppearance = .dark
    private var runtime: LinuxHostRuntime?
    private var desktop: LinuxHostDesktop?
    private var window: HostMainWindow?
    private var renameWindow: PairedMachineRenameWindow?
    private var cancelAsk: (() -> Void)?
    private var isStopping = false

    init() {
        gtk = sensorium_gtk_application_with_command_line("com.sensorium.host")
    }

    func run() -> Int32 {
        let object = UnsafeMutableRawPointer(gtk)
        let application = sensorium_g_application(object)
        sensorium_g_application_add_switch(application, "background", "Start without opening the host window")
        let context = Unmanaged.passUnretained(self).toOpaque()
        let commandLine: @convention(c) (
            UnsafeMutablePointer<GApplication>?, UnsafeMutablePointer<GApplicationCommandLine>?, UnsafeMutableRawPointer?
        ) -> Int32 = {
            _, command, data in
            guard let command, let data else { return 1 }
            let host = Unmanaged<LinuxHostApplication>.fromOpaque(data).takeUnretainedValue()
            let options = g_application_command_line_get_options_dict(command)
            let background = g_variant_dict_contains(options, "background") != 0
            MainActor.assumeIsolated { host.launch(background: background) }
            return 0
        }
        sensorium_signal_connect(object, "command-line", unsafeBitCast(commandLine, to: (@convention(c) () -> Void).self), context)
        let activate: @convention(c) (UnsafeMutablePointer<GApplication>?, UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data else { return }
            let host = Unmanaged<LinuxHostApplication>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated { host.launch(background: false) }
        }
        sensorium_signal_connect(object, "activate", unsafeBitCast(activate, to: (@convention(c) () -> Void).self), context)

        defer { g_object_unref(object) }
        return withExtendedLifetime(self) {
            g_application_run(application, CommandLine.argc, CommandLine.unsafeArgv)
        }
    }

    private func launch(background: Bool) {
        guard !isStopping else { return }
        if let window {
            if !background { window.show() }
            return
        }
        let dataFolder = RestoreTokenStore.defaultDataRoot()
        var state = HostWindowState(status: .notHosting, grant: .needed, supportsLocalNetwork: false)
        do {
            let desktop = try LinuxHostPlatform.desktop(dataFolder: dataFolder) { [weak self] content in
                self?.askFirst(content) ?? .timedOut
            }
            self.desktop = desktop
            let runtime = LinuxHostRuntime(dataFolder: dataFolder, platform: desktop.platform)
            self.runtime = runtime
            runtime.onStateChange = { [weak self] in self?.updateWindow($0) }
            state = runtime.state
        } catch {
            state.status = .couldNotStart(
                headline: "Sensorium Host could not start",
                detail: "The desktop session could not be reached."
            )
            state.desktop = .unsupported
            print("Sensorium host: no desktop session: \(error)")
        }

        state.openAtLogin = autostart.state
        state.supportsLocalNetwork = runtime?.supportsLocalNetwork ?? false
        let window = HostMainWindow(state: state, appearance: appearance, actions: makeActions())
        self.window = window
        gtk_window_set_application(sensorium_gtk_window(window.toplevel), gtk)
        gtk_window_set_icon_name(sensorium_gtk_window(window.toplevel), "com.sensorium.host")
        g_application_hold(sensorium_g_application(UnsafeMutableRawPointer(gtk)))
        watchSignals()
        if !background { window.show() }
        if let runtime {
            Task { await runtime.start() }
        }
    }

    private func makeActions() -> HostMainWindowActions {
        var actions = HostMainWindowActions()
        actions.stop = { [weak self] in self?.runtime?.stopLiveSession() }
        actions.allowScreenSharing = { [weak self] in self?.runtime?.allowScreenSharing() }
        actions.showPairingCode = { [weak self] in self?.runtime?.showPairingCode() }
        actions.hidePairingCode = { [weak self] in self?.runtime?.hidePairingCode() }
        actions.setSharing = { [weak self] in self?.runtime?.setSharing(machineID: $0, isOn: $1) }
        actions.setAsksFirst = { [weak self] in self?.runtime?.setAsksFirst(machineID: $0, isOn: $1) }
        actions.rename = { [weak self] in self?.rename(machineID: $0, currentName: $1) }
        actions.remove = { [weak self] in self?.runtime?.remove(machineID: $0) }
        actions.setOpenAtLogin = { [weak self] in self?.setOpenAtLogin($0) }
        actions.quit = { [weak self] in self?.quit() }
        return actions
    }

    private func updateWindow(_ state: HostWindowState) {
        guard !isStopping else { return }
        var state = state
        state.openAtLogin = autostart.state
        state.supportsLocalNetwork = runtime?.supportsLocalNetwork ?? false
        window?.update(state)
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        guard let runtime, let window else { return }
        do {
            try autostart.setEnabled(enabled)
        } catch {
            let alert = sensorium_alert_dialog_new("Open at login could not be changed.")
            gtk_alert_dialog_set_detail(alert, error.localizedDescription)
            gtk_alert_dialog_show(alert, sensorium_gtk_window(window.toplevel))
            g_object_unref(UnsafeMutableRawPointer(alert))
        }
        updateWindow(runtime.state)
    }

    private func rename(machineID: String, currentName: String) {
        renameWindow?.dismiss()
        let dialog = PairedMachineRenameWindow(currentName: currentName, appearance: appearance) { [weak self] name in
            self?.runtime?.rename(machineID: machineID, to: name)
            self?.renameWindow = nil
        } onCancel: { [weak self] in
            self?.renameWindow = nil
        }
        renameWindow = dialog
        dialog.show(over: window?.toplevel)
    }

    private func askFirst(_ content: AskFirstPromptContent) -> AskFirstOutcome {
        guard cancelAsk == nil, !isStopping, let loop = g_main_loop_new(nil, 0) else { return .timedOut }
        defer { g_main_loop_unref(loop) }

        // The shared presence gate is synchronous. Keep GTK events and the
        // prompt's countdown running while the gate waits for its answer.
        var answer = AskFirstOutcome.timedOut
        let prompt = AskFirstPromptWindow(content: content, appearance: appearance) { outcome in
            answer = outcome
            g_main_loop_quit(loop)
        }
        cancelAsk = {
            prompt.dismiss()
            g_main_loop_quit(loop)
        }
        prompt.show()
        g_main_loop_run(loop)
        cancelAsk = nil
        return answer
    }

    private func watchSignals() {
        for signal in [SIGTERM, SIGINT] {
            g_unix_signal_add(signal, { data in
                guard let data else { return 0 }
                let host = Unmanaged<LinuxHostApplication>.fromOpaque(data).takeUnretainedValue()
                MainActor.assumeIsolated { host.quit() }
                return 1
            }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func quit() {
        guard !isStopping else { return }
        isStopping = true
        cancelAsk?()
        Task {
            await runtime?.stop()
            desktop?.screenSaver.stop()
            renameWindow?.dismiss()
            window?.hide()
            g_application_quit(sensorium_g_application(UnsafeMutableRawPointer(gtk)))
        }
    }
}
#endif
