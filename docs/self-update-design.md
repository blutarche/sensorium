# Self-update

Installing Sensorium takes two downloads and one approval per app. After that, both apps keep themselves current. Nobody opens Terminal or builds from source, and an update never costs a permission grant.

Sensorium is signed with a self-signed code signing certificate, not an Apple Developer ID, and it is not notarized. That costs one **Open Anyway** per app per machine at first install. It costs nothing after that, because macOS checks downloads the person opens, not files an app writes for itself.

---

## 1. What the person sees

### 1.1 First install

1. On the laptop, download `Sensorium-<version>.zip` from the latest release. On the machine that will host, download `Sensorium-Host-<version>.zip`.
2. Open the zip. Drag the app into Applications.
3. Open the app. macOS refuses it. Click **Done**.
4. In System Settings, open Privacy & Security, then click **Open Anyway** next to the app. The button stays there for about an hour after the refusal.

The app has to run from Applications, or from another folder this user can write to. An app opened straight from Downloads runs from a temporary copy macOS makes for it, and that copy cannot be updated. The app says so in its window and asks to be moved.

### 1.2 Viewer updates

The viewer checks for an update when it opens, then every six hours while it runs. A found update downloads in the background.

When it is ready, *Your Machines* shows one line: *Sensorium `<version>` is ready.* with **Restart Now**. **Restart Now** is offered only while no session window is open. Otherwise the update installs the next time the viewer quits.

### 1.3 Host updates

The host checks on the same schedule. It installs on its own when it is idle: no session live, no pairing in progress. It stops listening, starts the new version beside itself, and quits only once the new version is serving with the same identity, paired machines and address. If the new version does not come up that way, the old one takes its place back and keeps serving. A viewer that tries to connect during those seconds is refused and connects on a later try.

The host window shows one line at the bottom, under **Open at login**:

| State | Line |
| --- | --- |
| Current | *Sensorium Host `<version>`, up to date* |
| Waiting | *Sensorium Host `<new version>` will install when no machine is connected* |
| Failed | *Sensorium Host could not update: `<reason>`. It keeps running `<version>`.* |
| Not updatable | *Move Sensorium Host to Applications and open it again to receive updates.* |

### 1.4 When the two apps disagree

The viewer and the host speak an exact protocol version. Every release so far speaks version 1. When a release changes it, a laptop that updated first may reach a host that has not caught up yet.

From this release on, a host that refuses a hello for its protocol version says which version it runs. This message ships while every release still speaks version 1. The protocol version changes only in a later release, once hosts that can send the message are in use. The version a host names is visible to anything that can reach it, which is its tailnet, or its local network when that setting is on.

The viewer names the problem on the machine's row, on macOS and on Linux alike:

| Case | Row says |
| --- | --- |
| Host older | *`<name>` runs Sensorium Host `<version>`. It updates itself within six hours of being online.* |
| Viewer older | *`<name>` needs a newer Sensorium.* On macOS, with **Restart Now** once the update is ready. |

### 1.5 Settings

| App | Control | Default |
| --- | --- | --- |
| Host | **Install updates automatically**, a checkbox under **Open at login** | On |
| Viewer | **Check for Updates Automatically**, in the Sensorium menu | On |
| Both | **Check for Updates…**, in the Sensorium menu (viewer) or the menu bar item's menu (host). It also clears any recorded failure and tries again. | |

With automatic updates off, the app makes no update request at all until **Check for Updates…** is chosen.

---

## 2. Release

Each release carries four files for macOS beside the Linux package:

| File | Contents |
| --- | --- |
| `Sensorium-<version>.zip` | The viewer alone, universal |
| `Sensorium-Host-<version>.zip` | The host alone, arm64 |
| `sensorium-update.json` | The manifest below |
| `sensorium-update.json.sig` | An Ed25519 signature over the manifest's exact bytes |

```json
{
  "format": 1,
  "version": "0.4.0",
  "minimumMacOS": "13.0",
  "apps": {
    "viewer": {
      "bundleIdentifier": "com.sensorium.viewer",
      "file": "Sensorium-0.4.0.zip",
      "size": 4194304,
      "sha256": "<64 hex characters>"
    },
    "host": {
      "bundleIdentifier": "com.sensorium.host",
      "file": "Sensorium-Host-0.4.0.zip",
      "size": 4194304,
      "sha256": "<64 hex characters>"
    }
  }
}
```

`Scripts/release-macos.sh` builds a release on the maintainer's own machine:

