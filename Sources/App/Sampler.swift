import Darwin
import Foundation
import IOKit
import WtopShared

/// `mach_host_self()` bumps the port's send-right refcount on every call and the right is
/// never deallocated here — cache one for the process lifetime instead of leaking refs each tick.
private let machHost: host_t = mach_host_self()

/// Does all the measuring, off the main thread.
///
/// Every counter the kernel exposes is cumulative, so each reading is a delta
/// against the previous one divided by the time that *actually* elapsed —
/// never by the interval that was asked for.
actor Sampler {
    struct Snapshot: Sendable {
        var apps: [AppUsage] = []
        var cores: [CoreUsage] = []
        var power = PowerReading()
        var temps: [TempReading] = []
        var thermalLevel: ThermalLevel = .nominal
        var memUsedGB = 0
        var uptime = ""
        var helper: HelperStatus = .checking
    }

    private let clock = ContinuousClock()
    private let helper = HelperClient()
    private let smc: SMC?
    private let ioReport: IOReportPower?
    private let gpuClients = GPUClients()
    private let eCoreCount: Int

    // Processes
    private var lastProcessSample: ContinuousClock.Instant?
    private var lastCounters: [Int32: (cpu: UInt64, energy: UInt64)] = [:]
    /// Process-list stability: an app stays listed (at zero) for a few cycles after going quiet.
    private var appCache: [String: AppUsage] = [:]
    private var idleCycles: [String: Int] = [:]
    private let maxIdleCycles = 5
    /// proc_pidinfo reports CPU time in Mach ticks (125/3 ns each on Apple Silicon).
    private let nanosecondsPerTick: Double

    // Cores
    private var lastTicks: [(busy: UInt64, idle: UInt64)] = []

    // Power — the registry entry is cached; matching it every tick is needless IOKit churn
    private var batteryService: io_service_t = 0

    // Temperatures — hold the last good value so one failed SMC read doesn't blank a sensor
    private let tempKeys: [(key: String, label: String)]
    private var lastTemps: [String: Float] = [:]

    init(eCoreCount: Int) {
        self.eCoreCount = eCoreCount

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosecondsPerTick = timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)

        let smc = SMC()
        let candidates = [
            ("Tp09", "CPU Die"), ("Tp05", "CPU"), ("Tp01", "CPU Core"),
            ("Tg0P", "GPU"), ("Tg0J", "GPU Die"),
            ("Tm0P", "Memory"), ("Tm0p", "Memory"),
            ("TB0T", "Battery"), ("Ts0S", "SSD"),
            ("Te0P", "Ambient"), ("TW0P", "WiFi"),
        ]
        tempKeys = candidates.filter { smc?.temp($0.0) != nil }.map { (key: $0.0, label: $0.1) }
        self.smc = smc
        ioReport = IOReportPower()
    }

    func sample() async -> Snapshot {
        var snapshot = Snapshot()
        snapshot.power = samplePower()
        // GPU power is split between processes by the GPU time each was given.
        let gpuShares = snapshot.power.gpuW.flatMap { watts in gpuClients?.shares().mapValues { $0 * watts } } ?? [:]
        (snapshot.apps, snapshot.helper) = await sampleProcesses(gpuWatts: gpuShares)
        snapshot.cores = sampleCores()
        snapshot.temps = sampleTemps()
        snapshot.thermalLevel = thermalLevel()
        snapshot.memUsedGB = memoryUsedGB()
        snapshot.uptime = uptime()
        return snapshot
    }

    // MARK: - Processes

    private func sampleProcesses(gpuWatts: [Int32: Double]) async -> (apps: [AppUsage], helper: HelperStatus) {
        // Helper sees every process; without it we only see the user's own.
        let privileged = await helper.processes()
        let records = privileged ?? ProcessRecord.snapshot()

        let now = clock.now
        let elapsed = lastProcessSample.map { (now - $0).inSeconds }
        lastProcessSample = now

        var counters: [Int32: (cpu: UInt64, energy: UInt64)] = [:]
        counters.reserveCapacity(records.count)
        var active: [String: [ProcUsage]] = [:]

        for record in records {
            let cpu = record.cpuUser &+ record.cpuSystem
            counters[record.pid] = (cpu, record.energyNJ)

            // A pid we haven't seen, or one whose counters went backwards (pid reuse), has no rate yet.
            guard let elapsed, elapsed > 0.01,
                  let last = lastCounters[record.pid],
                  cpu >= last.cpu, record.energyNJ >= last.energy
            else { continue }

            let cpuMs = Double(cpu - last.cpu) * nanosecondsPerTick / 1e6 / elapsed
            let gpuW = gpuWatts[record.pid] ?? 0
            let energyW = Double(record.energyNJ - last.energy) / 1e9 / elapsed + gpuW
            guard cpuMs > 1 || energyW > 0.001 else { continue }

            let name = record.path.isEmpty
                ? "pid \(record.pid)"
                : String(record.path[record.path.index(after: record.path.lastIndex(of: "/") ?? record.path.startIndex)...])
            let group = Self.appName(inPath: record.path) ?? name
            active[group, default: []].append(ProcUsage(
                id: record.pid, name: name, appGroup: group,
                isUserApp: record.uid >= 500,
                cpuMs: cpuMs, energyW: energyW, gpuW: gpuW, hasEnergy: record.energyNJ > 0 || gpuW > 0,
                threads: Int(record.threads), mem: record.memResident
            ))
        }
        lastCounters = counters

        for (group, procs) in active {
            appCache[group] = AppUsage(id: group, procs: procs.sorted { $0.energyW > $1.energyW })
            idleCycles[group] = nil
        }
        for (group, app) in appCache where active[group] == nil {
            let cycles = idleCycles[group, default: 0] + 1
            if cycles > maxIdleCycles {
                appCache[group] = nil
                idleCycles[group] = nil
            } else {
                if cycles == 1 { appCache[group] = app.idle }
                idleCycles[group] = cycles
            }
        }

        let apps = appCache.values.sorted { $0.id < $1.id }
        return (apps, privileged == nil ? .unavailable : .connected)
    }

    /// "/Applications/Safari.app/Contents/MacOS/Safari" → "Safari"
    static func appName(inPath path: String) -> String? {
        guard let bundle = path.range(of: ".app/") ?? path.range(of: ".app", options: [.anchored, .backwards])
        else { return nil }
        let prefix = path[..<bundle.lowerBound]
        let start = prefix.lastIndex(of: "/").map(prefix.index(after:)) ?? prefix.startIndex
        return prefix[start...].isEmpty ? nil : String(prefix[start...])
    }

    // MARK: - CPU cores

    private func sampleCores() -> [CoreUsage] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(machHost, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        var ticks: [(busy: UInt64, idle: UInt64)] = []
        ticks.reserveCapacity(Int(cpuCount))
        var cores: [CoreUsage] = []
        cores.reserveCapacity(Int(cpuCount))

        for core in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * core
            func state(_ index: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(index)])) }
            let busy = state(CPU_STATE_USER) &+ state(CPU_STATE_SYSTEM) &+ state(CPU_STATE_NICE)
            let idle = state(CPU_STATE_IDLE)
            ticks.append((busy, idle))

            var usage = 0.0
            if core < lastTicks.count {
                let busyDelta = busy &- lastTicks[core].busy
                let total = busyDelta &+ (idle &- lastTicks[core].idle)
                if total > 0 { usage = Double(busyDelta) / Double(total) }
            }
            cores.append(CoreUsage(id: core, usage: usage, isEfficiency: core < eCoreCount))
        }
        lastTicks = ticks
        return cores
    }

    // MARK: - Power

    private func samplePower() -> PowerReading {
        var reading = PowerReading()

        if batteryService == 0 {
            batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        var properties: Unmanaged<CFMutableDictionary>?
        if batteryService != 0,
           IORegistryEntryCreateCFProperties(batteryService, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
           let battery = properties?.takeRetainedValue() as? [String: Any] {
            reading.onAC = battery["ExternalConnected"] as? Bool ?? false
            reading.batteryPct = battery["CurrentCapacity"] as? Int ?? -1

            let millivolts = battery["AppleRawBatteryVoltage"] as? Int ?? 0
            // Signed milliamps, negative while discharging. `ioreg` prints it as a huge unsigned
            // number, but the CFNumber is signed — casting to UInt64 fails for every negative value.
            let milliamps = battery["InstantAmperage"] as? Int ?? 0
            reading.batteryW = Double(abs(milliamps)) * Double(millivolts) / 1e6

            if let telemetry = battery["PowerTelemetryData"] as? [String: Any] {
                if let load = telemetry["SystemLoad"] as? Int, load > 0 { reading.systemW = Double(load) / 1000 }
                if let input = telemetry["SystemPowerIn"] as? Int, input > 0 { reading.adapterW = Double(input) / 1000 }
            }

            if !reading.onAC, reading.systemW > 0.1 {
                let remainingMah = battery["AppleRawCurrentCapacity"] as? Int ?? 0
                let remainingWh = Double(remainingMah) * Double(millivolts) / 1e6
                reading.batteryTimeRemaining = remainingWh / reading.systemW
            }
        }

        if let soc = ioReport?.sample() {
            reading.cpuW = soc.cpuW
            reading.gpuW = soc.gpuW
            reading.aneW = soc.aneW
            reading.dramW = soc.dramW
            reading.socOtherW = soc.socOtherW
            reading.hasIOReport = true
        }
        // PDBR is the backlight rail: it follows the brightness slider and nothing else.
        reading.displayW = smc?.watts("PDBR").map(Double.init)
        reading.fillGaps(memoryRailW: smc?.watts("PPSC").map(Double.init),
                         packageRailW: smc?.watts("PHPS").map(Double.init))
        return reading
    }

    // MARK: - Temperatures & thermal state

    private func sampleTemps() -> [TempReading] {
        guard let smc else { return [] }
        return tempKeys.compactMap { key, label in
            if let celsius = smc.temp(key) { lastTemps[key] = celsius }
            return lastTemps[key].map { TempReading(id: key, label: label, celsius: $0) }
        }
    }

    private func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    // MARK: - Memory & uptime

    private func memoryUsedGB() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(machHost, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = UInt64(stats.internal_page_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        var pageSize: vm_size_t = 0
        guard host_page_size(machHost, &pageSize) == KERN_SUCCESS else { return 0 }
        return Int(pages * UInt64(pageSize) / (1 << 30))
    }

    private func uptime() -> String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return "" }
        let seconds = max(Int(Date().timeIntervalSince1970) - boot.tv_sec, 0)
        let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
        return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
    }
}
