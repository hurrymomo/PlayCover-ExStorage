# PlayCover ExStorage

[English](README.md) | [简体中文](README.zh-CN.md)

PlayCover ExStorage is a macOS utility for moving PlayCover Apps and their container data between local storage and external APFS containers. External App data is stored on a dedicated APFS Volume and mounted directly at the App's normal `Data` path, so the App can continue using its standard container location.

> PlayCover ExStorage performs privileged disk and filesystem operations. Back up important data and test with non-critical Apps first.

## Requirements

- macOS 13 Ventura or later
- An external drive containing an APFS container
- Administrator approval for the bundled privileged helper
- An Apple Development or Developer ID signing team when building from source

Only external APFS containers are accepted. Internal disks and unsupported filesystems are rejected by the privileged helper.

## What's new in 1.2.0

- Added a multi-App library with optional **Keep in Library** persistence.
- Added App-only, Data-only, and App & Data migration between local storage and external containers, including direct container-to-container migration.
- Added a serial migration queue, durable checkpoints, copy verification, recovery after interruption, and transactional rollback for App & Data migrations.
- Added an `ExStorage` management Volume for App bundles and per-App metadata, plus dedicated Data Volumes identified by UUID.
- Added per-App operation state so connecting or disconnecting one App does not overwrite another App's migration progress.
- Added **Connect & Open**, local Data conflict handling, and access to otherwise unmanaged Volumes.
- Improved deletion choices, migration validation, status presentation, and mount cleanup.
- Added signed Sparkle update support for releases after 1.2.0.

## Downloading the test build

GitHub Releases provides a Universal macOS build for Apple Silicon and Intel Macs. The current test build is signed with an Apple Development certificate and is not notarized by Apple.

1. Download the `.dmg` from [GitHub Releases](https://github.com/hurrymomo/PlayCover-ExStorage/releases).
2. Drag **PlayCover ExStorage** into **Applications**.
3. Open the App once. If macOS blocks it, open **System Settings → Privacy & Security** and choose **Open Anyway**.
4. When requested, approve PlayCover ExStorage under **System Settings → General → Login Items**.
5. Grant Full Disk Access if macOS prevents mounting a Volume at an App container's `Data` directory.

Only install builds downloaded from this repository.

## Main features

- Drag one or more `.app` bundles into the library and optionally keep their records across launches.
- Move an App, its Data, or both between local storage and an external APFS container.
- Move managed Apps and Data directly between two external containers.
- Queue multiple migrations; they are processed one at a time.
- Verify copied content before committing a migration and preserve enough state to recover an interrupted active migration.
- Connect a disconnected Data Volume at `~/Library/Containers/<bundle-id>/Data`, then open the App.
- Restore managed content to local storage. App bundles use their last verified local path when possible.
- Delete the App, Data, or both independently.

## External storage layout

Each managed APFS container has one management Volume named `ExStorage`:

```text
ExStorage/
├── Applications/          # managed .app bundles
└── AppInfo/               # per-App metadata
```

Each managed App also has a dedicated Data Volume. Its UUID is recorded in AppInfo; the Volume name is the App's Bundle ID. When connected, that Volume is mounted at:

```text
~/Library/Containers/<bundle-id>/Data
```

AppInfo records the Bundle ID, Data Volume UUID, schema version, and the last verified local App path hint. The hint is verified before it is used.

## Migration safety

- App copies use a hidden staging directory on the destination, are verified, and are committed only after verification succeeds.
- Data copies use resumable `rsync`, compare source and destination manifests, and remove unexpected destination files.
- App & Data migration is treated as one transaction. If its second component fails, the completed component is moved back when rollback succeeds.
- Only the active migration has a durable local recovery record. Queued requests are session state.
- Do not disconnect an external drive or launch the affected App while its migration is running.

If non-empty local Data exists when connecting an external Data Volume, choose whether to remove it or leave it hidden beneath the mount. Hidden local Data remains on disk and becomes visible again after the external Volume is disconnected.

## Local records and logs

Apps kept in the library are stored under the `ManagedApps` key in:

```text
~/Library/Preferences/momo.PlayCover-ExStorage.plist
```

Active migration recovery records are stored in:

```text
~/Library/Application Support/PlayCover ExStorage/Migrations/
```

Operation logs are stored under:

```text
~/Library/Logs/PlayCover ExStorage/
```

## Building from source

1. Clone the repository.
2. Open `PlayCover ExStorage.xcodeproj` in Xcode.
3. Select the **PlayCover ExStorage** and **PrivilegedHelper** targets and assign the same Development Team.
4. Build and run the **PlayCover ExStorage** scheme.
5. Approve the helper under **System Settings → General → Login Items** when requested.

The main App and Helper verify their expected Bundle IDs and matching Team ID. The Helper uses `SMAppService` and exposes constrained APFS and filesystem operations; it does not invoke `sudo`.

## Updates and distribution

Version 1.2.0 is the first Sparkle-enabled release. It contains the update feed URL and public EdDSA key required to verify future update packages. The private signing key stays outside the repository in the release maintainer's macOS Keychain.

For public distribution, archive with a Developer ID Application certificate, enable Hardened Runtime, notarize the result with Apple, and distribute the signed `.dmg` or `.zip`. Build products and signing credentials must not be committed.

## License

No license has been selected yet. Until a license file is added, normal copyright restrictions apply.
