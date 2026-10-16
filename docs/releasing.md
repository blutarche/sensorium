# Releasing

Releases are built on the maintainer's own machine, which runs macOS, not in CI. Each release carries two disk images for people to download, two zips that only self-update uses, `SHA256SUMS`, and a signed update manifest.

Each disk image holds one app and a link to Applications. The disk image itself is not signed. The app inside it is the signed app, and it is the same app as the one in the matching zip.

## The disk image window

A disk image opens to a fixed window with no toolbar or sidebar. The app sits on the left, Applications on the right, and a background picture shows the drag from one to the other. Each app has its own picture. Both draw the same two machines: a laptop for the viewer and a desk display for the host. Only their order differs. The app's own machine stands in front. The volume uses the app's icon.

| File on the volume | Made by | Holds |
| --- | --- | --- |
| `.background/background.tiff` | `Scripts/make-dmg-background.swift viewer` or `host`, then `tiffutil` | The app's picture, at 1x and 2x |
| `.DS_Store` | `Scripts/make-dmg-layout.swift` | Window size, icon size, icon positions, a link to the picture |
| `.VolumeIcon.icns` | Copied from the app | The volume icon |

The picture and the icon file are hidden in Finder. When Finder is set to show hidden files, they sit outside the window.

The volume name carries the version, for example `Sensorium 1.2.3`. Finder finds the picture by volume name. With the version in the name, another Sensorium disk image still mounted cannot lend its picture.

Do not arrange the window in Finder. Finder's `.DS_Store` records details of the build machine:

- the path of the disk image file
- the name of the startup disk
- temporary folder paths and volume identifiers

Every download would carry them. The script writes the file itself instead. Its link to the picture names only the volume and a path inside it. The release script refuses a `.DS_Store` that names a path of the build machine.

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
- the unit tests fail. The script runs `Scripts/run-unit-tests.sh` before it builds anything, with or without `--upload`. Continuous integration skips the tests that open windows, so this run is the one that covers them.
- either app is signed with a certificate other than the pinned release certificate
- a zip does not unpack to one app, or holds a link that points outside it
- a file in an app names a folder of the machine that built it
- an app fails `--update-self-test`
- a disk image does not attach, or shows anything but the app and a link named `Applications` that points to `/Applications`
- an app has no icon for its disk image
- a disk image lacks its window file, its picture or its volume icon, or its window file names a path of the build machine
- an app in a disk image fails the same checks as its zip
- an app in a disk image is not the same build as the app in its zip, by code directory hash

It uploads the zips, the disk images and `SHA256SUMS` first, then the manifest and its signature in a separate call. It never replaces a file that is already on the release.

## Forks

Set `SENSORIUM_RELEASE_CERT_LEAF` to the leaf of your own certificate, for example `H"0123..."`. Use your own update key and public key.
