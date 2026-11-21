import Darwin
import Foundation
import IOKit

// MARK: - Processes

struct ProcUsage: Identifiable, Sendable {
    let id: Int32
    let name: String
    let appGroup: String
    let isUserApp: Bool     // uid ≥ 500
    var cpuMs: Double       // CPU milliseconds per wall-clock second (1000 = one full core)
    /// CPU energy the kernel charged to the process, plus `gpuW`.
    var energyW: Double
    /// The process's share of GPU power: GPU watts split by GPU time. An apportionment,
    /// not a measurement — it assumes every millisecond of GPU time costs the same.
    var gpuW: Double
    let hasEnergy: Bool
    let threads: Int
    let mem: UInt64
}

/// Processes sharing a `.app` bundle, with totals computed once rather than per render.
struct AppUsage: Identifiable, Sendable {
    let id: String
    let procs: [ProcUsage]
    let totalCpuMs: Double
    let totalEnergyW: Double
    let totalGpuW: Double
    let totalMem: UInt64
    let hasEnergy: Bool
    let isUserApp: Bool

    init(id: String, procs: [ProcUsage]) {
        self.id = id
        self.procs = procs
        totalCpuMs = procs.reduce(0) { $0 + $1.cpuMs }
        totalEnergyW = procs.reduce(0) { $0 + $1.energyW }
        totalGpuW = procs.reduce(0) { $0 + $1.gpuW }
        totalMem = procs.reduce(0) { $0 + $1.mem }
        hasEnergy = procs.contains(where: \.hasEnergy)
        isUserApp = procs.first?.isUserApp ?? false
    }

    /// The same app with its rates zeroed — what it looks like once it stops doing work.
    var idle: AppUsage {
        AppUsage(id: id, procs: procs.map { proc in
            var proc = proc
            proc.cpuMs = 0
            proc.energyW = 0
            proc.gpuW = 0
            return proc
        })
    }
}

// MARK: - Hardware readings

struct CoreUsage: Identifiable, Sendable {
    let id: Int
    let usage: Double
    let isEfficiency: Bool
}

struct TempReading: Identifiable, Sendable {
    let id: String   // SMC key
    let label: String
    let celsius: Float
}

struct PowerReading: Sendable {
    var systemW: Double = 0
    var batteryW: Double = 0
    var adapterW: Double = 0
    var onAC: Bool = false
    var batteryPct: Int = -1
    var batteryTimeRemaining: Double?   // hours
    // IOReport SoC component breakdown — nil when a counter exists but isn't reporting
    var cpuW: Double?
    var gpuW: Double?
    var aneW: Double?
    var dramW: Double?         // DRAM + DCS + AMCC (memory subsystem)
    var socOtherW: Double?     // rest of the chip (package total minus the four above)
    var hasIOReport: Bool = false
    /// Display backlight, from the SMC. nil on a Mac without a built-in display.
    var displayW: Double?

    /// Fills what IOReport couldn't with SMC rails that were measured against the CLPC
    /// counters on an M3 Max: `PPSC` tracks DRAM + DCS and `PHPS` the whole package, each
    /// within a few percent across CPU, GPU and memory loads. Other chips may not have them.
    mutating func fillGaps(memoryRailW: Double?, packageRailW: Double?) {
        if dramW == nil { dramW = memoryRailW }
        if socOtherW == nil, let packageRailW, let cpuW, let gpuW, let aneW, let dramW {
            socOtherW = max(0, packageRailW - cpuW - gpuW - aneW - dramW)
        }
    }

    /// System power no sensor accounts for: SSD, radios, the panel's electronics, speakers,
    /// conversion losses. nil unless the whole chip is measured, since otherwise the
    /// remainder would silently include part of it.
    var unattributedW: Double? {
        guard systemW > 0, let cpuW, let gpuW, let aneW, let dramW, let socOtherW else { return nil }
        // The system figure is a slower-moving telemetry value, so a load step can briefly
        // put the parts above the whole.
        return max(0, systemW - cpuW - gpuW - aneW - dramW - socOtherW - (displayW ?? 0))
    }
}

enum ThermalLevel: String, Sendable {
    case nominal = "Nominal"
    case fair = "Fair"
    case serious = "Serious"
    case critical = "Critical"
}

/// Where process data is coming from.
enum HelperStatus: Sendable {
    case checking
    case connected      // privileged helper: every process on the system
    case unavailable    // local fallback: only the user's own processes
}

// MARK: - Static system facts

struct SystemInfo: Sendable {
    let hostname: String
    let cpuBrand: String       // "Apple M3 Max"
    let eCores: Int
    let pCores: Int
    let gpuCores: Int
    let memoryGB: Int
    let osVersion: String

    static let current = SystemInfo()

    private init() {
        hostname = Self.string("kern.hostname")
        cpuBrand = Self.string("machdep.cpu.brand_string")
        eCores = Self.integer("hw.perflevel1.logicalcpu")
        pCores = Self.integer("hw.perflevel0.logicalcpu")
        gpuCores = Self.gpuCoreCount()
        memoryGB = Self.integer("hw.memsize") / (1 << 30)
        osVersion = Self.string("kern.osproductversion")
    }

    private static func string(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Apple Silicon reports most integers as Int32, a few (hw.memsize) as Int64.
    private static func integer(_ name: String) -> Int {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return 0 }
        switch size {
        case 4:
            var value: Int32 = 0
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
        case 8:
            var value: Int64 = 0
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
        default:
            return 0
        }
    }

    private static func gpuCoreCount() -> Int {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        let count = IORegistryEntryCreateCFProperty(
            service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
        return count as? Int ?? 0
    }
}

// MARK: - Units

extension Duration {
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
