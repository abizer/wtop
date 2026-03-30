# wtop

Real-time power monitor for Apple Silicon Macs. Native SwiftUI app that shows exactly where your watts are going — from the SoC components down to individual apps.

_written by [Claude Opus 4.6](https://www.anthropic.com/news/claude-opus-4-6) via Claude Code_

![wtop screenshot](https://github.com/abizer/wtop/raw/master/screenshot.png)

## Features

- **System power** — total draw, battery discharge rate, adapter input
- **SoC breakdown** — CPU, GPU, ANE, DRAM power via IOReport
- **Per-process energy** — actual watts per app, not just CPU time
- **CPU cores** — per-core utilization for E-cluster and P-cluster
- **Temperatures** — CPU, SSD, battery via SMC sensors
- **App grouping** — Brave's 12 helper processes collapse into one row
- **Power history** — 5-minute sparkline of system power
- **Thermal state** — nominal/fair/serious/critical indicator
- **Battery projection** — estimated time remaining at current draw

## Install

### Homebrew (recommended)

```bash
brew install abizer/tap/wtop
```

This builds from source, installs the app to `~/Applications` (Spotlight-searchable), and sets up a privileged helper daemon for full system process energy data.

### From source

```bash
git clone https://github.com/abizer/wtop
cd wtop
just install          # .app → ~/Applications
just install-helper   # privileged daemon (needs sudo)
```

Requires Swift 5.9+ and macOS 14+.

## Usage

Launch **wtop** from Spotlight, Raycast, or the terminal:

```bash
wtop
```

The app works without the privileged helper — system power, CPU/GPU/ANE/DRAM breakdown, core utilization, temperatures, and user-app energy are all available. The helper adds energy data for system daemons (WindowServer, kernel_task, etc.).

### Controls

- **All / Apps / System** — filter by user apps or system daemons
- **Sort** — by Power, CPU, Memory, or Name
- **Search** — filter processes by name
- **Refresh** — 0.5s, 1s, 2s, or 5s intervals

## How it works

wtop reads from five macOS subsystems, none of which require third-party dependencies:

| What | How |
|------|-----|
| System power | IOKit `AppleSmartBattery` registry |
| CPU/GPU/ANE/DRAM | IOReport `Energy Model` channels via `/usr/lib/libIOReport.dylib` |
| Per-process energy | `proc_pid_rusage` with `rusage_info_v6.ri_energy_nj` |
| CPU core load | Mach `host_processor_info` |
| Temperatures | SMC keys via IOKit (`sp78` fixed-point) |

The privileged helper runs **on-demand** — launchd starts it when the app opens an XPC connection, and it exits 30 seconds after the app closes. It never runs in the background.

## Uninstall

```bash
brew uninstall wtop
# Then clean up the helper:
sudo launchctl bootout system/me.abizer.wtop.helper
sudo rm -f /Library/PrivilegedHelperTools/me.abizer.wtop.helper
sudo rm -f /Library/LaunchDaemons/me.abizer.wtop.helper.plist
rm -f ~/Applications/wtop.app
```

Or if installed from source:

```bash
just uninstall
```

## Requirements

- Apple Silicon Mac (M1/M2/M3/M4)
- macOS 14 Sonoma or later
- Swift 5.9+ (for building from source)

## License

MIT

## Acknowledgments

Built with insights from [mactop](https://github.com/context-labs/mactop), [macmon](https://github.com/vladkens/macmon), and the [Stats](https://github.com/exelban/stats) app's SMC implementation.
