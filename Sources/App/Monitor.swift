import Foundation
import Darwin
import IOKit
import Observation

// MARK: - Models

struct ProcUsage: Identifiable {
    let id: Int32
    let name: String
    let appGroup: String
    let isUserApp: Bool     // true if from a .app bundle
    let cpuMs: Double
    let energyW: Double
    let hasEnergy: Bool
    let threads: Int
    let mem: UInt64

    var cpuPct: Double { cpuMs / 10.0 }
}

struct AppUsage: Identifiable {
    let id: String
    var procs: [ProcUsage]

    var totalCpuMs: Double   { procs.reduce(0) { $0 + $1.cpuMs } }
    var totalEnergyW: Double { procs.reduce(0) { $0 + $1.energyW } }
    var totalMem: UInt64     { procs.reduce(0) { $0 + $1.mem } }
    var totalThreads: Int    { procs.reduce(0) { $0 + $1.threads } }
    var hasEnergy: Bool      { procs.contains { $0.hasEnergy } }
    var isUserApp: Bool      { procs.first?.isUserApp ?? false }
}

struct CoreUsage: Identifiable {
    let id: Int
    let usage: Double
    let isEfficiency: Bool
}

struct TempReading: Identifiable {
    let id: String   // SMC key
    let label: String
    let celsius: Float
}

struct PowerReading {
    var systemW: Double = 0
    var batteryW: Double = 0
    var adapterW: Double = 0
    var onAC: Bool = false
    var batteryPct: Int = -1
    var batteryTimeRemaining: Double?
    // IOReport SoC component breakdown
    var cpuW: Double = 0
    var gpuW: Double = 0
    var aneW: Double = 0
    var dramW: Double = 0      // DRAM + DCS + AMCC (memory subsystem)
    var hasIOReport: Bool = false
}

enum ThermalLevel: String {
    case nominal = "Nominal"
    case fair = "Fair"
    case serious = "Serious"
    case critical = "Critical"
}

struct SystemInfo {
    let hostname: String
    let cpuBrand: String       // "Apple M3 Max"
    let eCores: Int
    let pCores: Int
    let gpuCores: Int
    let memoryGB: Int
    let osVersion: String
    var uptime: String = ""
    var memUsedGB: Int = 0     // updated periodically

    nonisolated static func gather() -> SystemInfo {
        func sc(_ name: String) -> String {
            var sz = 0
            guard sysctlbyname(name, nil, &sz, nil, 0) == 0, sz > 0 else { return "?" }
            var buf = [CChar](repeating: 0, count: sz)
            sysctlbyname(name, &buf, &sz, nil, 0)
            return String(cString: buf)
        }
        func scI(_ name: String) -> Int {
            var sz = 0; sysctlbyname(name, nil, &sz, nil, 0)
            if sz == 4 { var v: Int32 = 0; sysctlbyname(name, &v, &sz, nil, 0); return Int(v) }
            if sz == 8 { var v = 0; sysctlbyname(name, &v, &sz, nil, 0); return v }
            return 0
        }

        // GPU cores from IOKit
        var gpuCores = 0
        let matching = IOServiceMatching("AGXAccelerator")
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == kIOReturnSuccess {
            let svc = IOIteratorNext(iter)
            if svc != 0 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                   let dict = props?.takeRetainedValue() as? [String: Any] {
                    gpuCores = dict["gpu-core-count"] as? Int ?? 0
                }
                IOObjectRelease(svc)
            }
            IOObjectRelease(iter)
        }

        return SystemInfo(
            hostname: sc("kern.hostname"),
            cpuBrand: sc("machdep.cpu.brand_string"),
            eCores: scI("hw.perflevel1.logicalcpu"),
            pCores: scI("hw.perflevel0.logicalcpu"),
            gpuCores: gpuCores,
            memoryGB: scI("hw.memsize") / (1024 * 1024 * 1024),
            osVersion: sc("kern.osproductversion")
        )
    }

    mutating func refresh() {
        // Uptime
        var boottime = timeval()
        var sz = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boottime, &sz, nil, 0)
        let s = Int(Date().timeIntervalSince1970) - Int(boottime.tv_sec)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        uptime = d > 0 ? "\(d)d \(h)h \(m)m" : "\(h)h \(m)m"

        // Memory usage
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                _ = host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.internal_page_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        memUsedGB = Int(used / (1024 * 1024 * 1024))
    }
}

