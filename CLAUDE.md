# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

GrindIsland is a macOS 14+ "accessory" (`LSUIElement`, status-bar item only) Swift/SwiftUI app that draws a "dynamic island" over the MacBook notch. It shows synced Apple Music lyrics, and local AI coding agents (Claude Code, Antigravity) as cat cards. UI strings are Traditional Chinese.

There is an XCTest suite (`swift test`, in `Tests/GrindIslandTests`) for the pure logic; no linter or README. Not a git repo. Reference app for sizes and behavior: see the auto-memory note on 靈動歌詞 (sizes and motion were measured from it; do not copy its code or assets).

## Commands

```sh
swift build                      # debug build -> .build/debug/GrindIsland
swift build -c release
swift test                       # run after every code change; must pass before reporting done
```

Tests cover pure logic only (parseLRC, LyricSplitter, LyricCache with a temp directory, CatLook.assign, IslandPresence.shouldBeActive, ChineseConverter). Use made-up data and temp directories; never the real `~/Library/Application Support/GrindIsland`. UI, animation and click behavior still need a real run.

`GrindIsland.app/` is built by `scripts/build-app.sh` (release binary + `Support/Info.plist` + Sparkle.framework), Apple silicon only, signed with the self-signed "GrindIsland Release Signing" identity in the login keychain (falls back to ad-hoc without it); a stable identity keeps macOS permissions across updates. It is not in git. No notification sounds (the user does not want any). To update it: back up the old bundle, run `scripts/build-app.sh`, then `open` it. Edit `Support/Info.plist`, never the bundle's copy. Keep `NSAppleEventsUsageDescription` (Music and cmux via AppleScript) and the calendar/reminders usage strings.

**Updates (Sparkle):** the app checks `SUFeedURL` (appcast on the GitHub Releases of `liaw-boy/GrindIsland`) daily; downloads must match `SUPublicEDKey`. The EdDSA private key lives only in the login keychain (account `GrindIsland`); never export it into the repo. `scripts/release.sh <version> <build>` prepares `dist/` (zip + signed appcast) and prints the `gh release create` command; tagging and publishing need the user's go-ahead.

**Two preference domains:** the `.app` uses `com.boywei.GrindIsland`; the bare debug/release executable uses `GrindIsland`. Tests via `.build/debug/GrindIsland` never touch the user's real settings; do not edit the `.app` domain.

Launch/env switches for verification (screenshots, recordings): `--expanded` (start expanded, auto-collapse off), `--tab=N` (0 lyrics, else Agents), `--open-at-launch` (expand with the pointer away), `--simulate-idle` (do not start the music tracker), `--simulate-no-notch`, `--draw-notch` (screenshots do not capture the hardware notch: draws a stand-in so you can judge how the island joins it), `--settings`, `--test-gear`, `--test-menu` (open/close our own status menu), `--test-idle-at=N` / `--test-active-at=N` (pretend playback stopped / resumed), `--test-panel-map` (log session → cmux panel, read-only), `--test-jump=<folder>` (jump to that session); `GRINDISLAND_SESSIONS_DIR` replaces `~/.claude/sessions` (use an empty dir for "no agents").

## Architecture

Entry: `App/main.swift` → `AppDelegate` (status-bar menu, starts `MusicTracker`, `AgentMonitor`, purges the lyric cache, shows `NotchPanel`).

