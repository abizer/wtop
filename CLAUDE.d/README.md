# wtop

Native macOS SwiftUI power monitor for Apple Silicon. Shows system power draw, per-component SoC breakdown, CPU core utilization, and per-process energy consumption.

## Build & Run

```bash
just build          # builds both wtop and wtop-helper
just install        # .app bundle → ~/Applications (Spotlight-searchable)
just install-helper # privileged daemon → /Library/ (needs sudo, on-demand)
```

Or all at once:
```bash
just install && just install-helper
```

Homebrew (one-touch, handles everything including the helper):
```bash
brew install abizer/tap/wtop
```

## Architecture

Two executables + shared protocol:

```
Sources/
  App/                      ← SwiftUI app (runs as current user)
    WtopApp.swift              App entry, ContentView, toolbar, admin status
    Monitor.swift              SystemMonitor @Observable — all data sampling
    Views.swift                Power cards, sparkline, core bars, process list
    SMC.swift                  Apple SMC reader (temperatures)
    IOReport.swift             IOReport private framework (CPU/GPU/ANE/DRAM watts)
    HelperClient.swift         XPC client for the privileged helper
  Helper/                   ← Privileged daemon (runs as root, on-demand)
    main.swift                 XPC listener, proc_pid_rusage for all PIDs
  Shared/                   ← Protocol definition
    HelperProtocol.swift       @objc XPC protocol + Mach service name
```

### Privilege Model

The app runs as the current user. Most features work without root:

| Feature | Needs root? |
|---------|-------------|
| System/battery/adapter power | No |
| CPU/GPU/ANE/DRAM breakdown (IOReport) | No |
| Per-core CPU usage | No |
| Temperatures (SMC) | No |
| Thermal state | No |
| User-app energy (Brave, Slack, etc.) | No |
| **System daemon energy** (WindowServer, kernel_task) | **Yes — via helper** |

For system daemon energy, the app connects to a privileged helper daemon over XPC:

```
[wtop.app]  ──XPC──▶  [wtop-helper]  ──proc_pid_rusage──▶  kernel
 (user)      Mach       (root)          RUSAGE_INFO_V6
             service
```

### Helper Daemon Lifecycle

The helper is **on-demand** — launchd starts it when the app connects, it exits when idle:

1. `just install-helper` (or `brew post_install`): copies binary to `/Library/PrivilegedHelperTools/`, registers LaunchDaemon plist with `launchctl bootstrap`. Helper does NOT start.
2. App opens → connects to Mach service `me.abizer.wtop.helper` → launchd starts helper as root.
3. App running → helper serves `proc_pid_rusage` data over XPC. Tracks active connection count.
4. App closes → XPC connection invalidates → helper starts 30-second idle timer.
5. Timer fires → `exit(0)`. Helper is gone. Zero resource usage until next app launch.

Key files:
- `/Library/PrivilegedHelperTools/me.abizer.wtop.helper` — the binary (root-owned)
- `/Library/LaunchDaemons/me.abizer.wtop.helper.plist` — on-demand config (`RunAtLoad=false`, `KeepAlive=false`)

### Distribution

**Homebrew formula** (builds from source, not a cask):
- `install`: `swift build -c release`, installs binaries to Cellar
- `post_install` (runs as root): copies helper to `/Library/PrivilegedHelperTools/`, registers LaunchDaemon, symlinks `.app` to `~/Applications`
- No Developer ID signing needed — formula builds on user's machine, `launchctl` doesn't validate code signatures for third-party LaunchDaemons
- Uninstall cleanup documented in caveats (Homebrew has no uninstall hook)

**justfile recipes:**
- `just build` — release build of both targets
- `just app` — `.app` bundle with embedded helper
- `just install` — copy `.app` to `~/Applications`
- `just install-helper` — sudo: copy daemon + register LaunchDaemon
- `just uninstall-helper` — sudo: bootout + remove files
- `just uninstall` — removes everything
- `just release <version>` — builds zip for GitHub Releases

### Data Sources