// MARK: - Monitor

@Observable
@MainActor
final class SystemMonitor {
    var apps: [AppUsage] = []
    var cores: [CoreUsage] = []
    var power = PowerReading()
    var temps: [TempReading] = []
    var thermalLevel: ThermalLevel = .nominal
    var powerHistory: [Double] = []
    var sysInfo: SystemInfo

    private(set) var eCoreCount: Int = 0
    private(set) var pCoreCount: Int = 0
    private(set) var totalCores: Int = 0

    var helperClient: HelperClient?
    private var helperData: [HelperProcessEntry]?

    private var task: Task<Void, Never>?
    private var prevCPU: [Int32: UInt64] = [:]
    private var prevEnergy: [Int32: UInt64] = [:]
    private var prevTicks: [(u: UInt64, s: UInt64, i: UInt64, n: UInt64)] = []
    private let smc: SMC?
    private let ioReport: IOReportPower?
    private var tempKeys: [(key: String, label: String)] = []
    private let historyMax = 150
    // Process list stability: keep apps visible for N cycles after going inactive
    private var appCache: [String: AppUsage] = [:]
    private var appAge: [String: Int] = [:]  // cycles since last active
    private let maxAge = 5

    init() {
        smc = SMC()
        ioReport = IOReportPower()
        sysInfo = SystemInfo.gather()
        eCoreCount = sysInfo.eCores > 0 ? sysInfo.eCores : 4
        pCoreCount = sysInfo.pCores > 0 ? sysInfo.pCores : 8
        totalCores = eCoreCount + pCoreCount

        // Discover available temperature sensors
        if let smc {
            let candidates: [(String, String)] = [
                ("Tp09", "CPU Die"), ("Tp05", "CPU"), ("Tp01", "CPU Core"),
                ("Tg0P", "GPU"), ("Tg0J", "GPU Die"),
                ("Tm0P", "Memory"), ("Tm0p", "Memory"),
                ("TB0T", "Battery"), ("Ts0S", "SSD"),
                ("Te0P", "Ambient"), ("TW0P", "WiFi"),
            ]
            tempKeys = candidates.compactMap { key, label in
                smc.temp(key) != nil ? (key, label) : nil
            }
        }
    }

