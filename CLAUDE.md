# wtop

Native macOS SwiftUI power monitor for Apple Silicon.

## Build & Run

```bash
just build            # release build of wtop + wtop-helper
just test             # swift test (sampler tests pin a core for a few seconds)
just app              # .app bundle in ./wtop.app (support/make-app.sh, also used by CI)
just install          # .app → ~/Applications
just install-helper   # privileged daemon → /Library/ (sudo)
just run              # debug build + launch
just release 0.5.0    # tag + push (CI handles the rest)
just clean            # rm -rf .build wtop.app
```

Homebrew:
```bash
brew tap abizer/wtop https://github.com/abizer/wtop && brew trust abizer/wtop
brew install --cask abizer/wtop/wtop
```

## Architecture

```
Sources/
  App/                    ← SwiftUI app (runs as current user)
    WtopApp.swift            App entry (single Window), ContentView, native toolbar, helper badge
    Monitor.swift            SystemMonitor @Observable @MainActor — timer loop, publishes snapshots
    Sampler.swift            actor Sampler — ALL measuring, off the main thread
    Models.swift             Sendable value types (ProcUsage, AppUsage, PowerReading, SystemInfo…)
    Views.swift              Power cards, sparkline, core bars, process list
    SMC.swift                SMC reader (temperatures)
    IOReport.swift           IOReport private framework (CPU/GPU/ANE/DRAM)
    CLPC.swift               AppleCLPC energy counter IDs — the macOS 27 source for CPU/ANE/DRAM
    GPUClients.swift         Per-process GPU time from the IO registry (splits GPU watts between apps)
    HelperClient.swift       actor — XPC client with retry backoff
  Helper/                 ← Privileged daemon (root, on-demand via launchd)
    main.swift               XPC listener; replies with ProcessRecord.snapshot()
  Shared/                 ← WtopShared library, linked into BOTH executables
    HelperProtocol.swift     @objc XPC protocol + Mach service name (the only declaration)
    ProcessRecord.swift      Process-table reader + frozen binary wire format
    IdleTimer.swift          Connection counting + idle callback (helper's exit-after-30s)
Tests/
  SharedTests/            ← wire format, idle timer
  AppTests/               ← app grouping, SMC decoding, live sampler (skipped when CI is set)
```

### Sampling model

`SystemMonitor` (main actor) runs one loop: `await sampler.sample()` → publish → sleep. `Sampler` is an actor that owns every piece of previous-sample state. Every kernel counter is cumulative, so each rate is `delta / time actually elapsed` — measured with `ContinuousClock` at each sample, never the nominal interval. Restarting the loop (interval change) awaits the old loop first so two never sample at once.

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

Every tick the Sampler asks `HelperClient.processes()`; on nil it falls back to a local `ProcessRecord.snapshot()` (same function the helper runs as root). There is no separate "installed?" probe — a failed fetch backs off 10s and retries, so a helper installed while the app is open is picked up automatically. The toolbar badge (Admin/Limited) reflects which path the last sample took.

## Distribution

### Homebrew cask (pre-built binary)

This repo is its own tap: the cask is `Casks/wtop.rb` on master. Because the repo isn't named `homebrew-*`, `brew tap` needs the URL. CI builds `.app` on macOS arm64, uploads to GitHub Releases. Cask downloads and installs.

**Cask postflight:**
1. `xattr -r -d com.apple.quarantine` (app is ad-hoc signed, not notarized)
2. `install-helper.sh` with `sudo: true` (installs LaunchDaemon, prompts for password)

**Cask uninstall block:** handles `launchctl bootout` + file cleanup automatically.

### Release pipeline

```
git tag v0.5.0 && git push --tags
  → CI: build .app → zip → GitHub Release
  → CI: rewrite version + sha256 in Casks/wtop.rb, commit "cask: wtop 0.5.0" to master
  → Users: brew upgrade --cask wtop
```

No extra secrets: the bump is a `sed` plus a push with the workflow's own `GITHUB_TOKEN` (`contents: write`). It deliberately doesn't use `brew bump-cask-pr` — Homebrew 7 refuses to load a cask from an untrusted tap, which is what broke the v0.5.0 bump to the old `abizer/homebrew-tap`.

### justfile `release` recipe

Runs the tests, then tags and pushes — CI does the rest:
```bash
just release 0.5.0  # → just test && git tag v0.5.0 && git push --tags
```

The bundle version comes from the tag: `support/make-app.sh <version>` stamps `CFBundleShortVersionString`/`CFBundleVersion` into the built bundle (the checked-in `Info.plist` value is a placeholder). CI runs on `macos-26`.

## Data Sources

