# bckp

A simple, native macOS backup tool (CLI + SwiftUI app) written in Swift. Creates snapshot folders you can browse and restore from.

- Language: Swift 5.9+
- Target: macOS 13+
- Arch: Apple Silicon (arm64) and Intel (universal by default when using `swift build`)

## Features
- Initialize a repository under `~/Backups/bckp` (configurable)
- Create snapshot(s) from one or more source directories
- Restore a snapshot to any destination
- List snapshots with counts and sizes
- Include/Exclude glob patterns (relative to each source)
- Prune snapshots by keeping the last N and/or last D days
- Concurrency control and progress reporting during backup
- .bckpignore support per source folder (with !reinclude lines)
- Cloud repository (optional): Azure Blob Storage via SAS URL
- Global history: repositories.json tracks recently used repositories (local/Azure), configured sources, and per-source last backup time

Repository layout:
```
<repo>/
  config.json
  snapshots/
    <SNAPSHOT_ID>/
      manifest.json
      data/
        <source-basename>/...
```

## Quick start

### Prerequisites
- macOS 13+ (works on macOS 15 Apple Silicon)
- Xcode (full) recommended so `swift test` has XCTest SDKs
  - Set active developer dir if needed: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`

### Build and test
```bash
swift build              # compile
swift run bckp --help    # show commands
swift test               # run tests (requires full Xcode SDKs)
```

### Run the GUI (SwiftUI app)
> [!WARNING]  
> GUI is in heavy development and should NOT be considered as usable yet!

```bash
swift run bckp-app
```
The app lets you:
- Choose and initialize a local repository
- Add sources, run backups with progress, and view logs
- Edit configuration (include/exclude, concurrency, Azure SAS)
- Run Cloud actions (Init, List, Cloud Backup, Cloud Restore)

### Configuration
The CLI and GUI read defaults from a simple config file. Flags always override config.

Locations (first found wins):
- `./bckp.config` next to the default repo (created by the app when saving), or
- `~/.config/bckp/config`

Format (INI-like):
```
[repo]
path = /Users/you/Backups/bckp

[backup]
include = **/*
exclude = **/.git/**, **/node_modules/**
concurrency = 8

[azure]
sas = https://acct.blob.core.windows.net/container?sv=...&sig=...
```
A `config.sample` is provided in the repo. The real config is ignored by git.

### Repositories history (global)
The tool maintains a global JSON file to help surfaces like the GUI list “recent repositories” and show when each source was last backed up.

- Location (macOS): `~/Library/Application Support/bckp/repositories.json`
- Tracks, per repository (local path or Azure container URL):
  - lastUsedAt (when the repo was last initialized/restored/backed up)
  - sources[] with `path` and `lastBackupAt` (per-source timestamp)

When it updates:
- Local: `init-repo` and `restore` update `lastUsedAt`; `backup` also ensures sources are present and sets `lastBackupAt` for each backed-up source.
- Azure: `init-azure` and `restore-azure` update `lastUsedAt`; `backup-azure` updates per-source `lastBackupAt`.

Sample shape:
```
{
  "version": 1,
  "repositories": [
    {
      "key": "/Users/you/Backups/bckp",
      "type": "local",
      "lastUsedAt": "2025-08-16T12:34:56Z",
      "sources": [
        { "path": "/Users/you/Documents", "lastBackupAt": "2025-08-16T12:34:12Z" },
        { "path": "/Users/you/Pictures", "lastBackupAt": "2025-08-15T09:01:02Z" }
      ]
    },
    {
      "key": "https://acct.blob.core.windows.net/container",
      "type": "azure",
      "lastUsedAt": "2025-08-15T07:00:00Z",
      "sources": []
    }
  ]
}
```

### Initialize a repo
```bash
swift run bckp init-repo --repo ~/Backups/bckp
```

### Create a backup
```bash
swift run bckp backup --source ~/Documents --source ~/Pictures --repo ~/Backups/bckp \
  --include "**/*.jpg" --include "**/*.png" \
  --exclude "**/.git/**" --exclude "**/*.tmp"
```

Enable progress and tune concurrency (optional):
```bash
swift run bckp backup --source ~/Documents --repo ~/Backups/bckp --progress --concurrency 8
```

Per-source ignores
Create a `.bckpignore` file in any source folder to override CLI include/exclude for that source. Example:
```
# exclude node_modules everywhere under this source
**/node_modules/**

# exclude logs
**/*.log

# re-include a specific file
!keep/important.log

# optional directive style also works
include: src/**
exclude: **/.DS_Store
```

### List snapshots
```bash
swift run bckp list --repo ~/Backups/bckp
```

### Restore a snapshot
```bash
swift run bckp restore <SNAPSHOT_ID> --repo ~/Backups/bckp --destination ~/RestoreHere
```

### Prune old snapshots
```bash
# keep last 5 snapshots
swift run bckp prune --repo ~/Backups/bckp --keep-last 5

# or keep snapshots from the last 30 days
swift run bckp prune --repo ~/Backups/bckp --keep-days 30
```

## Release (build a distributable binary)

### Debug (fast, default)
```bash
swift build
ls -l .build/debug/bckp
```

### Release (optimized)
```bash
swift build -c release
ls -l .build/release/bckp
```

You can copy the built binary to a directory in your PATH (e.g., `~/bin`) or wrap it in a small `.pkg`/`.dmg` later.

### Azure (SAS) Cloud Repo
You can pass `--sas` explicitly, or omit it to use the value from your config.

- Initialize the container as a repo (writes config.json at container root)
```bash
swift run bckp init-azure --sas "https://<acct>.blob.core.windows.net/<container>?sv=...&sig=..."
# or use config: set [azure] sas in your config and run
swift run bckp init-azure
```

- Backup to Azure
```bash
swift run bckp backup-azure --source ~/Documents --source ~/Pictures \
  --include "**/*" --exclude "**/.git/**" --concurrency 8 --progress
# optionally add --sas to override config
```

- List Azure snapshots
```bash
swift run bckp list-azure   # uses config SAS, or add --sas
```

- Restore from Azure
```bash
swift run bckp restore-azure <SNAPSHOT_ID> --destination /tmp/restore --concurrency 8
# optionally add --sas to override config
```

- Prune Azure snapshots
```bash
swift run bckp prune-azure --keep-last 10  # or --keep-days D
# optionally add --sas to override config
```

Azure SAS: use a container-level SAS. For backup: write + list (and create). For restore/list: read (and list). Keep SAS secrets safe.

## Notes
- Current version copies files; deduplication/hard-linking can be added later.
- Symlinks are preserved when possible.
- Hidden files are skipped during backup; adjust in code if needed.
- Some folders require Full Disk Access. Grant your Terminal app Full Disk Access in System Settings > Privacy & Security.
- Tests may fail with `no such module XCTest` if only Command Line Tools are installed. Install full Xcode and run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

### Tests (Azure integration)
- `swift test` runs local tests and an optional Azure integration test.
- If `~/.config/bckp/config` contains a valid `[azure] sas`, the Azure test performs init, upload, list, and restore against your container.
- If SAS is missing/empty, the Azure test is skipped with a clear message.
