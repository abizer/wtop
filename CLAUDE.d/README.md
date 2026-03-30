# wtop

Native macOS SwiftUI app for real-time power monitoring on Apple Silicon. Shows system power draw, per-component SoC breakdown, CPU core utilization, and per-process energy consumption.

## Build & Run

```bash
swift build
sudo .build/debug/wtop
```

Requires `sudo` for full functionality:
- `proc_pid_rusage` for all processes' energy data (without sudo, only user-owned processes report)
- IOReport for CPU/GPU/ANE/DRAM component power

Without sudo the app still works — system power, CPU cores, and user-process energy are available.

## Architecture

5 source files, ~1400 lines total:

| File | Purpose |
|------|---------|
| `WtopApp.swift` | App entry point, ContentView, toolbar with system info |
| `Monitor.swift` | `SystemMonitor` @Observable class — all data sampling |
| `Views.swift` | All SwiftUI views: power cards, sparkline, core bars, process list |
| `SMC.swift` | Apple SMC reader via IOKit (temperatures, power sensors) |
| `IOReport.swift` | IOReport private framework wrapper via dlopen for SoC power breakdown |

### Data Sources

| Data | API | Root? |
|------|-----|-------|
| System/battery power | IOKit `AppleSmartBattery` registry | No |
| CPU/GPU/ANE/DRAM watts | IOReport `Energy Model` group via `/usr/lib/libIOReport.dylib` | No |
| Per-process energy (watts) | `proc_pid_rusage` with `rusage_info_v6.ri_energy_nj` | Yes (for system procs) |
| Per-process CPU time | `proc_pidinfo` with `PROC_PIDTASKALLINFO` | No |
| CPU core utilization | Mach `host_processor_info` / `PROCESSOR_CPU_LOAD_INFO` | No |
| Temperatures | SMC keys (`Tp05`, `TB0T`, `Ts0S`, etc.) via `sp78` fixed-point | No |
| Thermal state | `ProcessInfo.processInfo.thermalState` | No |
| Process UID (user/system) | `proc_taskallinfo.pbsd.pbi_uid` (≥500 = user) | No |
| System info | sysctl (`machdep.cpu.brand_string`, `hw.memsize`, etc.) | No |
| GPU core count | IOKit `AGXAccelerator` service, `gpu-core-count` property | No |
| Memory usage | Mach `host_statistics64` / `HOST_VM_INFO64` | No |

### Key Implementation Details

**SMC struct layout (Apple Silicon):** The `SMCParamStruct` must be exactly 80 bytes. Critical: use `UInt32` for `KeyInfo.dataSize` (NOT `IOByteCount` which is 8 bytes on arm64), and include an explicit `padding: UInt16` field between `keyInfo` and `result`. The selector is `2`, and `output.result` must be checked for `0` (non-zero means SMC-level error like key-not-found = `0x84`).

**IOReport unit labels:** Channels report energy in different units — most use `mJ` (millijoules), but aggregate channels like `"GPU Energy"` use `nJ` (nanojoules). Always check `IOReportChannelGetUnitLabel` and scale accordingly: `mJ` ÷ 1e3, `uJ` ÷ 1e6, `nJ` ÷ 1e9.

**IOReport dlopen:** The framework isn't in the CLI tools SDK but the dylib exists at `/usr/lib/libIOReport.dylib`. Load via `dlopen`, resolve symbols with `dlsym`. Key: `IOReportCopyChannelsInGroup` returns an immutable dict — must `CFDictionaryCreateMutableCopy` before passing to `IOReportCreateSubscription`. Use `IOReportIterate` (block-based) to walk channels; there is no `GetChannelAtIndex` function.

**IOReport sampling:** `IOReportCreateSamples(subscription, subbedChannels, nil)` — the second arg must be the `subbedChannels` output from `IOReportCreateSubscription`, NOT the original channels.

**Process classification:** Uses process UID via `proc_taskallinfo.pbsd.pbi_uid`. UIDs ≥ 500 = user process, < 500 = system. More reliable than path-based `.app` detection.

**Process list stability:** Apps cached with 5-cycle expiry (`appCache` + `appAge` dicts). Prevents list flickering when processes briefly dip below activity threshold. View uses cached sort order that only re-ranks on explicit user interaction (sort/filter/search change), not on data updates.

**sysctl types:** On Apple Silicon macOS, sysctl values like `hw.logicalcpu` return `Int32` (4 bytes), not `Int` (8 bytes). The sysctl helper must check `size` and handle both.

## Dependencies

None — pure Swift with system frameworks only (IOKit, AppKit, SwiftUI, Darwin). No third-party packages.
