# Source Guide (Beginner Friendly)

This document explains how the code is organized, what each file does, and how pieces fit together.

## High-level design
- Swift Package with three products/targets:
  - `BackupCore` (library): all backup logic + Azure client + config types.
  - `bckp` (executable): CLI built with ArgumentParser (local + Azure subcommands).
  - `bckp-app` (executable): SwiftUI GUI that wraps BackupCore.
- Tests live under `Tests/` for core and optional Azure integration.

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
│  │  ├─ AzureBlob.swift      # Minimal Azure Blob client + BackupManager extension
│  │  ├─ Config.swift         # AppConfig + AppConfigIO (INI-like) with [azure] sas
│  │  ├─ RepositoriesConfig.swift # Global repositories.json (recent repos, per-source last backup)
│  │  └─ CloudProvider.swift  # Protocol for future cloud backends
│  ├─ bckp-cli/
│  │  └─ main.swift           # CLI entry point, local + Azure subcommands
│  └─ bckp-app/
│     ├─ App.swift            # SwiftUI app entry
│     └─ ContentView.swift    # GUI (repo, sources, config, cloud actions)
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
- Contains the small data types we save as JSON, like `Snapshot` and `RepoConfig`.
- `Codable` makes it easy to serialize/deserialize to/from JSON.
- `Equatable` allows comparing values in tests.

### BackupCore/Utilities.swift
- Defines `BackupError` so we can report readable errors.
- Helpers: `URL.isDirectory`, byte count formatting, JSON helpers, glob matching, `.bckpignore` parsing.

### BackupCore/AzureBlob.swift
- Minimal SAS-based client (URLSession) supporting Put Block/List, Get, Delete.
- `BackupManager` extension adds Azure-specific init/backup/list/restore/prune.

### BackupCore/Config.swift
- `AppConfig` and `AppConfigIO` load/save INI-like config.
- Sections: [repo], [backup] (include/exclude/concurrency), [azure] (sas).

### BackupCore/CloudProvider.swift
- `CloudProvider` protocol + AzureBlobProvider wrapper for future backends.

### BackupCore/RepositoriesConfig.swift
- Global lightweight persistence for repository usage history.
- File location (macOS): `~/Library/Application Support/bckp/repositories.json`.
- Keeps an array of repositories with:
  - `key` (local repo path or Azure container URL without query)
  - `type` (local|azure)
  - `lastUsedAt` (Date)
  - `sources[]` of `{ path, lastBackupAt }`
- Used by CLI to:
  - Update last-used on init/restore (local and Azure)
  - Record per-source last backup on backup/backup-azure
  - Add newly configured sources on local backup

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

### bckp-cli/main.swift
- ArgumentParser-based CLI with local and Azure subcommands.
- Local: `init-repo`, `backup`, `restore`, `list`, `prune`.
- Azure: `init-azure`, `backup-azure`, `list-azure`, `restore-azure`, `prune-azure`.
- Many flags are optional when defaults exist in config (e.g., SAS).

### bckp-app (SwiftUI)
- GUI wrapping BackupCore.
- Sidebar: repo chooser/init, sources, configuration editor (include/exclude, concurrency, SAS), Cloud actions.
- Cloud: Init/List/Backup/Restore wired to SAS from config.

### Tests
- `BackupCoreTests.swift`: local E2E including include/exclude, symlinks, pruning, concurrency.
- `AzureIntegrationTests.swift`: loads SAS from `~/.config/bckp/config` and runs init/upload/list/restore if present; otherwise skips with a clear message.

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
- Start by reading `bckp-cli/main.swift` to see commands and options.
- Then open `BackupManager.swift` (and `AzureBlob.swift`) to follow core + cloud logic.
- Check `Models.swift`, `Utilities.swift`, and `Config.swift` to understand the data and helpers.
- Explore the GUI in `Sources/bckp-app/ContentView.swift` to see how the app ties together.
- Run `swift run bckp --help` and `swift run bckp-app` to try it.
