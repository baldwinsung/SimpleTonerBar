
# SimpleTonerBar

A lightweight macOS menu bar utility that auto-discovers network printers and displays toner levels, paper tray status, and page counts via SNMP.

> ⚠️ **Disclaimer:** This software is provided "as is", without warranty of any kind. The author(s) are not liable for any damages or issues arising from the use of this software. Use at your own risk. See [LICENSE](LICENSE) for full details.

> 🤖 **AI Disclosure:** This project was created with assistance from [Claude](https://claude.ai) by Anthropic.
## Menu Bar

The menu bar shows a compact, color-coded summary of toner levels with colored circles matching each supply:

`🖨️ ●78 ●64 ●59 ●61`

Hover over the icon for a tooltip with printer IP, page count, and last update time.

## Dropdown Menu

Click the menu bar icon to see:

- **Toner details** — full supply name, percentage, and raw level/capacity (e.g., `Black: 78% (156/200)`) with colored indicators
- **Paper tray status** — tray name, percentage, and level/capacity
- **Page count** — total pages printed
- **Last polled** — relative and absolute timestamp of the last poll

## Features

- **Auto-discovery** — automatically finds printers on your network, no manual IP configuration needed
- **SNMP monitoring** — uses SNMPv2c (RFC 3805 Printer MIB) to read toner levels, paper trays, and page counts
- **Color-coded display** — colored circles for Black, Cyan, Magenta, and Yellow in both the menu bar and dropdown
- **Configurable poll schedule** — choose from Twice Daily (10am & 7pm), Every Hour, Every 6 Hours, or Once Daily (10am)
- **Manual refresh** — poll on demand via the dropdown menu (Cmd+R)
- **Start at Login** — toggle to launch automatically on login
- **Move to Applications** — on first launch, offers to install itself to `/Applications`
- **Offline detection** — shows "Offline" when the printer is unreachable
- **Menu bar only** — runs as a background utility with no Dock icon

## Requirements

- macOS 13+
- Xcode 15+ (for building)
- A network printer with SNMP enabled (community string: `public`)

## Install

Build and install to `/Applications` in one step:

```bash
./build.sh
```

This builds a release binary, creates a `.app` bundle, and copies it to `/Applications` via `ditto`.

To launch after installing:

```bash
open /Applications/SimpleTonerBar.app
```

## Build from Source

**Xcode:** Open `Package.swift` and run the `SimpleTonerBar` target.

**CLI (development):**

```bash
swift build
swift run SimpleTonerBar
```

## Dependencies

- [SwiftSnmpKit](https://github.com/darrellroot/SwiftSnmpKit) — SNMPv2c/v3 client library

## Verified Printers

 - HP Color LaserJet Pro 3201

## Built with

This project was built with [Claude Code](https://claude.ai/code).
