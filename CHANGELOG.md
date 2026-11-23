# Changelog

## v0.5.1

- **Liquid Glass.** The hand-rolled header is now a standard window toolbar: on macOS 26 and later the helper badge and refresh picker sit in glass capsules and the content scrolls beneath them. The machine summary moved to the window subtitle. macOS 14 and 15 get the same toolbar in the classic style.

## v0.5.0

New:

- **The power breakdown now adds up to the system figure.** Three new cards: Display (backlight, from the SMC), Other SoC (the rest of the chip, from the CLPC package counter; macOS 27), and Everything Else (what no sensor accounts for).
- **Per-app GPU power.** A new GPU column splits the GPU's watts between apps by the GPU time each was given, and an app's Power now includes it. It is an apportionment, not a measurement.
- On chips without known CLPC IDs, DRAM and Other SoC fall back to SMC rails (`PPSC`, `PHPS`) that were checked against the CLPC counters on an M3 Max.
- Temperatures are labelled °C.

Accuracy — several numbers on screen were wrong:

- **CPU ms/s was ~42× too low.** `proc_pidinfo` reports CPU time in Mach ticks (125/3 ns on Apple Silicon), not nanoseconds. A fully pinned core now reads ~1000 ms/s.
- **Temperatures were noise.** Apple Silicon SMC keys are little-endian floats; they were being decoded as `sp78` fixed-point, producing random values that happened to fall in a plausible range. Now decoded by each key's declared type.
- **Battery watts read 0 while discharging.** The signed amperage failed an unsigned cast for every negative value.
- **CPU/GPU/ANE/DRAM watts were wrong at any interval other than 2s** (4× low at 0.5s, 2.5× high at 5s). All rates now divide by measured elapsed time instead of the nominal interval.
- **CPU, ANE and DRAM read 0 mW on macOS 27.** The `Energy Model` counters freeze there for apps without an Apple entitlement. They are now read from the CLPC driver's energy counters (IDs ported from [macmon](https://github.com/vladkens/macmon)); a chip without known IDs shows "—" rather than a false zero.
- Process data from the helper is no longer one tick stale, and apps that go quiet show zero instead of their last reading.
- WebKit and other `com.apple.*` helpers are no longer grouped under an app called "com".

Reliability:

- **Helper now actually exits when idle.** Its 30s timer was scheduled from an XPC callback queue with no run loop, so it never fired; a second client disconnecting could also strand the first.
- **"Limited" is no longer sticky** — the app retries the helper every 10s, so installing it while wtop is open just works. A dead helper can no longer hang the sampling loop.
- Truncated helper replies are rejected instead of crashing the decoder.
- Single window (`Window` scene) — ⌘N no longer spawns a second monitor, sampler and helper connection.

Internals:

- Swift 6 language mode with strict concurrency. All sampling moved off the main thread into an `actor Sampler`; the main actor only publishes snapshots.
- `Sources/Shared` is now a real library linked into both executables: one XPC protocol declaration, one process-table reader, one wire codec (previously each was duplicated by hand).
- First tests: wire-format compatibility with the v0.4 helper, idle timer, SMC decoding, and a live sampler test that pins a core.
- The process list no longer recomputes its filter and peak once per row per render.
- Bundle version is stamped from the release tag (it had been stuck at 0.1.0). `support/make-app.sh` is shared by `just app` and CI; CI moves to `macos-26` and runs the tests.

## v0.4.4

- Fixed IOReport sample leak (~100 KB per tick, gigabytes over days); cached the Mach host port, battery service and SMC key info.

## v0.4.1 – v0.4.3

- Release pipeline fixes for the Homebrew cask bump.

## v0.4.0

- **System processes visible** — helper now provides full process data (CPU, memory, threads, energy, path) for all PIDs, not just energy. System tab shows WindowServer, kernel_task, etc.
- **Homebrew cask** — switched from formula (builds from source) to cask (pre-built binary from GitHub Releases). Installs via `brew install --cask abizer/tap/wtop`.
- **Quarantine handling** — cask postflight strips `com.apple.quarantine` xattr (app is ad-hoc signed).
- **Helper postflight** — cask automatically installs the privileged helper daemon (prompts for password).
- **CI pipeline** — tag push triggers GitHub Actions: build → zip → release → update cask sha256.

## v0.3.0

- Fixed codesign: shell scripts go in `Contents/Resources/` (not `Helpers/`).
- Fixed `install-helper.sh` path resolution within `.app` bundle.
- CI release workflow builds `.app` and uploads to GitHub Releases.

## v0.2.0

- **macOS version** in toolbar info line.
- Removed `--disable-sandbox` investigation (it IS required — SPM sandbox conflicts with Homebrew's).
- Fixed `Resources/` → `support/` rename (SPM reserves `Resources/`).
- Formula uses `buildpath` for source file references.
- Formula uses `--show-bin-path` for portable binary paths.

## v0.1.0

Initial release.

- System/battery/adapter power from IOKit AppleSmartBattery
- CPU/GPU/ANE/DRAM breakdown via IOReport private framework
- Per-process energy in watts via `rusage_info_v6.ri_energy_nj`
- Per-core CPU usage (E-cluster + P-cluster)
- App grouping by `.app` bundle with UID-based user/system classification
- SMC temperature sensors
- Thermal pressure indicator
- Power history sparkline (5-min rolling window)
- Battery time remaining projection
- Sort/search/filter with stable cached ordering
- System info header (hostname, CPU, GPU cores, RAM, uptime)
- On-demand privileged helper daemon via XPC
- Proper macOS `.app` bundle (Spotlight/Raycast/Dock/Cmd+Tab)
