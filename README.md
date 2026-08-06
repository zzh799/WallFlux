# WallFlux

> Dynamic wallpapers for every display, independently.

WallFlux is a macOS menu bar app (macOS 14+ / Sonoma or later) that brings dynamic wallpapers to each of your monitors. Displays that go idle automatically start looping dynamic wallpapers to protect the screen, while active displays stay in an almost imperceptible "micro-step" mode to prevent burn-in. It never interrupts your workflow.

English | [简体中文](README_zh.md)

## Features

- **Per-display configuration** - each monitor gets its own wallpaper, remembered by hardware ID across unplug / replug; or switch to "All displays" to apply one wallpaper everywhere (newly connected displays inherit it automatically)
- **Smart idle detection** - global mouse + keyboard monitoring; a display without input for N minutes (default 1, configurable) automatically starts playing its dynamic wallpaper
- **Micro-step burn-in prevention** - on active displays the wallpaper is paused and advances Z frames every Y seconds, visually imperceptible but effective against OLED burn-in
- **Three wallpaper sources** - macOS system dynamic wallpapers, local video files (mp4 / mov / webm), local image sequences (a folder of images, sorted by filename)
- **Graceful exit** - configurable transition when you come back: instant stop or fade-out (0.5 s default); a mouse passing briefly over a playing display never interrupts the wallpaper - it goes back to top-layer playback as soon as the mouse leaves or stops
- **Screen-saver-level playback** - while playing, the wallpaper window sits at the very top (screen saver layer); the moment the mouse enters, it drops to the desktop layer and yields the screen, never blocking your work
- **Hot-plug aware** - connecting or disconnecting a display is detected automatically and its configuration is restored
- **Smart pause** - with any enabled condition hit (system sleep, display sleep, Low Power Mode, battery power, low battery below a threshold with +5% hysteresis, or a fullscreen / maximized app window on that display), wallpaper playback and micro-stepping pause entirely; manual pause and smart pause are independent and OR-ed together
- **Launch at login** - optional and off by default; a first-launch prompt asks whether to start WallFlux at login, and the toggle in the menu bar panel and Settings stays in sync with the system

## Requirements

- macOS 14.0+ (Sonoma or later)
- Apple Silicon or Intel

## Installation

### Homebrew

```bash
brew install --cask zzh799/wallflux/wallflux
```

The cask is auto-synced with each release.

### Manual (DMG)

Download the latest DMG from the [Releases page](https://github.com/zzh799/WallFlux/releases), open it, and drag WallFlux.app into your Applications folder.

### Build from source

Requires Xcode 15+.

```bash
xcodebuild -project WallFlux.xcodeproj -scheme WallFlux -configuration Release -derivedDataPath build build
open ./build/Build/Products/Release/WallFlux.app
```

## Getting started

1. Launch WallFlux - it lives in the menu bar (⌘ icon).
2. Grant the **Accessibility** permission when prompted (System Settings → Privacy & Security → Accessibility). This is required to monitor global input events so WallFlux knows which display is idle.
3. Open the menu bar panel → Settings, choose "All displays" for a single wallpaper everywhere, or switch to "Per display" to pick a wallpaper for each monitor (system wallpaper, video, or image sequence).
4. Walk away. Idle displays start playing automatically; when you return, they fade back to the desktop.

## How it works

Each display runs a small state machine:

```
active (micro-step) ── idle timeout ──▶ idle (looping wallpaper, on top)
      ▲                                     │
      │                        mouse enters: wallpaper yields, grace period
      │                                     │
      │          ┌───── mouse leaves / stops → back to top-layer playback
      │          │
      │          └───── moving for the full grace period → exit
      └──── exit ── exiting (fade out) ┘
```

- **Idle detection** uses a global `CGEventTap`; the display under the mouse is always considered active, and keyboard input activates the display of the focused window.
- **Brief-entry grace** (5 s default, adjustable in Settings): when the mouse enters a playing display the wallpaper immediately drops to the desktop layer and pauses, yielding the screen; if the mouse leaves or stops within the grace period, playback resumes on top. Clicks, scrolling and keyboard input exit immediately.
- **Micro-step mode** pauses the wallpaper at its last frame and steps forward Z frames every Y seconds, so the panel never stays perfectly still (burn-in prevention) while looking static.
- The wallpaper window runs at the screen saver level (`kCGScreenSaverWindowLevel`) while playing and drops to the desktop icon level (`kCGDesktopIconWindowLevel`) when paused, joins all Spaces, and ignores mouse events.

See [docs/技术文档（Tech Design）.md](docs/技术文档（Tech Design）.md) for the full architecture, data flow, and state machine details.

## Documentation

- [Product Requirements (PRD)](docs/需求文档（PRD）.md) - feature & non-functional requirements (FR-01 ~ FR-13, NFR-01 ~ NFR-05)
- [Technical Design](docs/技术文档（Tech Design）.md) - architecture, modules, state machine, data flow
- [UI Design Spec](docs/设计规范.md) - design tokens and component guidelines

## Project structure

```
WallFlux/
├── App/       # main.swift entry, AppDelegate, MenuBarController
├── Core/      # CoreManager, ScreenManager, IdleDetector, ConfigStore, AssetStore, Models
├── Engine/    # WallpaperEngine, WallpaperWindow, ImageSequenceRenderer
└── UI/        # SwiftUI menu bar panel & settings views
```

## Troubleshooting

- **Idle detection stops working** - the system may terminate a `CGEventTap` (a known macOS behavior). WallFlux auto-reconnects; if it keeps failing, re-grant the Accessibility permission in System Settings.
- **Wallpaper not showing** - make sure the wallpaper window level still works on your macOS version; on future macOS releases the desktop window level may change behavior and a fallback level is used.
