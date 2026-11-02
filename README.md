# GrindIsland

A dynamic island for the MacBook notch (macOS 14+, Apple silicon): synced Apple Music lyrics, your local AI coding
agents (Claude Code) as cat cards with approve / deny right on the island, and Mac notices (volume, brightness,
charging, AirPods), plus pages for a focus timer, calendar and reminders, a file shelf, screenshots, screen recording
and system stats. Every feature can be turned off in Settings.

## Install

1. Download `GrindIsland-<version>.zip` from [Releases](https://github.com/liaw-boy/GrindIsland/releases) and unzip it.
2. Move `GrindIsland.app` to Applications.
3. The app is not notarized by Apple: the first time, right-click it › **Open** › **Open**.

Updates are installed from inside the app (Settings › About › Check for updates); every update is verified with an
EdDSA signature before it is installed.

## Build

```sh
swift test                 # unit tests
scripts/build-app.sh       # builds GrindIsland.app
```

## Privacy

Nothing leaves your Mac except lyric lookups (song title and artist, to NetEase Cloud Music or LRCLIB) and the daily
update check (GitHub). Settings › Privacy lists what is stored locally and clears it.

## License

MIT