1. Build both apps with `Scripts/package-apps.sh`, signed with the release certificate. It produces one kit holding both apps.
2. Zip each app from that kit on its own, with `ditto -c -k --keepParent`, so each zip holds exactly one app.
3. Write the manifest with each zip's size and SHA-256.
4. Sign the manifest with the update key, through `Scripts/sign-update.swift` (CryptoKit, no dependency). The key is a file only the maintainer's account can read, outside the repository. It holds the 32 byte private key in base64 on one line.
5. Check the result as an app would: verify the signature with the public key compiled into the apps, unzip each app into a scratch folder, and run every check in section 3.3.
6. Upload the two zips with `gh release upload`, then the manifest and its signature last.

The manifest goes last so no app ever reads a manifest whose zips are missing. A release that is already marked latest but has no manifest yet reads as "no update".

Releases are built on the maintainer's own machine, not in CI. CI would need both signing secrets from section 4.

---

## 3. How an app updates

### 3.1 Check

1. Fetch `https://github.com/blutarche/sensorium/releases/latest/download/sensorium-update.json` and its `.sig`. GitHub documents this address as a stable link to the latest release's file, and it does not count against the REST API's rate limit.
2. Use an ephemeral `URLSession`: no cookies, no cache, a 30 second timeout, at most 64 KB per file, and a fixed `User-Agent` of `Sensorium-Update/1`.
3. Verify the signature with `Curve25519.Signing.PublicKey.isValidSignature(_:for:)` against the public key compiled into the app. Stop on any failure.
4. Parse the manifest. Stop unless `format` is 1 and this machine meets `minimumMacOS`.
5. Compare `version` with the running version and with the highest version this app has seen in a valid manifest, which it stores.

The first row that matches decides:

| `version` is | Result |
| --- | --- |
| Lower than the highest seen | A failed check: the release page went backwards |
| Equal to the running version | Up to date |
| Greater than the running version | An update |

The version is inside the signed bytes, so an older signed manifest served again can never install a release older than the running one. Two things need a server to stop, and Sensorium has none. Whoever controls the release page can stop offering a newer release. They can also serve an older signed manifest that is still newer than the running version, which moves an app to that release and not the newest.

### 3.2 Download

1. Build the download address from the manifest: `https://github.com/blutarche/sensorium/releases/download/v<version>/<file>`. The app never follows an address it was handed whole.
2. Download to a temporary file. Stop past the manifest's `size`.
3. Compare the file's SHA-256 with the manifest's.

### 3.3 Stage

1. Ask `FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor:)` for a staging folder on the same volume as the installed app. Set it to mode `0700`.
2. Unzip there with `/usr/bin/ditto -x -k --noqtn --noacl`.
3. The folder must hold exactly one item: a real directory, not a symbolic link, named like the installed app, with the expected bundle identifier and a `CFBundleShortVersionString` equal to the manifest's `version`. No symbolic link inside it may point outside it, and no file may be a device or a hard link.
4. The new app's signature must satisfy the running app's own designated requirement: `SecCodeCopySelf`, then `SecCodeCopyDesignatedRequirement`, then `SecStaticCodeCheckValidity` on the new bundle with that requirement, strict validation, and `kSecCSCheckAllArchitectures` so every slice of the universal viewer is checked. The requirement names the bundle identifier and the release certificate. macOS ties Screen Recording and Accessibility to the same requirement, so passing this check is what keeps the permissions.
5. Run the staged executable with `--update-self-test`. It must exit 0 within 10 seconds. The self-test reads, without changing, the state the app needs to serve: the host's identity and its paired machines, or the viewer's list of machines. It binds no port and writes nothing.

### 3.4 Install

Both apps handle `--update-self-test` and `--replacing` before any other argument. Today any argument the apps do not know ends them with a usage message, so this comes first.