- **Notch/**
  - `NotchPanel`: one borderless non-activating `NSPanel`, sized to the expanded island plus a 48×24 overshoot margin, centered at the top of the target screen. `hitTest` returns nil outside what is drawn, so clicks pass through to the menu bar; it reads `NotchGeometry` sizes, so any island size change must be mirrored there. Also: global/local mouse monitors (pointer proximity, outside-click collapse), auto-collapse watcher (pointer left → 0.35s; never entered → 2.5s), fullscreen-app hiding, screen-change handling.
  - Island style (setting 外觀): `notch` (wings beside the notch, lyric hanging below), `capsule` (floating), `attached` (fused: the notch layout in a fully rounded capsule: the island starts at the screen's top edge (its top corners are rounded too) and wraps the notch, collapsed 330 wide with 55pt wings, expanded 584×178 with 12pt lower corners = `NotchGeometry.notchCorner`; idle it hides inside the notch). `auto` = attached with a usable notch, capsule otherwise. Layout flags: `notchStyle`, `attached`, and `integrated` (= either; use it for wings / top-bar layout); never branch on `hasNotch` for layout. Expanded content is 540pt wide in every style (`contentEdge`, `topBarHeight`); keep margins symmetric.
  - **Several displays:** "顯示在 › 所有螢幕" (`AppSettings.allScreens`) gives every display its own `NotchPanel` + `NotchGeometry` (`NotchPanel.syncExtraPanels()`); views get their island's geometry from `@EnvironmentObject`, never `NotchGeometry.shared` (that is only the main island). Content (music, agents, notices) is shared; expanding is per display.
  - `NotchGeometry`: sizes, notch measurement (`safeAreaInsets` / `auxiliaryTop*Area`; virtual notch on displays without one), `pointerNear`, idle silhouette constants.
  - `IslandPresence`: decides whether the island exists at all (music *playing* — paused counts as not playing, 4s grace — or an agent needing attention). Features add their source here.
  - `NotchRootView`: root view. Animations (`.animation` for expand and `pointerNear`) live on the **root**, outside the centering frame, so size and position animate together; putting them inside makes one edge jump first. The tap/click area is the island as drawn, not the fixed-size content.
  - `CommonModeTimer`: use `Timer.commonModeTimer` for every timer; default-mode timers stop while a menu is open.
- **Music/**
  - `MusicTracker`: polls Music via `NSAppleScript` every 0.5s plus `com.apple.Music.playerInfo` notifications. Read position only through `livePosition()`.
  - `LyricService`: sources NetEase (POST search; the old GET search is rate limited) → LRCLIB exact → LRCLIB fuzzy search by duration; chain order depends on CJK. Stores raw LRC (`LyricPayload`), parses with `parseLRC` (filters credit lines). `currentLyrics` (as sung, expanded view) and `compactLyrics` (long lines split by `LyricSplitter`) are separate.
  - `LyricCache`: `~/Library/Application Support/GrindIsland/lyrics`, file name = SHA256 of the track key, file mtime = last played, 14-day retention, 800 max. No per-song disk writes while playing.
  - `FlowingKaraokeView` (sweep + marquee), `NowPlayingView` (expanded page), `ChineseConverter` (Simplified→Taiwan Traditional for translations).
- **PixelOffice/**: `AgentMonitor` (scans `~/.claude/sessions` and `agy` processes; `focusHost` jumps to the session's own screen), `AgentListView` (cards) + `CatAvatar` (vector cat, 3 poses) + `CatLook` (16 looks: coat, pattern, eyes, ears, accessory; `CatLook.assign` gives each session a look by a stable hash of its project folder, independent of the AI kind). `PixelOfficeView.swift` is legacy; only `PixelMascot` is still used by the collapsed alert.
  - **Jump to a cmux tab:** the process env has `CMUX_PANEL_ID`, equal to the `id` of the terminal in cmux's AppleScript dictionary; `focus term` selects it. Do not use `cmux focus-panel` / the socket from this app: cmux only accepts processes started inside it (`socketControlMode=cmuxOnly`, the user's security setting). Needs a one-time macOS Automation approval for GrindIsland → cmux.
- **Settings/**: `AppSettings` (UserDefaults, 9 user-facing options) and `SettingsView`. Keep it small; behavior that nobody needs to choose is fixed, not a setting.

## Pitfalls learned the hard way

- SwiftUI does not hit-test transparent areas: give every custom button `.contentShape(Rectangle())`.
- Measure with a real recording or screenshots, not reasoning; and make sure the island is not being clicked by the user during a test (it expands/changes tabs and ruins the data).
- If the "reference app" is running, its island overlaps ours at the same place and corrupts measurements.
- Screenshots do not capture the physical notch as black; our idle silhouette shows in screenshots but is hidden behind the real notch.

## Key design decisions (ClaudeVault/GrindIsland/decisions.md)

- Never animate the NSWindow frame; the window is fixed-size and SwiftUI does the motion.
- Agent data must be real (local sessions/processes); no simulated agents.

Project memory (progress / decisions / log) lives in `../ClaudeVault/GrindIsland/` (outside this repo).
