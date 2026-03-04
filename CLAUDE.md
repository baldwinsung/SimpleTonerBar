# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SimpleTonerBar is a macOS menu bar utility that monitors printer toner/supply levels. It displays toner percentages (e.g., "B78 C64 M59 Y61") in the system menu bar with configurable printer IP and refresh interval.

## Build & Run

- **Requires:** Xcode 15+, macOS 13+
- **Build:** Open `Package.swift` in Xcode and run the `SimpleTonerBar` target
- **CLI build:** `swift build`
- **CLI run:** `swift run SimpleTonerBar`

Swift Package Manager executable with no external dependencies (uses Foundation, AppKit, SwiftUI).

## Architecture

The app combines AppKit (menu bar via `NSStatusItem`) with SwiftUI (settings window):

- **SimpleTonerBarApp.swift** — `@main` entry point, bridges to AppDelegate and hosts SwiftUI Settings scene
- **AppDelegate.swift** — Manages the `NSStatusItem`, refresh timer, and menu bar display. Orchestrates `TonerMonitor` and updates the menu bar title/tooltip/context menu
- **TonerMonitor.swift** — Defines `TonerSupply` and `PrinterStatus` models. `fetch()` retrieves printer status (currently returns mock data; intended for SNMP integration)
- **Preferences.swift** — Singleton (`Preferences.shared`) with `@Published` properties (`printerIP`, `refreshInterval`) persisted to `UserDefaults`
- **SettingsView.swift** — SwiftUI form bound to `Preferences.shared` for configuring IP and refresh interval (15–600s)

All source files live in `Sources/SimpleTonerBar/`. There are no tests.

## Key Details

- `TonerSupply.shortCode` maps supply names to single-letter codes (B/C/M/Y) for the compact menu bar display
- The refresh timer in AppDelegate uses `Preferences.shared.refreshInterval`
- `TonerMonitor.fetch()` uses a callback-based async pattern `((PrinterStatus) -> Void)`
