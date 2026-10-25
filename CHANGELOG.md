# Changelog

All notable changes to Sentinel Cam are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
semantic versioning.

## [1.0.0] — 2026-10-25

First public release.

### Added

- Multi-device support: any number of standalone cameras and multi-channel
  NVRs/DVRs, each with its own host, port, credentials, transport, and paths.
- Device → camera model with per-camera name, recorder channel, Main/Sub
  quality, and Fit/Stretch scale.
- Add-camera flow with pasted RTSP URL parsing, brand presets (Dahua/Amcrest,
  Hikvision/HiLook, Reolink, Tapo/VIGI, Axis, Uniview, Foscam, Hanwha/Wisenet,
  Vivotek, generic), manual entry, and a handshake test before saving.
- Main stream by default, with an optional per-camera sub stream.
- Grouped menu bar camera picker and grouped sidebar by device.
- Universal binary (Apple silicon + Intel) build script.
- Settings redesign with device editing, per-camera controls, connection tester,
  and JSON export/import (passwords excluded).
- Snapshot save and copy from the maximized camera (macOS 14.4+).
- Semantic success/warning/error colors and system-accent tinting throughout.
- Self-test covering URL building, presets, URL parsing, IPv6, migration,
  round-tripping, duplicate IDs, and empty devices.

### Changed

- Renamed the app to **Sentinel Cam**.
- Redesigned the main window around a full-height native sidebar, a custom
  in-content header, and flat system surfaces, with a hidden title bar and
  native traffic lights.
- Minimum macOS raised to 14.0.
- Credentials moved to a per-device `secrets.json` file with `0600`
  permissions; the legacy single `password` file is read once and preserved.
- The first-run setup sheet now shares one implementation with the normal
  add/edit flow.

### Migration

- Existing single-recorder `config.json` files are migrated automatically.
  The original is kept as `config.v1.backup.json`; channel names, enabled
  flags, menu camera, grid density, menu bar size, appearance, and the password
  are preserved.

### Removed

- ONVIF support. Sentinel Cam is an RTSP viewer and does not perform discovery.
