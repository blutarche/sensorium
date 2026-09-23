# Uninstall

Reversible by design. Nothing installs a launch agent, login item, background service, or auto-updater, so there is nothing hidden to find. There is no dedicated uninstaller, so these steps are manual.

1. **Stop both apps.** Quitting the host releases its canvas. If it was killed instead, the canvas releases when the process exits and its handle drops.
2. **Remove the optional PF firewall anchor**, only if you added it yourself.
   ```sh
   ./Scripts/install-pf-rule.sh --uninstall
   ```
   Follow the printed steps, then run `sudo pfctl -f /etc/pf.conf`.
3. **Remove everything the viewer wrote**, on the viewer machine. This is its key, the saved host, and its presence credential record, so the pairing is forgotten.
   ```sh
   rm -rf ~/Library/Application\ Support/Sensorium
   ```
   The files inside are `device-identity.json`, `saved-host.json`, and `presence-credential.json`.
4. **Remove everything the host wrote**, on the host machine.
   ```sh
   rm -rf ~/Library/Application\ Support/Sensorium
   ```
   This holds its keys (`device-identity.json`, `host-tls-identity.json`), the record of which machines may reach the host screen (`host-screen-arming.json`), the local log of host-screen sessions (`host-screen-sessions.log`), and small UI and display-mode preferences.
5. **Delete `Sensorium.app` and `Sensorium Host.app`.**

There is no cached account state and no telemetry to revoke, because none was ever created.
