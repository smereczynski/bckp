# Source Guide (Beginner Friendly)

This document explains how the code is organized, what each file does, and how pieces fit together.

## High-level design
- Swift Package with three products/targets:
  - `BackupCore` (library): all backup logic + Azure client + config types.
  - `bckp` (executable): CLI built with ArgumentParser (local + Azure subcommands).
  - `bckp-app` (executable): SwiftUI GUI that wraps BackupCore.
- Tests live under `Tests/` for core and optional Azure integration.
  - Additional macOS-only CLI integration test verifies external-drive listing JSON when enabled via `BCKP_RUN_CLI_TESTS=1`.

## Folder structure
```
/ (repo root)
├─ Package.swift              # Swift Package manifest (dependencies, targets)
├─ README.md                  # Build/run/test instructions
├─ SOURCE-README.md           # This document
├─ Sources/
│  ├─ BackupCore/             # Library source
│  │  ├─ BackupManager.swift  # Main backup engine (local + Azure helpers)
│  │  ├─ Models.swift         # Data models: Snapshot, RepoConfig, options, etc.
│  │  ├─ Utilities.swift      # Errors, glob matching, JSON helpers, formatting
│  │  │                       # + macOS disk identity helpers (external volumes & UUIDs)
│  │  ├─ AzureBlob.swift      # Minimal Azure Blob client + BackupManager extension
│  │  ├─ Config.swift         # AppConfig + AppConfigIO (INI-like) with [azure] sas
│  │  └─ CloudProvider.swift  # Protocol for future cloud backends
│  ├─ bckp-cli/
│  │  └─ main.swift           # CLI entry point, local + Azure subcommands
│  └─ bckp-app/
│     ├─ App.swift            # SwiftUI app entry
│     ├─ ContentView.swift    # GUI (repo, sources, config, cloud actions)
│     └─ RepositoriesPanel.swift # GUI: dedicated panel to view repositories.json (filter, sort, live refresh)
└─ Tests/
   └─ BackupCoreTests/
  ├─ BackupCoreTests.swift       # End-to-end local init/backup/restore + features
  └─ AzureIntegrationTests.swift # Optional Azure SAS-based integration test
```

## File-by-file overview

### Package.swift
- Defines the package name `bckp`, supported platform (macOS 13+), and two targets.
- Declares a dependency on `swift-argument-parser` so we can build a nice CLI.

### BackupCore/Models.swift
// … models for snapshots/config/options

### BackupCore/RepositoriesConfig.swift
- Persists repository usage: lastUsedAt per repo, lastBackupAt per source.
- Models: `RepositoriesConfig` { repositories: [String: RepositoryInfo] }, `RepositoryInfo` { lastUsedAt, sources }, `RepoSourceInfo` { path, lastBackupAt }.
- Store: `RepositoriesConfigStore.shared` reads/writes `~/Library/Application Support/bckp/repositories.json` with ISO8601 dates.
- Keys normalize repo identities:
  - Local: standardized absolute path; on macOS, if the repo is on an external/removable volume and a stable volume UUID is available, the key is prefixed `ext://volumeUUID=<UUID>` to make it robust across re-mounts. Fallback is the standardized path.
  - Azure: strip SAS query/fragment from the container URL.
- Called from CLI on init/backup/restore/list/prune (local and Azure) to update last-used and per-source last-backup.
- Tests live in `Tests/BackupCoreTests/RepositoriesConfigStoreTests.swift`.
### BackupCore/AzureBlob.swift

### bckp-cli/main.swift
- ArgumentParser-based CLI with local and Azure subcommands.
- Local: `init-repo`, `backup`, `restore`, `list`, `prune`.
- Azure: `init-azure`, `backup-azure`, `list-azure`, `restore-azure`, `prune-azure`.
- Repositories inspector: `repos` subcommand prints tab-separated rows or `--json`.
- Size columns are in raw bytes (no unit suffix) for easy scripting.

### BackupCore/Config.swift
- `AppConfig` and `AppConfigIO` load/save INI-like config.
- Sections: [repo], [backup] (include/exclude/concurrency), [azure] (sas).