1. Find the installed app from `Bundle.main.bundleURL`. If its path contains `/AppTranslocation/`, macOS is running a temporary copy: stop and show the *Not updatable* line. Stop the same way if the folder that holds the app is not writable by this user.
2. The host stops its listener and stays running. A stopped listener never starts again in the same process, so from here this process only hands over: to the new version, or on failure to a fresh copy of the old one. The viewer installs only at quit or on **Restart Now**.
3. Note what the new version must keep: whether Screen Recording and Accessibility are granted (host), the status of `SMAppService.mainApp`, and for the host what it serves with. That is its identity key's fingerprint, a digest of its paired machines' keys, the tailnet address, port and interface it listened on, and whether it allows connections from the local network.
4. Swap the staged app and the installed app with `renamex_np(staged, installed, RENAME_SWAP)`. The old app now sits in the staging folder. The swap is one step: there is never a moment with no app installed.
5. Check the installed path again as in section 3.3, step 4. On any failure, swap back.
6. Open the new app with `NSWorkspace.openApplication(at:configuration:)`, with `createsNewApplicationInstance` set and the arguments `--replacing <pid> <ready file>`. The ready file is a path inside the staging folder.
7. The new instance starts normally. The host's port is already free. Once its listener reports ready (host) or its window is up (viewer), it writes the ready file with its version and every value from step 3, read from its own running state.
8. The old instance waits up to 60 seconds for that file. It accepts it only if it names the process it launched, the version is the new one, no permission or login item state got worse, and every host value equals its own. It then quits through `NSApplication.terminate`, scheduled from the run loop and never from inside a main-queue block, where AppKit's wait for the shutdown would block the shutdown itself. If the old process has not exited 30 seconds after the ready file, the new instance ends it, once it has confirmed that process still runs this app. The new instance deletes the old app once that process has exited, and only from a folder that is owner-only, holds exactly the ready file and one copy of this app, and is not the folder the app runs from. The ready file is written only into a folder that already exists and is owner-only.
9. Otherwise the old instance asks the new one to quit, forces it after 10 seconds, swaps back, records the failure as section 3.6 says, and opens the restored old app through the same handoff. It quits once that copy is serving. The fresh copy reads the recorded failure and shows the *Failed* line.

At quit, the viewer does steps 1 to 5 and opens nothing. The next time the person opens Sensorium, it is the new version. **Restart Now** goes through every step.

Between step 4 and step 8 the old process reads its bundle by path, and that path now holds the new app. It loads nothing from its bundle during those seconds.

The ready file is the new version's own report. The old instance cannot test the new listener itself: the host admits no connection from this same machine on its product transport, and a dial to its own tailnet address does not come back to it. So a release that listens wrongly but reports the right values passes. What catches it is the next release. The update check and install depend on no session code, so a host whose listener started but serves wrongly still checks and installs a fixed release. A host whose listener never started checks but does not install: it has no values for a new version to match, and a new version on the same machine would most likely fail to listen too.

### 3.5 Host idle rule

The host installs only while no session is live and no pairing is in progress. It checks again right before step 2 of section 3.4.

A host whose session never ends never installs. The host window's *Waiting* line says so.

A relaunch for an update is not a login. `HostAutoLoginLockAtStart` locks the screen of a host that logged in on its own at startup, and a host started with `--replacing` skips it, so an update leaves the screen locked or unlocked as it was.

### 3.6 When an install fails

A failure either means the release itself is bad, or it could pass on another try.

| Kind | Failures | Then | *Failed* line reason |
| --- | --- | --- | --- |
| Bad release | A download that matched the signed manifest, then failed: wrong bundle contents, requirement check fails, or the self-test exits with an error. | That version with that zip's SHA-256 is never tried again. A release with a different zip is. | *the new version is not signed like this one* or *the new version did not start* |
| Could pass on another try | Download fails, times out, or does not match the signed manifest's size or SHA-256. Self-test times out. Swap fails. Ready file late, or its values differ. New instance does not quit when asked. | Tried again at the next check, up to three tries for that version. A retry waits for the next scheduled check, not a relaunch. After the third it counts as a bad release. | *the download did not match the release* or *the new version did not start in time* |

The *Failed* line shows after a bad release, or after the third try. Between tries the *Waiting* line stays. **Check for Updates…** clears every recorded failure and tries at once.

---

## 4. Trust

An update installs only when two independent checks pass:

| Check | Proves | Secret behind it |
| --- | --- | --- |
| Manifest signature, then SHA-256 of the zip | The maintainer published this exact file | Ed25519 update key |
| Designated requirement | The new app is signed by the same certificate as the running one | Release code signing certificate |

| Secret | Kept | If lost |
| --- | --- | --- |
| Ed25519 update key | A file outside the repository on the maintainer's own machine, readable only by the maintainer's account, with an offline backup | Installed apps accept no further update. Everyone installs once by hand a release that carries a new public key. |
| Release certificate | The maintainer's login keychain, with an offline backup of the certificate and key | Updates fail the requirement check. Everyone installs once by hand, and every host grants Screen Recording and Accessibility again. |

Someone who obtains one secret cannot ship an update. They need both, and a way to put files on the release page. All three meet on the maintainer's own machine, so a compromise of that machine could yield all three. Whoever controls that machine can also change the source the maintainer builds, so no handling of the keys closes this. The update key has no passphrase, so a release can be signed without anyone typing one. A copy of the key file alone, from a backup for example, still cannot ship an update. A stolen paired device gains nothing here: updates never travel between the two apps.

A hardware key was not chosen. A key that cannot leave its chip cannot be backed up, and losing it costs every machine a manual install.

