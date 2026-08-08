# PlayCover ExStorage

PlayCover ExStorage is a macOS utility that moves a PlayCover app's container data to a dedicated APFS volume on an external drive. The volume is then mounted directly at the app's `Data` directory, so the app continues to use its normal container path while its data lives on external storage.

> This project performs privileged disk and filesystem operations. Keep a separate backup of important data and test with non-critical apps first.

## Requirements

- macOS 13 Ventura or later
- An external drive containing an APFS container
- An Apple Development or Developer ID signing team when building from source
- Administrator approval for the bundled privileged helper

The app only lists external APFS containers. Internal disks and non-APFS filesystems are rejected by the privileged helper.

## Features

- **Migrate App Data** creates a dedicated APFS volume named after the selected app's Bundle ID, copies the app's local `Data`, preserves it as `Data.backup`, and mounts the new volume at the original `Data` path.
- **Reconnect Volume** finds the matching Bundle ID volume on the selected external disk and mounts it back at the app's `Data` path after a drive has been disconnected and reattached.
- **Restore Local Data** copies data back when necessary, removes the migrated APFS volume, and restores a normal local `Data` directory.
- **Remove Local Backup** permanently removes `Data.backup` after the migrated app has been verified to work.

The drive list uses these states:

- Green: the matching volume is mounted at the selected app's `Data` directory.
- Yellow: a matching volume exists but is disconnected or mounted elsewhere.
- Gray: no volume matches the selected app.

## Data layout

For an app with Bundle ID `com.example.game`, migration changes the layout from:

```text
~/Library/Containers/com.example.game/Data
```

to:

```text
~/Library/Containers/com.example.game/Data.backup  # local safety copy
~/Library/Containers/com.example.game/Data         # mount point for the external APFS volume
```

The dedicated external APFS volume is named `com.example.game`.

## Building from source

1. Clone the repository.
2. Open `PlayCover ExStorage.xcodeproj` in Xcode.
3. Select the **PlayCover ExStorage** target and choose your Development Team under **Signing & Capabilities**.
4. Select the **PrivilegedHelper** target and choose the same Development Team.
5. Build and run the **PlayCover ExStorage** scheme.
6. On first use, approve PlayCover ExStorage under **System Settings → General → Login Items** if macOS requests approval.

The main app and Helper verify that they have the expected Bundle IDs and are signed by the same Team ID. The Team ID is read from the running code signature rather than hard-coded in source.

## Privileged helper

The app uses `SMAppService` and an XPC LaunchDaemon on macOS 13+. The main app decides the workflow; the Helper only exposes constrained primitives for:

- Creating and deleting external APFS volumes
- Mounting and unmounting external APFS volumes
- Copying, renaming, and deleting the selected app's `Data` or `Data.backup`

The Helper runs as root, so it does not invoke `sudo`. It validates device identifiers, rejects internal/non-APFS disks, and restricts filesystem paths to supported app-container and external-volume locations.

## Safe workflow

1. Quit the app being migrated.
2. Drag its `.app` bundle into PlayCover ExStorage.
3. Select the intended external APFS container.
4. Click **Migrate App Data** and wait for completion.
5. Launch the migrated app and verify its data.
6. Keep `Data.backup` until you are confident migration succeeded.
7. Use **Remove Local Backup** only when that recovery copy is no longer needed.

Do not disconnect the external drive during migration, restore, or backup deletion.

## Creating a distributable build

For public distribution, archive the app with a Developer ID Application certificate, notarize it with Apple, staple the notarization ticket, and distribute the signed app as a `.dmg` or `.zip` through GitHub Releases. Build products and signing credentials should not be committed to the source repository.

## License

No license has been selected yet. Until a license file is added, normal copyright restrictions apply.
