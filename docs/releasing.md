# Releasing

Releases are built on the maintainer's Mac, not in CI. Each release carries two zips, `SHA256SUMS`, and a signed update manifest.

## What you need

| Item | Where | Back it up |
| --- | --- | --- |
| Update key | `$HOME/.sensorium-release/update-key`, or the file named by `SENSORIUM_UPDATE_KEY` | Offline, in a place only you can open |
| Release certificate | Your login keychain | Offline, certificate and private key together |

The update key is one line: the base64 of a 32 byte Ed25519 private key. Only your account may read the file. The script refuses a key that group or others can read.

Lose the update key and no installed app accepts another update. Everyone installs once by hand.

## Create the key once

```
swift Scripts/sign-update.swift generate "$HOME/.sensorium-release/update-key"
```

The command prints the public key and refuses to overwrite a file. Put that public key in `Sources/SensoriumUpdate/UpdatePublicKey.swift` and build the apps with it. Never print or share the key file.

## Release

Create the GitHub release `v<version>` first. Then run:

```
Scripts/release-macos.sh --upload
```

Without `--upload` the script builds and checks everything and prints the upload commands.

The script refuses to continue when:

- the key file is missing or readable by others
- the key does not match the public key compiled into the apps
- either app is signed with a certificate other than the pinned release certificate
- a zip does not unpack to one app, or holds a link that points outside it
- an app fails `--update-self-test`

It uploads the zips and `SHA256SUMS` first, then the manifest and its signature in a separate call. It never replaces a file that is already on the release.

## Forks

Set `SENSORIUM_RELEASE_CERT_LEAF` to the leaf of your own certificate, for example `H"0123..."`. Use your own update key and public key.
