# Development Guide

This document explains how we develop, review, and release changes in this repository.

## 1. Branching model

We follow a short‑lived branch workflow with mandatory Pull Requests.

- Feature work: `feature/<feature-id>` (e.g., `feature/logging`, `feature/repositories-usage-tracking`).
- Bug fixes: `bugfix/<bugfix-id>` (e.g., `bugfix/azure-timeout`, `bugfix/repo-path-normalization`).
- Branch names should be lowercase, kebab‑cased after the prefix, and describe the intent succinctly.
- Keep branches small, focused, and regularly rebased on `main` to reduce merge conflicts.

## 2. Pull Requests (PRs)

- All changes flow through PRs. Open a PR from your `feature/*` or `bugfix/*` branch into `main`.
- Keep PRs small and self‑contained with a clear title and description:
  - What changed, why it changed (problem/solution), and any trade‑offs.
  - Testing notes: unit tests added/updated, manual validation steps.
  - Screenshots or terminal snippets when UI/UX or CLI output changes.
- CI must be green (build + tests) before review/merge.
- Prefer squash merge to keep a clean history. The squash commit message should summarize the change.

## 3. `main` protection

- The `main` branch is protected: no direct commits.
- `main` can be updated only via Pull Requests that pass CI and review.

## 4. Versioning and Releases

We use SemVer with Git tags as the single source of truth:

- Released versions: `vX.Y.Z` (e.g., `v0.2.0`).
- Pre‑releases: `vX.Y.Z-rc.N` (e.g., `v0.2.0-rc.1`). These create prereleases on GitHub.

The project embeds a version string at build time and automates releases via GitHub Actions.

### 4.1 How versioning is wired

- `Sources/BackupCore/Version.swift` defines `BckpVersion.string`.
  - Local/dev builds fall back to the environment variable `BCKP_VERSION` or `"0.0.0+dev"`.
  - The Release workflow overwrites `Version.swift` with the tag value before building.
- The CLI reads this value to serve `bckp --version`.

### 4.2 Releasing a new version

1) Prepare and merge your changes
- Implement on `feature/*` or `bugfix/*` branch.
- Ensure tests and CI are green.
- Open a PR into `main`, address reviews, and merge (squash recommended).

2) Tag the release
- Decide the next SemVer: bump major/minor/patch.
- Create and push a tag on the `main` commit you want to release:
  - Final releases: `vX.Y.Z`
  - Pre‑releases: `vX.Y.Z-rc.N`

3) What CI does on tag push
- The `release.yml` workflow runs on macOS:
  - Derives `VERSION` from the tag (drops the leading `v`).
  - Writes `Sources/BackupCore/Version.swift` with that exact string.
  - Builds release binaries via SwiftPM (`bckp`, `bckp-app`).
  - Packages artifacts:
    - `bckp-<version>-macos.zip` (CLI binary inside named `bckp`)
    - `bckp-app-<version>-macos.zip` (GUI binary inside named `bckp-app` for Terminal launch)
    - `bckp-app-<version>-macos.app.zip` (double‑clickable Finder app bundle `bckp-app.app`)
    - `SHA256SUMS` with checksums for integrity.
  - Publishes a GitHub Release:
    - Title/Tag: `v<version>`
    - Marks as a prerelease if the tag contains `-rc`.

4) Verify the release
- Download artifacts, verify checksums from `SHA256SUMS`.
- CLI: unzip `bckp-<version>-macos.zip`, run `./bckp --version` and confirm the tag.
- GUI (Terminal): unzip `bckp-app-<version>-macos.zip`, run `./bckp-app` and confirm the app shows the version.
- GUI (Finder): unzip `bckp-app-<version>-macos.app.zip`, move to Applications, launch. If Gatekeeper warns (unsigned, not notarized yet), right‑click → Open or clear quarantine: `xattr -dr com.apple.quarantine ~/Applications/bckp-app.app`.

### 4.3 Local builds and version override (optional)

- You can inject a custom version for local testing:
  - macOS zsh: `BCKP_VERSION=0.2.0-dev swift build`
- Without override, local builds report `0.0.0+dev`.

### 4.4 Notes and future improvements

- Artifacts include a raw GUI binary and a minimal `.app` bundle. Code signing and notarization are not yet enabled.
- Optional follow‑ups:
  - Universal (arm64 + x86_64) macOS binaries.
  - Code signing and notarization for `.app` and binaries.
  - Homebrew tap for `bckp` CLI.
  - Changelog automation.

## 5. Keychain, encryption, and CI

- The encryption feature generates an RSA‑4096 key and a self‑signed certificate using swift‑certificates and stores them in the login keychain. The key is created with an ACL that trusts `/usr/bin/hdiutil` and `diskimages-helper` to reduce prompts.
- The ACL uses `SecAccessCreate` and `SecTrustedApplicationCreateFromPath`, which are deprecated APIs in the Keychain stack but remain functional. They are currently used to provide a prompt‑free experience for automated backups and tests. We will revisit this if a modern alternative becomes available.
- Tests: `EncryptionInitializerTests` may try to add XCTest as a trusted application (best‑effort with multiple possible paths) to avoid prompts on CI. If your CI environment still prompts, ensure the test runner binary path is allowed in Keychain or skip the test.
- Focused runs: to iterate quickly on encryption, use:
  - `swift test --filter EncryptionInitializerTests`

## 6. Code coverage

- SwiftPM: `swift test --enable-code-coverage` generates profiling data under `.build`.
- Export an lcov + optional HTML report:
  - `scripts/swiftpm-coverage.sh` (writes `.coverage/coverage.lcov`)
  - `scripts/swiftpm-coverage.sh --open` (requires `genhtml` from lcov)