Key rotation is out of scope for this version.

---

## 5. Privacy and rule changes

`docs/privacy.md` gains a section:

> Each app fetches two small files from github.com when it opens and every six hours, to learn whether a newer release exists, and downloads that release from GitHub when there is one. GitHub sees your address, when the app asked, and which file it fetched, so it can tell a host from a viewer and which version is being downloaded. Nothing else about you or your machines is sent. Turning automatic updates off stops these requests.

Its "Stored on disk" table gains a row for both apps: `~/Library/Application Support/Sensorium/host-update-state.json` for the host and `viewer-update-state.json` for the viewer, owner-only, each holding the highest version seen, the time of the last check, and each version that failed to install, with its zip's SHA-256 and how many times it was tried. A download and its staging folder live in the system's temporary items folder and are deleted once the update installs or fails.

`docs/macos-permissions.md` says a rebuild drops a grant. That holds for an ad hoc signed build only. It gains that a build signed with the same certificate keeps its grants, an update included. The periodic expiry macOS has applied since Sequoia is separate from updates, and stays as written.

`CLAUDE.md` forbids cloud APIs and a backend. It gains one sentence allowing exactly this: fetching the signed update manifest from the project's GitHub releases, and the release files it names.

---

## 6. Existing installs

Releases before this one have no updater. Moving to the first release with one is a manual install, once.

Screen Recording and Accessibility grants are tied to the certificate an app was signed with. Anyone whose apps were built and signed with their own certificate grants both permissions once more on that first install.

---

## 7. What has been tested

A throwaway app was signed like the host (self-signed certificate, no Team ID, no hardened runtime). It was installed in `/Applications`, registered for **Open at login**, and swapped itself for a newer copy with `renamex_np` and `NSWorkspace.openApplication`. It was tested on macOS 26.6.2.

| Case | Result |
| --- | --- |
| App built locally, never quarantined | Swap `rc=0`. No App Management notice. New version opened with no Gatekeeper dialog. **Open at login** still enabled. |
| App downloaded, quarantined, approved with **Open Anyway** | Same results. The approved app ran from a translocated path, which is why section 3.4 checks for one. |
| Screen locked during the swap and relaunch | Same results. |

A second check covered the permissions. A different program was built under the host's bundle identifier and signed with the host's certificate, then opened through LaunchServices beside the running host. It shared none of the host's code. It found Accessibility and Screen Recording both granted, from the host's existing grants. The same kind of program under a bundle identifier with no grants, opened the same way, found both off.

The real apps were then tested through published releases, on macOS 26.6.2.

| Case | Result |
| --- | --- |
| Host 0.4.0 installed from its release zip over an earlier host | Kept its identity and paired machines, served on the same port, and found itself up to date. |
| Host 0.4.0 updating itself to 0.4.1 | Downloaded, staged, swapped, and the new copy reported ready in under a second, serving on the same port. A paired viewer then streamed the host screen, so Screen Recording was kept. The old copy did not exit: it called `NSApplication.terminate` from inside a main-queue block and waited forever for its own shutdown. Fixed in 0.4.2, which also ends such an old copy after 30 seconds. |
| Viewer 0.4.0 updating itself to 0.4.1 | Downloaded and staged while open, installed when asked to quit from outside the app, and the new copy opened and found itself up to date. |

Still to test:

- Accessibility used directly after an update. It rests on the permissions check above.
- That host machine restarting afterwards and the host coming back serving.
- A host updating after its screen was unlocked from a viewer does not lock the screen again on relaunch.
- macOS 27.

---

## 8. Out of scope

- The Linux viewer's own update. It updates through its package.
- A machine whose user cannot write to Applications. The app shows the *Not updatable* line.
- An Intel Mac as the host. The host is built for Apple silicon only, as before.
- Delta updates, beta channels, and key rotation.

---

## 9. Open decisions

| Decision | Proposed |
| --- | --- |
| How often each app checks | Every six hours, and at launch |
| Whether automatic updates start on | On in both apps, like **Open at login** |
| Whether the update key needs a passphrase at release time | No. Releases are signed without anyone at the keyboard. A copy of the key alone cannot ship an update |

---

## 10. Build order

1. Release zips, the release script, and install documentation. No app changes. This alone removes building from source.
2. The update core, in a new macOS-only target `SensoriumUpdate`: manifest, signature, download, stage, swap, handoff, failure kinds. Unit tested against a local fake of the release page, with no network. It depends on no listener or session code.
3. The version refusal message from section 1.4, in both viewers and the host.
4. The viewer's use of the update core.
5. The host's use of it, with the idle rule, then the live tests in section 7.