    func start(interval: Duration = .seconds(2)) {
        stop()
        sample(dt: 0)
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                sample(dt: interval.seconds)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Sampling

    private func sample(dt: Double) {
        if dt > 0.01 {
            // Fetch helper data asynchronously (fire and forget — uses last result)
            if let helper = helperClient, helper.status == .running {
                Task { helperData = await helper.fetchProcessData() }
            }
            sampleProcs(dt: dt)
        }
        sampleCores()
        samplePower()
        sampleTemps()
        sampleThermal()
        sysInfo.refresh()

        if power.systemW > 0 {
            powerHistory.append(power.systemW)
            if powerHistory.count > historyMax {
                powerHistory.removeFirst(powerHistory.count - historyMax)
            }
        }
    }

    // MARK: - Processes + Energy + Grouping

    /// Unified entry for process data from either local proc_pidinfo or helper
    private struct RawProc {
        let pid: Int32; let uid: UInt32; let cpuTotal: UInt64
        let energyNJ: UInt64; let hasEnergy: Bool
        let threads: Int; let mem: UInt64; let path: String
    }

    private func sampleProcs(dt: Double) {
        // Gather raw process data from helper (all procs) or local (user procs only)
        let raw: [RawProc]
        if let hd = helperData {
            raw = hd.map { e in
                RawProc(pid: e.pid, uid: e.uid,
                        cpuTotal: e.cpuUser &+ e.cpuSystem,
                        energyNJ: e.energyNJ, hasEnergy: e.energyNJ > 0,
                        threads: Int(e.threads), mem: e.memResident, path: e.path)
            }
        } else {
            raw = gatherLocalProcs()
        }

        // Compute deltas and build results
        var newCPU: [Int32: UInt64] = [:]
        var newEnergy: [Int32: UInt64] = [:]
        var results: [ProcUsage] = []

        for e in raw {
            newCPU[e.pid] = e.cpuTotal
            newEnergy[e.pid] = e.energyNJ

            var cpuMs = 0.0
            if let prevC = prevCPU[e.pid], e.cpuTotal >= prevC {
                cpuMs = Double(e.cpuTotal &- prevC) / 1_000_000.0 / dt
            }
            var energyW = 0.0
            if let prevE = prevEnergy[e.pid], e.energyNJ >= prevE, e.energyNJ > 0 {
                energyW = Double(e.energyNJ &- prevE) / (dt * 1_000_000_000.0)
            }
            guard cpuMs > 0.05 || energyW > 0.001 else { continue }

            let name = e.path.isEmpty ? "pid \(e.pid)" : (e.path as NSString).lastPathComponent

            results.append(ProcUsage(
                id: e.pid, name: name,
                appGroup: Self.extractAppName(from: e.path, fallback: name),
                isUserApp: e.uid >= 500,
                cpuMs: cpuMs, energyW: energyW, hasEnergy: e.hasEnergy,
                threads: e.threads, mem: e.mem
            ))
        }

        prevCPU = newCPU
        prevEnergy = newEnergy

        // Group active processes
        var activeGroups: [String: [ProcUsage]] = [:]
        for proc in results { activeGroups[proc.appGroup, default: []].append(proc) }
        let activeIds = Set(activeGroups.keys)

        // Update cache: refresh active apps, age out inactive ones
        for (key, procs) in activeGroups {
            appCache[key] = AppUsage(id: key, procs: procs.sorted { $0.energyW > $1.energyW })
            appAge[key] = 0
        }
        for key in appCache.keys where !activeIds.contains(key) {
            appAge[key, default: 0] += 1
            if appAge[key]! > maxAge {
                appCache.removeValue(forKey: key)
                appAge.removeValue(forKey: key)
            }
            // Stale entries keep their last-known identity but zero rates
        }

        apps = Array(appCache.values)
    }

    /// Gather process data locally via proc_pidinfo (only works for user-owned processes)
    private func gatherLocalProcs() -> [RawProc] {
        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(pidCount))
        let actual = proc_listallpids(&pids, Int32(MemoryLayout<Int32>.size * Int(pidCount)))

        let allInfoSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var result: [RawProc] = []

        for i in 0..<Int(actual) {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var allInfo = proc_taskallinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &allInfo, allInfoSize) == allInfoSize else {
                continue
            }

            var ri = rusage_info_v6()
            let riOk = withUnsafeMutablePointer(to: &ri) { ptr -> Bool in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { buf in
                    proc_pid_rusage(pid, Int32(RUSAGE_INFO_V6), buf)
                } == 0
            }

            pathBuf.withUnsafeMutableBufferPointer { $0.baseAddress!.initialize(repeating: 0, count: $0.count) }
            proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN))
            var path = String(cString: pathBuf)
            if path.isEmpty {
                proc_name(pid, &pathBuf, UInt32(MAXPATHLEN))
                path = String(cString: pathBuf)
            }

            result.append(RawProc(
                pid: pid, uid: allInfo.pbsd.pbi_uid,
                cpuTotal: allInfo.ptinfo.pti_total_user &+ allInfo.ptinfo.pti_total_system,
                energyNJ: riOk ? ri.ri_energy_nj : 0, hasEnergy: riOk,
                threads: Int(allInfo.ptinfo.pti_threadnum),
                mem: allInfo.ptinfo.pti_resident_size, path: path
            ))
        }
        return result
    }

    nonisolated private static func extractAppName(from path: String, fallback: String) -> String {
        guard !path.isEmpty, let dotApp = path.range(of: ".app") else { return fallback }
        let before = path[..<dotApp.lowerBound]
        if let slash = before.lastIndex(of: "/") {
            return String(before[before.index(after: slash)...])
        }
        return String(before)
    }

    // MARK: - Power

    private func samplePower() {
        var reading = PowerReading()

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")
        )
        if service != 0 {
            defer { IOObjectRelease(service) }
            var cfProps: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &cfProps, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = cfProps?.takeRetainedValue() as? [String: Any] {
                reading.onAC = dict["ExternalConnected"] as? Bool ?? false
                reading.batteryPct = dict["CurrentCapacity"] as? Int ?? -1

                let voltage = dict["AppleRawBatteryVoltage"] as? Int ?? 0
                let rawAmp = dict["InstantAmperage"] as? UInt64 ?? 0
                let amperage = Int64(bitPattern: rawAmp)
                reading.batteryW = Double(abs(amperage)) * Double(voltage) / 1_000_000.0

                if let telemetry = dict["PowerTelemetryData"] as? [String: Any] {
                    if let load = telemetry["SystemLoad"] as? Int, load > 0 {
                        reading.systemW = Double(load) / 1000.0
                    }
                    if let dcIn = telemetry["SystemPowerIn"] as? Int, dcIn > 0 {
                        reading.adapterW = Double(dcIn) / 1000.0
                    }
                }

                // Battery time remaining (on battery only)
                if !reading.onAC, reading.systemW > 0.1 {
                    let remainingMah = dict["AppleRawCurrentCapacity"] as? Int ?? 0
                    let remainingWh = Double(remainingMah) * Double(voltage) / 1_000_000.0
                    reading.batteryTimeRemaining = remainingWh / reading.systemW
                }
            }
        }

        // IOReport: CPU/GPU/ANE component power (requires dlopen of private framework)
        if let ioReport, let ir = ioReport.sample(interval: 2.0) {
            reading.cpuW = ir.cpuW
            reading.gpuW = ir.gpuW
            reading.aneW = ir.aneW
            reading.dramW = ir.dramW
            reading.hasIOReport = true
        }

        power = reading
    }

    // MARK: - Temperatures

    private var lastTemps: [String: Float] = [:]  // cache to avoid flickering

    private func sampleTemps() {
        guard let smc else { return }
        for (key, _) in tempKeys {
            if let c = smc.temp(key) {
                lastTemps[key] = c
            }
        }
        temps = tempKeys.compactMap { key, label in
            guard let c = lastTemps[key] else { return nil }
            return TempReading(id: key, label: label, celsius: c)
        }
    }

    // MARK: - Thermal State

    private func sampleThermal() {
        thermalLevel = switch ProcessInfo.processInfo.thermalState {
        case .nominal:  .nominal
        case .fair:     .fair
        case .serious:  .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    // MARK: - CPU Cores

    private func sampleCores() {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numInfo: mach_msg_type_number_t = 0

        guard host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
            &numCPUs, &cpuInfo, &numInfo
        ) == KERN_SUCCESS, let info = cpuInfo else { return }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(numInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }

        var ticks: [(u: UInt64, s: UInt64, i: UInt64, n: UInt64)] = []
        ticks.reserveCapacity(Int(numCPUs))
        var newCores: [CoreUsage] = []
        newCores.reserveCapacity(Int(numCPUs))

        for i in 0..<Int(numCPUs) {
            let off = Int(CPU_STATE_MAX) * i
            let u = UInt64(info[off + Int(CPU_STATE_USER)])
            let s = UInt64(info[off + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(info[off + Int(CPU_STATE_IDLE)])
            let n = UInt64(info[off + Int(CPU_STATE_NICE)])
            ticks.append((u, s, idle, n))

            var usage = 0.0
            if i < prevTicks.count {
                let du = u &- prevTicks[i].u
                let ds = s &- prevTicks[i].s
                let di = idle &- prevTicks[i].i
                let dn = n &- prevTicks[i].n
                let total = du &+ ds &+ di &+ dn
                if total > 0 { usage = Double(du &+ ds &+ dn) / Double(total) }
            }

            newCores.append(CoreUsage(id: i, usage: usage, isEfficiency: i < eCoreCount))
        }

        prevTicks = ticks
        cores = newCores
    }

    // MARK: - Helpers

    nonisolated private static func sysctl(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size {
            var val: Int32 = 0
            guard sysctlbyname(name, &val, &size, nil, 0) == 0 else { return nil }
            return Int(val)
        } else if size == MemoryLayout<Int>.size {
            var val = 0
            guard sysctlbyname(name, &val, &size, nil, 0) == 0 else { return nil }
            return val
        }
        return nil
    }
}

private extension Duration {
    var seconds: Double {
        let (s, atto) = components
        return Double(s) + Double(atto) * 1e-18
    }
}