### BackupCore/CloudProvider.swift
- `CloudProvider` protocol + AzureBlobProvider wrapper for future backends.

### BackupCore/BackupManager.swift
- The main engine used by the CLI and tests.
- Public methods:
  - `initRepo(at:)` creates the repo folder and a `config.json` file.
  - `backup(sources:to:)` copies files from source folders into the repo under `snapshots/<ID>/data/...` and writes `manifest.json`.
  - `restore(snapshotId:from:to:)` copies snapshot files into a destination folder.
  - `listSnapshots(in:)` reads each `manifest.json` and returns a summary list.
- Uses `FileManager` to walk directories and copy files.
- Preserves symlinks by re-creating them.
- Skips hidden files when backing up (you can change this behavior in code).

### bckp-app (SwiftUI)
- GUI wrapping BackupCore.
- Sidebar: repo chooser/init, sources, configuration editor (include/exclude, concurrency, SAS), Cloud actions.
- Repositories panel: searchable/sortable view of repositories.json with live auto-refresh, “Open JSON”, and “Copy key”.
- External-drive picker (macOS): lists external/removable volumes with UUIDs and mount paths, lets users enter a subpath, updates the repo path, and shows the volume UUID and derived repositories.json key with a copy action.

### bckp-app (SwiftUI)
- GUI wrapping BackupCore.
- Sidebar: repo chooser/init, sources, configuration editor (include/exclude, concurrency, SAS), Cloud actions.
- Cloud: Init/List/Backup/Restore wired to SAS from config.

### Tests
- `BackupCoreTests.swift`: local E2E including include/exclude, symlinks, pruning, concurrency.
- `AzureIntegrationTests.swift`: loads SAS from `~/.config/bckp/config` and runs init/upload/list/restore if present; otherwise skips with a clear message.
- `ExternalDiskTests.swift`: unit tests for macOS disk identity and key normalization; skips cleanly if no external drives are present.
- `CLIDrivesIntegrationTests.swift`: optional macOS-only integration test; enabled by `BCKP_RUN_CLI_TESTS=1`. Runs the built `bckp` binary with `drives --json`, asserts the selected volume UUID is present, and times out after 20s with diagnostics to avoid hangs.

## How pieces relate
- The CLI depends on `BackupCore` and just forwards user input to `BackupManager`.
- `BackupManager` uses models and utilities to do the work and to store/load JSON.
- Tests call `BackupManager` functions directly (no CLI needed) to verify behavior.

## Data layout on disk
```
<repo>/
  config.json
  snapshots/
    <SNAPSHOT_ID>/
      manifest.json
      data/
        <source-basename>/ ... copied files and folders ...
```

## Tips for learners
## External disk identification (macOS)
- Implemented in `Utilities.swift` behind `#if os(macOS)`.
- Uses URL resource values to obtain the volume URL and volume UUID when available; considers `/Volumes/...` and removable flags as external.
- Public helpers:
  - `identifyDisk(forPath:) -> DiskIdentity?` returns volumeUUID, mountPath, and `isExternal`.
  - `pathIsOnExternalVolume(_:) -> Bool` convenience check.
- `RepositoriesConfigStore.keyForLocal(_:)` consults `identifyDisk` and embeds `volumeUUID` in the key for external volumes: `ext://volumeUUID=<UUID><standardizedPath>`.
- Impact: keys for repos on external drives remain stable even if the volume’s displayed name changes or mount path varies. If UUID is unavailable, behavior falls back to path-only keys.
- CLI helpers: `bckp drives` lists external/removable volumes (UUID, mount path, device); `bckp init-repo --external-uuid <UUID> [--external-subpath ...]` initializes directly on a chosen volume.
- Start by reading `bckp-cli/main.swift` to see commands and options.
- Then open `BackupManager.swift` (and `AzureBlob.swift`) to follow core + cloud logic.
- Check `Models.swift`, `Utilities.swift`, and `Config.swift` to understand the data and helpers.
- Explore the GUI in `Sources/bckp-app/ContentView.swift` to see how the app ties together.
- Run `swift run bckp --help` and `swift run bckp-app` to try it.
