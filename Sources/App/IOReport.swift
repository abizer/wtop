import Foundation

/// Reads CPU/GPU/ANE/DRAM power via IOReport private framework (dlopen'd from /usr/lib/libIOReport.dylib).
/// Returns nil from init if the framework isn't available.
final class IOReportPower {

    private typealias CopyChFn   = @convention(c) (CFString, UnsafeRawPointer?, CFIndex, CFIndex, CFIndex) -> UnsafeRawPointer?
    private typealias SubFn      = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer, UnsafeMutablePointer<UnsafeRawPointer?>, CFIndex, UnsafeRawPointer?) -> UnsafeRawPointer?
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
    private let getGroup: StrFn
    private let iterate: IterateFn

    private let subscription: UnsafeRawPointer
    private let subbedChannels: UnsafeRawPointer
    private var prevSample: UnsafeRawPointer
    private var prevTime: ContinuousClock.Instant

    /// Watts per component; nil where no trustworthy source exists.
    struct Reading: Equatable {
        var cpuW: Double?
        var gpuW: Double?
        var aneW: Double?
        var dramW: Double?
    }

    /// Watts seen in one sample from one source, keyed by component. A component the source
    /// has no channel for is 0 in `energyModel` (indistinguishable from idle there) and
    /// absent from `clpc`.
    struct Watts: Equatable {
        var cpu = 0.0, gpu = 0.0, ane = 0.0, dram = 0.0
    }

    /// Picks a source for each component.
    ///
    /// The GPU driver publishes its own `Energy Model` channel, which is always live. CPU, ANE
    /// and DRAM come from the power manager, whose channels freeze on macOS 27 and then catch
    /// up in one jump — so there they are read from CLPC or not at all: a frozen counter reads
    /// as a false zero and its catch-up as a spike of hundreds of watts.
    static func resolve(energyModel: Watts, clpc: [String: Double], energyModelFreezes: Bool) -> Reading {
        var reading = Reading(gpuW: energyModel.gpu)
        if let cpu = clpc[CLPCEnergy.cpu] {
            reading.cpuW = cpu
            reading.aneW = clpc[CLPCEnergy.ane]
            if let dram = clpc[CLPCEnergy.dram] { reading.dramW = dram + (clpc[CLPCEnergy.dcs] ?? 0) }
        } else if !energyModelFreezes {
            reading.cpuW = energyModel.cpu
            reading.aneW = energyModel.ane
            reading.dramW = energyModel.dram
        }
        return reading
    }

    private let energyModelFreezes = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }

        guard let p1 = dlsym(handle, "IOReportCopyChannelsInGroup"),
              let p2 = dlsym(handle, "IOReportCreateSubscription"),
              let p3 = dlsym(handle, "IOReportCreateSamples"),
              let p4 = dlsym(handle, "IOReportCreateSamplesDelta"),
              let p5 = dlsym(handle, "IOReportSimpleGetIntegerValue"),
              let p6 = dlsym(handle, "IOReportChannelGetChannelName"),
              let p7 = dlsym(handle, "IOReportIterate"),
              let p8 = dlsym(handle, "IOReportChannelGetUnitLabel"),
              let p9 = dlsym(handle, "IOReportChannelGetGroup")
        else { return nil }

        let copyCh = unsafeBitCast(p1, to: CopyChFn.self)
        let createSub = unsafeBitCast(p2, to: SubFn.self)
        let createSample = unsafeBitCast(p3, to: SampleFn.self)
        self.createSample = createSample
        createDelta = unsafeBitCast(p4, to: DeltaFn.self)
        getInt = unsafeBitCast(p5, to: IntValFn.self)
        getName = unsafeBitCast(p6, to: StrFn.self)
        iterate = unsafeBitCast(p7, to: IterateFn.self)
        getUnit = unsafeBitCast(p8, to: StrFn.self)
        getGroup = unsafeBitCast(p9, to: StrFn.self)

        guard let copied = copyCh("Energy Model" as CFString, nil, 0, 0, 0) else { return nil }
        let energyModel = Unmanaged<CFDictionary>.fromOpaque(copied).takeRetainedValue() as NSDictionary
        let published = energyModel["IOReportChannels"] as? [Any] ?? []

        /// Subscribes to the published channels plus `extra`, and takes the first sample.
        /// The request and the subscription live as long as the process, so neither is released.
        func subscribe(adding extra: [Any]) -> (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer)? {
            // IOReportCopyChannelsInGroup returns an immutable dictionary; subscribing needs a mutable one.
            let request = NSMutableDictionary(dictionary: energyModel)
            request["IOReportChannels"] = published + extra
            let requestPtr = UnsafeRawPointer(Unmanaged.passRetained(request).toOpaque())
            var subbed: UnsafeRawPointer?
            guard let sub = createSub(nil, requestPtr, &subbed, 0, nil),
                  let first = createSample(sub, subbed ?? requestPtr, nil)
            else { return nil }
            return (sub, subbed ?? requestPtr, first)
        }

        // CLPC counters are named by hard-coded report IDs; if an OS update invalidates them
        // the subscription is refused, and the published channels still work on their own.
        let clpc = CLPCEnergy.subscriptionChannels()
        guard let (sub, channels, first) = (clpc.isEmpty ? nil : subscribe(adding: clpc)) ?? subscribe(adding: [])
        else { return nil }
        subscription = sub
        subbedChannels = channels
        prevSample = first
        prevTime = .now
    }

    /// Average watts per component since the previous call.
    /// The channels count joules, so the divisor is the time that really passed between samples.
    func sample() -> Reading? {
        let prev = prevSample
        guard let curr = createSample(subscription, subbedChannels, nil) else { return nil }
        let now = ContinuousClock.now
        let interval = (now - prevTime).inSeconds
        // IOReportCreateSamples/CreateSamplesDelta follow the CF Create rule (+1 retained);
        // held as UnsafeRawPointer they're invisible to ARC and must be CFReleased here.
        defer {
            Unmanaged<AnyObject>.fromOpaque(prev).release()
            prevSample = curr
            prevTime = now
        }

        guard let delta = createDelta(prev, curr, nil) else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(delta).release() }
        guard interval > 0.01 else { return nil }

        var energyModel = Watts()
        var clpc: [String: Double] = [:]

        _ = iterate(delta) { [getName, getInt, getUnit, getGroup] ch in
            // A negative delta is IOReport's invalid-value sentinel or a counter reset.
            let val = getInt(ch, 0)
            guard val >= 0 else { return 0 }

            let name = (getName(ch)?.takeUnretainedValue() as String?) ?? ""

            // Unit-aware scaling: channels report in mJ, uJ, or nJ
            let unit = (getUnit(ch)?.takeUnretainedValue() as String?) ?? "nJ"
            let divisor: Double = switch unit.trimmingCharacters(in: .whitespaces) {
            case "mJ": 1e3
            case "uJ": 1e6
            default:   1e9  // nJ
            }
            let watts = Double(val) / divisor / interval

            if (getGroup(ch)?.takeUnretainedValue() as String?) == CLPCEnergy.group {
                clpc[name] = watts
                return 0
            }

            // Aggregate channels (suffix " Energy") — use directly, skip per-core to avoid double-counting
            if name.hasSuffix(" Energy") {
                if name.contains("CPU")      { energyModel.cpu += watts }
                else if name.hasPrefix("GPU") { energyModel.gpu += watts }
                return 0
            }

            // Per-component channels (no aggregate available)
            if name.hasPrefix("ANE")  { energyModel.ane += watts }
            else if name.hasPrefix("DRAM") || name.hasPrefix("DCS") || name.hasPrefix("AMCC") { energyModel.dram += watts }
            // Everything else is either a per-core channel the aggregates already cover
            // or a peripheral (DISP, ISP, AVE, MSR) that has no card in the UI.
            return 0
        }

        return Self.resolve(energyModel: energyModel, clpc: clpc, energyModelFreezes: energyModelFreezes)
    }
}
