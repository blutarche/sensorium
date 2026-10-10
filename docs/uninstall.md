# Uninstall

Reversible by design. Nothing installs a launch agent or background service, so there is nothing hidden to find. Each macOS app checks for its own updates while it runs, and there is no separate updater. The only login item is the host's own **Open at login**, which is on by default. There is no dedicated uninstaller, so these steps are manual.

1. **Turn off Open at login** in Sensorium Host, so the host app leaves Login Items.
2. **Stop both apps.** Quitting the host releases its canvas. If it was killed instead, the canvas releases when the process exits and its handle drops.
3. **Remove the optional PF firewall anchor**, only if you added it yourself.
   ```sh
   ./Scripts/install-pf-rule.sh --uninstall
   ```
   Follow the printed steps, then run `sudo pfctl -f /etc/pf.conf`.
4. **Remove everything the viewer wrote**, on the viewer machine. This is its key and the saved host, so the pairing is forgotten.
   ```sh
   rm -rf ~/Library/Application\ Support/Sensorium
   ```
   The files inside are `device-identity.json`, `saved-host.json`, `shortcut-strip-pin.json` and, on macOS, `viewer-update-state.json`.
5. **Remove everything the host wrote**, on the host machine.
   ```sh
   rm -rf ~/Library/Application\ Support/Sensorium
   ```
   This holds its keys (`device-identity.json`, `host-tls-identity.json`), the machines it has paired (`approved-devices.json`), the record of which machines may reach the host screen (`host-screen-arming.json`), the local log of host-screen sessions (`host-screen-sessions.log`), what it knows about updates (`host-update-state.json`), and small UI and display-mode preferences.
6. **Delete `Sensorium.app` and `Sensorium Host.app`.**

On Linux the viewer is a Fedora package instead of an app bundle. Remove it in
Discover, the same way it was installed, or with `sudo dnf remove sensorium`.
Removing the package leaves the viewer's own files behind, because they are
yours and not the package's. They are in `$XDG_DATA_HOME/sensorium`, or in
`~/.local/share/sensorium` where that variable is unset, under the same names
as step 4 lists.

```sh
rm -rf ~/.local/share/sensorium
```

There is no cached account state and no telemetry to revoke, because none was ever created.
