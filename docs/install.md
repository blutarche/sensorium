# Install

What you need, and how to pair the two apps.

## Requirements

- One viewer machine and one host machine. macOS 13 or later on both machines. Built and tested only on macOS 26. Linux support is planned.
- Both machines joined to the same Tailscale tailnet.

## Build the two apps

There are no prebuilt downloads. Build on either machine with the Swift toolchain from Command Line Tools.

```sh
SENSORIUM_ALLOW_ADHOC=1 ./Scripts/package-apps.sh
```

1. The apps land in `Artifacts/Sensorium/`.
2. Put `Sensorium Host.app` on the machine that will host.
3. Put `Sensorium.app` on the machine you will work from.

The apps are not notarized. If macOS blocks one, do not disable Gatekeeper or strip its quarantine attribute.

### Keeping permissions across rebuilds

Ad-hoc signing changes with every build. After each rebuild macOS asks again for Screen Recording and Accessibility.

To avoid that, make a self-signed code signing certificate once:

1. Open Keychain Access. Choose Keychain Access > Certificate Assistant > Create a Certificate.
2. Name it `Sensorium`. Set Certificate Type to Code Signing.
3. Double-click the new certificate in the login keychain. Expand Trust. Set Code Signing to Always Trust.
4. Build without the ad-hoc variable. The script signs with that certificate.
5. macOS asks for your login password three times, once per signature. Click Allow each time.

A signed release built with an Apple Team ID would keep the grants across rebuilds without this step. This build is not signed that way.

## Grant permissions

1. Open `Sensorium Host.app`.
2. Its window names any setting it still needs. Click the button it shows, and grant that permission in System Settings.

See [macOS permissions](macos-permissions.md) for what each permission is for, and why macOS can ask again after a rebuild or a restart.

## Pair the two apps

1. On the host machine, in `Sensorium Host.app`, click **Show pairing code**. It shows a temporary six-digit code.
2. On the machine you work from, open `Sensorium.app`. Pick the host from the tailnet list, or click **Enter address manually…** if it is not listed.
3. Type the six-digit code shown on the host.

## Start a session

1. Once paired, `Sensorium.app` shows a ready state naming the host.
2. Press Connect to start a session. The session window opens, named after the host.
3. Its Stop control, or quitting the app, ends the session at once and releases anything the session was holding.

## Current limitations

The optional PF firewall anchor described in [the threat model](threat-model.md) is not installed by Sensorium. Add it yourself for that extra layer. See [privacy](privacy.md) and [the threat model](threat-model.md) for what Sensorium does and does not protect.