| Data | API | Root? |
|------|-----|-------|
| System/battery power | IOKit `AppleSmartBattery` → `PowerTelemetryData.SystemLoad` | No |
| CPU/GPU/ANE/DRAM watts | IOReport `Energy Model` (macOS 27: `CLPC` counters for CPU/ANE/DRAM) via `/usr/lib/libIOReport.dylib` | No |
| Rest of the SoC | CLPC `Package Energy` minus CLPC's CPU/GPU/ANE/DRAM/DCS (macOS 27 only) | No |
| Display backlight | SMC `PDBR` (verified: follows the brightness slider, 0.2 W at 10% → 10.5 W at 100% on a 16" M3 Max) | No |
| Everything else | System minus all of the above (`PowerReading.unattributedW`), clamped at 0 | No |
| Per-process GPU share | IO registry: `AppUsage[].accumulatedGPUTime` (ns) on each child of `IOAccelerator`, pid from `IOUserClientCreator` | No |
| Per-process energy | `rusage_info_v6.ri_energy_nj` via `proc_pid_rusage` | System procs: yes |
| Per-process CPU/mem | `proc_pidinfo` / `PROC_PIDTASKALLINFO` | System procs: yes |
| CPU core utilization | Mach `host_processor_info` / `PROCESSOR_CPU_LOAD_INFO` | No |
| Temperatures | SMC keys, decoded by declared type (`flt ` on Apple Silicon) | No |
| Thermal state | `ProcessInfo.processInfo.thermalState` | No |
| System info | sysctl (`machdep.cpu.brand_string`, `hw.memsize`, etc.) | No |
| GPU core count | IOKit `AGXAccelerator` → `gpu-core-count` | No |
| Memory usage | Mach `host_statistics64` / `HOST_VM_INFO64` | No |

## Key Gotchas

**Building without Xcode (Command Line Tools only):** the macOS 27 SDK makes SwiftUI's `@State` a macro whose plugin (`SwiftUIMacros`) ships only with Xcode, so `swift build` fails with "plugin for module 'SwiftUIMacros' not found". The justfile exports `SDKROOT` to the CLT's `MacOSX26.sdk` in that case — use `just`, or set `SDKROOT` yourself for bare `swift` commands. Same toolchain intermittently drops the Swift Testing plugin; `just test` passes `-plugin-path` explicitly. SourceKit diagnostics in editors will still show these as errors — trust the build.

**Liquid Glass comes from the SDK stamp, not from code:** macOS gives an app the new design when its binary's `LC_BUILD_VERSION` says SDK ≥ 26 (`otool -l … | grep -A5 LC_BUILD_VERSION`). The UI uses only standard pieces (`.toolbar`, `navigationSubtitle`, segmented pickers), so there are no `glassEffect` calls and no availability checks — content cards deliberately stay plain, since glass is for the control layer. The CLT linker stamps the deployment target (14.0) as the SDK version, which silently renders a local build in the old style; the justfile corrects it with `-Xlinker -platform_version` (`WTOP_BUILD_FLAGS`, also read by `support/make-app.sh`). CI's Xcode stamps it correctly. A window must be frontmost for the glass to show in a screenshot.

**CPU time is in Mach ticks, not nanoseconds:** `proc_taskinfo.pti_total_user/system` (and `rusage_info` times) are Mach absolute time units — 125/3 ns each on Apple Silicon. Scale by `mach_timebase_info` or CPU reads ~42× too low. A fully pinned core must show ~1000 ms/s; `Tests/AppTests` asserts exactly that.

**SMC temperature encoding:** Apple Silicon temperature keys are type `flt ` (little-endian IEEE float), not `sp78`. Decode by the key's declared `dataType` — decoding a float as sp78 yields random numbers that often land in a plausible range (looks like "flicker"). Labels in `Sampler.init` are still guesses per key: `Te0P` reads ~CPU temperature on an M3 Max, so "Ambient" is probably wrong there.

**IOKit signed numbers:** `InstantAmperage` etc. are signed CFNumbers that `ioreg` prints as huge unsigned values. Cast `as? Int`; `as? UInt64` returns nil for every negative value (i.e. whenever the battery is discharging).

**macOS 27 freezes the Energy Model:** without an Apple entitlement, the power manager's `Energy Model` channels (CPU, ANE, DRAM, DISP… — all of `AppleT60xxPMGR`) sit at a constant value for minutes and then catch up in one jump; only `GPU Energy` (AGX driver) stays live. A reboot doesn't help. On 27+ CPU/ANE/DRAM are therefore read from AppleCLPC's `Energy Counters` instead (`CLPC.swift`): unpublished channels subscribed by hard-coded per-chip report IDs, table ported from macmon and generated from 27.2. A chip or OS major missing from the table shows "—" — never the Energy Model value, which would be a false zero or a spike of hundreds of watts. If the cards go "—" after an OS update, the IDs moved: refresh the table from macmon's `src/clpc.rs`.

**SMC power rails (M3 Max, measured against CLPC through idle / P-cores / E-cores / GPU / memory / SSD / dimmed phases):** `PZD1` = DRAM, `PPSC` = DRAM + DCS, `PHPS` ≈ `PZC0` ≈ `PZC1` = whole SoC package (all within ~2%), `PDBR` = backlight, `Pb0f` = `PPBR` = battery. `PC10/12/20/22` are GPU supply rails and `PC02/PC42` the two P-clusters, but their sums don't match CLPC (58 W vs 45 W GPU; 10 W vs 15 W CPU) — don't display them. `PHPC` is NOT SoC power (82 W when the package is 51 W). `PSVR`, `PE0b`, `PMVC`, `P5SR`, `PR0b`, `PFLR` rise with load but are unidentified. Only `PPSC`/`PHPS` are used, as gap-fillers (`PowerReading.fillGaps`), and only this one chip is verified.

**System vs chip under GPU load:** a heavy Metal load raised system power by 84 W but the CLPC package by only 50 W. The difference shows up in "Everything Else". Unknown whether that is conversion loss or the modelled counters under-reporting GPU power.

**Per-process power is CPU energy + a GPU share:** `ri_energy_nj` covers CPU only. `ProcUsage.gpuW` = GPU watts × the process's fraction of GPU time that tick; `energyW` includes it. There is no per-process signal for DRAM, display or anything else — a memory-copy load and a pure CPU load draw the same DRAM power.

**Wire format is frozen:** an installed helper is only replaced when the user reinstalls it, so `ProcessRecord.encode/decode` must stay byte-compatible (there is a test pinning the layout). The XPC selector `getProcessDataWithReply:` likewise.

**XPC callbacks run on arbitrary queues:** `Timer.scheduledTimer` from an invalidation handler never fires (no run loop there). Helper lifecycle state lives on `IdleTimer`'s serial queue; only `invalidationHandler` decrements (it fires exactly once per connection).

**App grouping:** match `.app/` (or a trailing `.app`), not bare `.app` — `com.apple.WebKit…` contains ".app" and would group as "com".

**SMC struct (Apple Silicon):** Must be exactly 80 bytes. `KeyInfo.dataSize` = `UInt32` (NOT `IOByteCount`/8 bytes on arm64). Explicit `padding: UInt16` between `keyInfo` and `result`. Selector `2`. Check `output.result == 0`.

**IOReport units:** Most channels report `mJ`, but `"GPU Energy"` aggregate uses `nJ`. Always check `IOReportChannelGetUnitLabel`. Scale: `mJ` ÷ 1e3, `uJ` ÷ 1e6, `nJ` ÷ 1e9.

**IOReport dlopen:** Dylib at `/usr/lib/libIOReport.dylib`. `IOReportCopyChannelsInGroup` returns immutable → `CFDictionaryCreateMutableCopy` before subscription. Pass `subbedChannels` (not original) to `IOReportCreateSamples`. Iterate via `IOReportIterate` (block-based).

**IOReport Create-rule leaks:** `IOReportCreateSamples` / `IOReportCreateSamplesDelta` return +1-retained CF objects. Held as `UnsafeRawPointer` they're invisible to ARC — must `Unmanaged.fromOpaque(p).release()` both the old prev sample and the delta every tick, or the app leaks ~100KB/sample (20GB after a couple of days).

**Mach port refcounts:** `mach_host_self()` bumps a send-right refcount per call. Cache one `host_t` for the process lifetime instead of calling it every sample.

**IOReport channels:** Use `"CPU Energy"` / `"GPU Energy"` aggregates. For DRAM sum `DRAM*` + `DCS*` + `AMCC*`. For ANE match `ANE*`.

**proc_pidinfo visibility:** `PROC_PIDTASKALLINFO` returns 0 for system processes (uid < 500) without root. Both `PROC_PIDTASKALLINFO` and `PROC_PIDTASKINFO` fail. The helper is required for system process data.

**proc_taskallinfo field:** Swift imports the task info member as `.ptinfo` (not `.ptask`).

**Process classification:** UID ≥ 500 = user, < 500 = system. More reliable than `.app` path matching.

**Process list stability:** `appCache` dict with 5-cycle expiry; an app that goes quiet stays listed with its rates zeroed. View uses `frozenOrder` that re-sorts only on user interaction.

**Temperature stability:** `lastTemps` dict caches last-known values so a single failed SMC read doesn't blank a sensor.

**sysctl Int32:** Apple Silicon sysctl values return `Int32` (4 bytes), not `Int` (8 bytes).

**GUI privilege escalation doesn't work:** Root GUI apps can't handle Apple Events (WindowServer is per-user-session). `setuid` fails (App Translocation). `AuthorizationExecuteWithPrivileges` runs inside `security_authtrampoline` (can't host SwiftUI). Correct pattern: user GUI + root daemon + XPC.

**Homebrew sandbox:** `swift build` inside Homebrew requires `--disable-sandbox` (SPM's `sandbox-exec` conflicts with Homebrew's own sandbox).

**Homebrew `install` moves files:** `Pathname#install` MOVES (not copies). Build .app bundle BEFORE calling `(etc/"wtop").install`.

**Homebrew quarantine:** Casks are quarantined by default. Strip in postflight: `xattr -r -d com.apple.quarantine`.

**Codesign + shell scripts:** Shell scripts in `Contents/Helpers/` break `codesign`. Put scripts in `Contents/Resources/` instead.

## Dependencies

None. Pure Swift 6 (strict concurrency) + system frameworks (IOKit, AppKit, SwiftUI, Darwin). Deployment target macOS 14.
