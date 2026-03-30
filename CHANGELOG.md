# Changelog

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