| Data | API | Root? |
|------|-----|-------|
| System/battery power | IOKit `AppleSmartBattery` `PowerTelemetryData.SystemLoad` | No |
| CPU/GPU/ANE/DRAM watts | IOReport `Energy Model` via `/usr/lib/libIOReport.dylib` | No |
| Per-process energy | `proc_pid_rusage` / `rusage_info_v6.ri_energy_nj` | System procs only |
| Per-process CPU + UID | `proc_pidinfo` / `PROC_PIDTASKALLINFO` (`.ptinfo` + `.pbsd`) | No |
| CPU core utilization | Mach `host_processor_info` / `PROCESSOR_CPU_LOAD_INFO` | No |
| Temperatures | SMC keys via `sp78` fixed-point (cached to avoid flicker) | No |
| Thermal state | `ProcessInfo.processInfo.thermalState` | No |
| System info | sysctl (`machdep.cpu.brand_string`, `hw.memsize`, etc.) | No |
| GPU core count | IOKit `AGXAccelerator` / `gpu-core-count` property | No |
| Memory usage | Mach `host_statistics64` / `HOST_VM_INFO64` | No |

### Key Implementation Details

**SMC struct layout (Apple Silicon):** `SMCParamStruct` must be exactly 80 bytes. Use `UInt32` for `KeyInfo.dataSize` (NOT `IOByteCount` which is 8 bytes on arm64). Include an explicit `padding: UInt16` between `keyInfo` and `result`. Selector is `2`. Check `output.result == 0` (non-zero = SMC error, e.g., `0x84` = key not found).

**IOReport unit labels:** Most channels report in `mJ` (millijoules), but some aggregates like `"GPU Energy"` use `nJ`. Always read `IOReportChannelGetUnitLabel` and scale: `mJ` ÷ 1e3, `uJ` ÷ 1e6, `nJ` ÷ 1e9.

**IOReport dlopen:** Dylib at `/usr/lib/libIOReport.dylib` (not in CLI tools SDK headers). `IOReportCopyChannelsInGroup` returns immutable dict — must `CFDictionaryCreateMutableCopy` before `IOReportCreateSubscription`. Pass `subbedChannels` output (not original channels) to `IOReportCreateSamples`. Use `IOReportIterate` (block-based) to walk channels — there is no `GetChannelAtIndex`.

**IOReport channel naming:** Use aggregate channels `"CPU Energy"` and `"GPU Energy"` for CPU/GPU (per-core channels are near-zero on idle). For DRAM, sum `"DRAM*"` + `"DCS*"` + `"AMCC*"` individual channels. For ANE, match `"ANE*"`.

**Process classification:** UID via `proc_taskallinfo.pbsd.pbi_uid`. UIDs ≥ 500 = user, < 500 = system. More reliable than `.app` path detection (loginwindow, BiomeAgent, node all correctly classified as user).

**proc_taskallinfo field name:** The task info member is `.ptinfo` in Swift (not `.ptask` as in the C header).

**Process list stability:** Apps cached in `appCache` dict with 5-cycle expiry via `appAge`. View maintains a `cachedOrder` that only re-sorts on explicit user interaction (sort/filter/search), not on data updates.

**Temperature stability:** SMC `temp()` can intermittently return nil. `lastTemps` dict caches last-known values to prevent UI flicker.

**sysctl types:** Apple Silicon sysctl values like `hw.logicalcpu` return `Int32` (4 bytes), not `Int` (8 bytes). The helper must check `size` and handle both.

**macOS GUI privilege escalation:** Running a GUI app as root doesn't work — the WindowServer is per-user-session, root processes can't properly handle Apple Events/Dock interactions. The correct pattern is: GUI runs as user, privileged helper runs as root daemon, they communicate via XPC. `setuid` doesn't work (App Translocation strips it). `AuthorizationExecuteWithPrivileges` runs inside `security_authtrampoline` which can't host SwiftUI windows.

## Dependencies

None — pure Swift with system frameworks only (IOKit, AppKit, SwiftUI, Darwin, Security, ServiceManagement). No third-party packages.
