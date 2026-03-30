import Foundation

/// Reads CPU/GPU/ANE/DRAM power via IOReport private framework (dlopen'd from /usr/lib/libIOReport.dylib).
/// Returns nil from init if the framework isn't available.
final class IOReportPower: @unchecked Sendable {

    private typealias CopyChFn   = @convention(c) (CFString, UnsafeRawPointer?, CFIndex, CFIndex, CFIndex) -> UnsafeRawPointer?
    private typealias SubFn      = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer, UnsafeMutableRawPointer?, CFIndex, UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias SampleFn   = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias DeltaFn    = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias IntValFn   = @convention(c) (UnsafeRawPointer, CFIndex) -> Int64
    private typealias StrFn      = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFString>?
    private typealias IterateFn  = @convention(c) (UnsafeRawPointer, @convention(block) (UnsafeRawPointer) -> Int32) -> Int32

    private let createSample: SampleFn
    private let createDelta: DeltaFn
    private let getInt: IntValFn
    private let getName: StrFn
    private let getUnit: StrFn
    private let iterate: IterateFn

    private let subscription: UnsafeRawPointer
    private let subbedChannels: UnsafeRawPointer
    private var prevSample: UnsafeRawPointer?

    struct Reading {
        var cpuW: Double = 0
        var gpuW: Double = 0
        var aneW: Double = 0
        var dramW: Double = 0
        var otherW: Double = 0
    }

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }

        guard let p1 = dlsym(handle, "IOReportCopyChannelsInGroup"),
              let p2 = dlsym(handle, "IOReportCreateSubscription"),
              let p3 = dlsym(handle, "IOReportCreateSamples"),
              let p4 = dlsym(handle, "IOReportCreateSamplesDelta"),
              let p5 = dlsym(handle, "IOReportSimpleGetIntegerValue"),
              let p6 = dlsym(handle, "IOReportChannelGetChannelName"),
              let p7 = dlsym(handle, "IOReportIterate"),
              let p8 = dlsym(handle, "IOReportChannelGetUnitLabel")
        else { return nil }

        let copyCh = unsafeBitCast(p1, to: CopyChFn.self)
        let createSub = unsafeBitCast(p2, to: SubFn.self)
        createSample = unsafeBitCast(p3, to: SampleFn.self)
        createDelta = unsafeBitCast(p4, to: DeltaFn.self)
        getInt = unsafeBitCast(p5, to: IntValFn.self)
        getName = unsafeBitCast(p6, to: StrFn.self)
        iterate = unsafeBitCast(p7, to: IterateFn.self)
        getUnit = unsafeBitCast(p8, to: StrFn.self)

        guard let immutableCh = copyCh("Energy Model" as CFString, nil, 0, 0, 0) else { return nil }
        let cfDict = unsafeBitCast(immutableCh, to: CFDictionary.self)
        guard let mutableCh = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(cfDict), cfDict) else {
            return nil
        }
        let mutablePtr = unsafeBitCast(mutableCh, to: UnsafeRawPointer.self)

        var subbedPtr: UnsafeRawPointer? = nil
        guard let sub = createSub(nil, mutablePtr, &subbedPtr, 0, nil) else { return nil }
        subscription = sub
        subbedChannels = subbedPtr ?? mutablePtr

        prevSample = createSample(sub, subbedChannels, nil)
        guard prevSample != nil else { return nil }
    }

    /// Take a new sample and compute delta watts since last call.
    func sample(interval: Double) -> Reading? {
        guard let prev = prevSample else { return nil }
        guard let curr = createSample(subscription, subbedChannels, nil) else { return nil }
        defer { prevSample = curr }

        guard let delta = createDelta(prev, curr, nil) else { return nil }
        guard interval > 0.01 else { return nil }

        var reading = Reading()

        _ = iterate(delta) { [getName, getInt, getUnit] ch in
            let val = getInt(ch, 0)
            guard val > 0 else { return 0 }

            let name = (getName(ch)?.takeUnretainedValue() as String?) ?? ""

            // Unit-aware scaling: channels report in mJ, uJ, or nJ
            let unit = (getUnit(ch)?.takeUnretainedValue() as String?) ?? "nJ"
            let divisor: Double = switch unit {
            case "mJ": 1e3
            case "uJ": 1e6
            default:   1e9  // nJ
            }
            let watts = Double(val) / divisor / interval

            // Aggregate channels (suffix " Energy") — use directly, skip per-core to avoid double-counting
            if name.hasSuffix(" Energy") {
                if name.hasPrefix("CPU") || name.contains("CPU") { reading.cpuW += watts }
                else if name.hasPrefix("GPU")                     { reading.gpuW += watts }
                return 0
            }

            // Per-component channels (no aggregate available)
            if name.hasPrefix("ANE")  { reading.aneW += watts }
            else if name.hasPrefix("DRAM") || name.hasPrefix("DCS") || name.hasPrefix("AMCC") { reading.dramW += watts }
            // Skip individual CPU/GPU cores (covered by aggregates above)
            else if name.contains("CPU") || name.hasPrefix("EACC") || name.hasPrefix("PACC") { /* skip */ }
            else if name.hasPrefix("GPU") { /* skip */ }
            else if name.hasPrefix("DISP") || name.hasPrefix("ISP") || name.hasPrefix("AVE") || name.hasPrefix("MSR") {
                reading.otherW += watts
            }
            return 0
        }

        return reading
    }
}
