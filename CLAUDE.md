# wtop

Native macOS SwiftUI power monitor for Apple Silicon.

## Build & Run

```bash
just build            # release build of wtop + wtop-helper
just app              # .app bundle in ./wtop.app
just install          # .app → ~/Applications
just install-helper   # privileged daemon → /Library/ (sudo)
just run              # debug build + launch
just release 0.5.0    # tag + push (CI handles the rest)
just clean            # rm -rf .build wtop.app
```

Homebrew:
```bash
brew install --cask abizer/tap/wtop
```

## Architecture

```
Sources/
  App/                    ← SwiftUI app (runs as current user)
    WtopApp.swift            App entry, ContentView, toolbar, admin badge
    Monitor.swift            SystemMonitor @Observable — all sampling
    Views.swift              Power cards, sparkline, core bars, process list
    SMC.swift                SMC reader (temperatures)
    IOReport.swift           IOReport private framework (CPU/GPU/ANE/DRAM)
    HelperClient.swift       XPC client — decodes binary process data from helper
  Helper/                 ← Privileged daemon (root, on-demand via launchd)
    main.swift               XPC listener, returns full process data for ALL pids
  Shared/                 ← Protocol definition
    HelperProtocol.swift     @objc XPC protocol + Mach service name
```

### Why the helper exists

`proc_pidinfo(PROC_PIDTASKALLINFO)` returns 0 for system processes (uid < 500) when running as a regular user. Without root, we can't even read CPU time for WindowServer, kernel_task, etc. The helper runs as root and provides full process data (pid, uid, cpu times, energy, threads, memory, path) over XPC.

### Helper lifecycle (on-demand)

1. `just install-helper` / cask postflight: registers LaunchDaemon (`RunAtLoad=false`, `KeepAlive=false`)
2. App opens → XPC connect → launchd starts helper as root
3. Helper serves data, tracks connection count
4. App closes → 30s idle timer → `exit(0)`. Zero background resource usage.

### Data flow

```
Without helper:  app ──proc_pidinfo──▶ kernel (user procs only)
With helper:     app ──XPC──▶ helper ──proc_pidinfo──▶ kernel (all procs)
                                     ──proc_pid_rusage──▶ (energy)
```

The Monitor checks `helperClient.status == .running` and `helperData != nil`. If available, uses helper data. Otherwise falls back to local `gatherLocalProcs()`.

## Distribution

### Homebrew cask (pre-built binary)

CI builds `.app` on macOS arm64, uploads to GitHub Releases. Cask downloads and installs.

**Cask postflight:**
1. `xattr -r -d com.apple.quarantine` (app is ad-hoc signed, not notarized)
2. `install-helper.sh` with `sudo: true` (installs LaunchDaemon, prompts for password)

**Cask uninstall block:** handles `launchctl bootout` + file cleanup automatically.

### Release pipeline

```
git tag v0.5.0 && git push --tags
  → CI: build .app → zip → GitHub Release
  → CI: update Casks/wtop.rb in homebrew-tap (version + sha256)
  → Users: brew upgrade --cask wtop
```

Requires `TAP_TOKEN` secret (fine-grained PAT with `contents:write` + `pull-requests:write` on `abizer/homebrew-tap`).

### justfile `release` recipe

Just tags and pushes — CI does the rest:
```bash
just release 0.5.0  # → git tag v0.5.0 && git push --tags
```

## Data Sources

| Data | API | Root? |
|------|-----|-------|
| System/battery power | IOKit `AppleSmartBattery` → `PowerTelemetryData.SystemLoad` | No |
| CPU/GPU/ANE/DRAM watts | IOReport `Energy Model` via `/usr/lib/libIOReport.dylib` | No |
| Per-process energy | `rusage_info_v6.ri_energy_nj` via `proc_pid_rusage` | System procs: yes |
| Per-process CPU/mem | `proc_pidinfo` / `PROC_PIDTASKALLINFO` | System procs: yes |
| CPU core utilization | Mach `host_processor_info` / `PROCESSOR_CPU_LOAD_INFO` | No |
| Temperatures | SMC `sp78` keys (cached to avoid flicker) | No |
| Thermal state | `ProcessInfo.processInfo.thermalState` | No |
| System info | sysctl (`machdep.cpu.brand_string`, `hw.memsize`, etc.) | No |
| GPU core count | IOKit `AGXAccelerator` → `gpu-core-count` | No |
| Memory usage | Mach `host_statistics64` / `HOST_VM_INFO64` | No |

## Key Gotchas

**SMC struct (Apple Silicon):** Must be exactly 80 bytes. `KeyInfo.dataSize` = `UInt32` (NOT `IOByteCount`/8 bytes on arm64). Explicit `padding: UInt16` between `keyInfo` and `result`. Selector `2`. Check `output.result == 0`.

**IOReport units:** Most channels report `mJ`, but `"GPU Energy"` aggregate uses `nJ`. Always check `IOReportChannelGetUnitLabel`. Scale: `mJ` ÷ 1e3, `uJ` ÷ 1e6, `nJ` ÷ 1e9.

**IOReport dlopen:** Dylib at `/usr/lib/libIOReport.dylib`. `IOReportCopyChannelsInGroup` returns immutable → `CFDictionaryCreateMutableCopy` before subscription. Pass `subbedChannels` (not original) to `IOReportCreateSamples`. Iterate via `IOReportIterate` (block-based).

**IOReport channels:** Use `"CPU Energy"` / `"GPU Energy"` aggregates. For DRAM sum `DRAM*` + `DCS*` + `AMCC*`. For ANE match `ANE*`.

**proc_pidinfo visibility:** `PROC_PIDTASKALLINFO` returns 0 for system processes (uid < 500) without root. Both `PROC_PIDTASKALLINFO` and `PROC_PIDTASKINFO` fail. The helper is required for system process data.

**proc_taskallinfo field:** Swift imports the task info member as `.ptinfo` (not `.ptask`).

**Process classification:** UID ≥ 500 = user, < 500 = system. More reliable than `.app` path matching.

**Process list stability:** `appCache` dict with 5-cycle expiry. View uses `cachedOrder` that re-sorts only on user interaction.

**Temperature stability:** `lastTemps` dict caches last-known values (SMC reads intermittently return nil).

**sysctl Int32:** Apple Silicon sysctl values return `Int32` (4 bytes), not `Int` (8 bytes).

**GUI privilege escalation doesn't work:** Root GUI apps can't handle Apple Events (WindowServer is per-user-session). `setuid` fails (App Translocation). `AuthorizationExecuteWithPrivileges` runs inside `security_authtrampoline` (can't host SwiftUI). Correct pattern: user GUI + root daemon + XPC.

**Homebrew sandbox:** `swift build` inside Homebrew requires `--disable-sandbox` (SPM's `sandbox-exec` conflicts with Homebrew's own sandbox).

**Homebrew `install` moves files:** `Pathname#install` MOVES (not copies). Build .app bundle BEFORE calling `(etc/"wtop").install`.

**Homebrew quarantine:** Casks are quarantined by default. Strip in postflight: `xattr -r -d com.apple.quarantine`.

**Codesign + shell scripts:** Shell scripts in `Contents/Helpers/` break `codesign`. Put scripts in `Contents/Resources/` instead.

## Dependencies

None. Pure Swift + system frameworks (IOKit, AppKit, SwiftUI, Darwin, ServiceManagement).
