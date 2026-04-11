# CloudTune

CloudTune is a Tauri 2 desktop player for Tianyi Cloud music, built with a React frontend and a Rust backend.

## Features

- QR-code login for Tianyi Cloud
- Music, video, and download modules
- Remote folder browsing and music library scanning
- Shuffle, previous / next, list loop, and single-track loop
- Download-first playback and stream-cache playback modes
- Local cache size limits and transfer thread tuning
- macOS Media Session metadata from cached track tags and artwork
- Windows x64 / ARM64 and macOS Apple Silicon packaging scripts

## Tianyi Driver Choice

This project follows OpenList's `189CloudPC` flow, not the other Tianyi drivers.

- `189CloudPC`
  Uses `getSessionForPC.action` and matches the desktop QR-login flow.
- `189`
  Older username/password flow with different behavior.
- `189_tv`
  Android TV style flow with different device parameters.

Reference project:

- [OpenListTeam/OpenList](https://github.com/OpenListTeam/OpenList)

## Stack

- Frontend: React 19 + Vite
- Desktop shell: Tauri 2
- Backend: Rust
- Cloud integration: Tianyi Cloud client flow modeled after OpenList `189CloudPC`

## Development

```bash
npm ci
npm run dev
```

## Build

```bash
npm run build
npm run tauri:build:mac:arm64
npm run tauri:build:win:x64
npm run tauri:build:win:arm64
```

`npm run tauri:build:mac:arm64` now builds the `.app` first and then repacks a custom DMG that contains:

- `CloudTune.app`
- an `Applications` shortcut
- `Fix CloudTune.command`, a one-click macOS permission repair helper for ad-hoc signed releases

## Release Workflow

The repository includes a GitHub Actions workflow that:

- builds the Windows x64 installer
- builds the macOS Apple Silicon dmg
- uploads artifacts
- publishes a GitHub Release automatically when a tag is pushed

Trigger a release by pushing a tag such as `v0.1.0`.

You can also use the Actions page to run the workflow manually:

- build any branch, commit, or tag with `workflow_dispatch`
- optionally publish the produced assets to an existing tag by filling `release_tag`

## macOS signing

The workflow now always performs ad-hoc macOS signing so downloaded builds are not emitted as malformed app bundles.

If you want macOS downloads to open without the manual Privacy & Security bypass, add Apple Developer signing and notarization secrets:

- `APPLE_CERTIFICATE`
- `APPLE_CERTIFICATE_PASSWORD`
- `KEYCHAIN_PASSWORD`
- plus either:
  - `APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`
  - or `APPLE_API_ISSUER`, `APPLE_API_KEY`

Tagged releases and manual runs with `publish_release=true` now require valid Apple Developer signing and notarization secrets.
If those secrets are missing, the workflow falls back to ad-hoc signing and still publishes the DMG.
That fallback avoids broken app bundles, and the DMG now includes `Fix CloudTune.command` to strip the quarantine attribute and install the app into `/Applications`. Fully unsigned ad-hoc builds can still require one manual allow in Privacy & Security on newer macOS versions.
