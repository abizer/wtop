import Foundation
import Testing
@testable import wtop

@Test(arguments: [
    ("/Applications/Safari.app/Contents/MacOS/Safari", "Safari"),
    ("/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper", "Foo"),
    ("/Applications/Bare.app", "Bare"),
    // ".app" inside "com.apple" is not a bundle
    ("/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU", nil),
    ("/usr/libexec/trustd", nil),
    ("", nil),
] as [(String, String?)])
func groupsProcessesByOutermostAppBundle(path: String, expected: String?) {
    #expect(Sampler.appName(inPath: path) == expected)
}

/// Bytes captured from an M3 Max: `flt ` keys are little-endian floats. Reading them as
/// sp78 yields 102.5 °C for a 63.9 °C SSD — plausible-looking, and wrong.
@Test func decodesSMCTemperaturesByDeclaredType() throws {
    let ssd = try #require(SMC.celsius(bytes: (102, 127, 127, 66), type: "flt "))
    #expect(abs(ssd - 63.874) < 0.01)
    #expect(SMC.celsius(bytes: (0x1E, 0x80, 0, 0), type: "sp78") == 30.5)
    #expect(SMC.celsius(bytes: (0xFF, 0x00, 0, 0), type: "sp78") == nil)       // -1 °C: implausible
    #expect(SMC.celsius(bytes: (0, 0, 0x80, 0x7F), type: "flt ") == nil)       // +infinity
    #expect(SMC.celsius(bytes: (102, 127, 127, 66), type: "ui32") == nil)      // not a temperature
}

/// These measure this very process, so they must not run alongside each other.
/// Skipped on CI: hosted runners are VMs with no energy counters or IOReport power channels.
@Test func readsPowerManagerComponentsFromCLPCOnMacOS27() {
    let energyModel = IOReportPower.Watts(cpu: 0, gpu: 0.2, ane: 0, dram: 0)
    let clpc = ["CPU Energy": 4.0, "GPU Energy": 0.25, "ANE": 0.0, "DRAM": 0.5, "DCS": 0.25, "Package Energy": 6.5]

    // CLPC wins where present, an idle ANE is a real zero, and the GPU keeps its own live channel.
    // The rest of the chip is the package minus CLPC's own five figures: 6.5 − 5 = 1.5.
    #expect(IOReportPower.resolve(energyModel: energyModel, clpc: clpc, energyModelFreezes: true)
        == .init(cpuW: 4, gpuW: 0.2, aneW: 0, dramW: 0.75, socOtherW: 1.5))

    // Without CLPC a macOS 27 Energy Model is frozen (0) or catching up (a spike): show neither.
    let spike = IOReportPower.Watts(cpu: 700, gpu: 0.2, ane: 3, dram: 90)
    #expect(IOReportPower.resolve(energyModel: spike, clpc: [:], energyModelFreezes: true)
        == .init(cpuW: nil, gpuW: 0.2, aneW: nil, dramW: nil))

    // Before macOS 27 the Energy Model is live and is the only source.
    let live = IOReportPower.Watts(cpu: 5, gpu: 0.2, ane: 0, dram: 1)
    #expect(IOReportPower.resolve(energyModel: live, clpc: [:], energyModelFreezes: false)
        == .init(cpuW: 5, gpuW: 0.2, aneW: 0, dramW: 1))
}

@Test func theBreakdownAddsUpToTheSystemFigure() {
    var power = PowerReading(systemW: 20, cpuW: 2, gpuW: 0.5, aneW: 0, dramW: 1, socOtherW: 1.5, displayW: 10)
    #expect(power.unattributedW == 5)

    // No built-in display: nothing to subtract for it.
    power.displayW = nil
    #expect(power.unattributedW == 15)

    // The system figure lags a load step; the remainder never goes negative.
    power.cpuW = 40
    #expect(power.unattributedW == 0)

    // With part of the chip unmeasured the remainder would hide it, so there is none.
    power.socOtherW = nil
    #expect(power.unattributedW == nil)
}

@Test func fillsMissingMemoryAndPackageFromSMCRails() {
    // Nothing from IOReport for memory or the package (chip missing from the CLPC table, or an older OS).
    var power = PowerReading(cpuW: 2, gpuW: 0.5, aneW: 0)
    power.fillGaps(memoryRailW: 1, packageRailW: 5)
    #expect(power.dramW == 1)
    #expect(power.socOtherW == 1.5)

    // IOReport's own figures are never overwritten.
    var measured = PowerReading(cpuW: 2, gpuW: 0.5, aneW: 0, dramW: 0.8, socOtherW: 1.2)
    measured.fillGaps(memoryRailW: 1, packageRailW: 50)
    #expect(measured.dramW == 0.8)
    #expect(measured.socOtherW == 1.2)

    // Without a CPU figure the package can't be split, so there is no remainder to show.
    var noCPU = PowerReading(gpuW: 0.5)
    noCPU.fillGaps(memoryRailW: 1, packageRailW: 5)
    #expect(noCPU.dramW == 1)
    #expect(noCPU.socOtherW == nil)
}

@Test func splitsGPUPowerByGPUTime() {
    let shares = GPUClients.shares(
        previous: [1: 1_000, 2: 5_000, 3: 9_000],
        current: [1: 4_000, 2: 5_000, 3: 2_000, 4: 1_000]
    )
    // pid 1 used 3000 ns and the new pid 4 used 1000; pid 2 was idle and pid 3 went
    // backwards (it closed a client), so neither gets a share.
    #expect(shares == [1: 0.75, 4: 0.25])
    #expect(GPUClients.shares(previous: [1: 10], current: [1: 10]).isEmpty)

    #expect(GPUClients.pid(fromCreator: "pid 631, WindowServer") == 631)
    #expect(GPUClients.pid(fromCreator: "WindowServer") == nil)
    #expect(GPUClients.pid(fromCreator: nil) == nil)
}

@Test func buildsCLPCReportIDsOnlyForKnownChipsOnMacOS27() throws {
    let m3Max = try #require(CLPCEnergy.channels(bundle: "com.apple.driver.AppleT6031CLPC", osMajor: 27))
    #expect(m3Max.map(\.name) == ["CPU Energy", "GPU Energy", "ANE", "DRAM", "DCS", "Package Energy"])
    #expect(m3Max[0].id == 0x0000_0010_d81e_0084)
    #expect(m3Max[4].id == 0x0000_001b_10cb_1f6a)
    #expect(m3Max[5].id == 0x0000_0009_fc3f_ce99)

    #expect(CLPCEnergy.channels(bundle: "com.apple.driver.AppleT6031CLPC", osMajor: 26) == nil)
    #expect(CLPCEnergy.channels(bundle: "com.apple.driver.AppleT9999CLPC", osMajor: 27) == nil)
}

@Suite(.serialized,.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
struct LiveSampling {

/// Pins one core for a second and checks the sampler reports roughly one core's worth of
/// CPU for this process. Guards the unit conversion (Mach ticks, not nanoseconds) and the
/// use of measured rather than nominal elapsed time.
@Test func reportsRealCPUTimeForABusyProcess() async throws {
    let sampler = Sampler(eCoreCount: SystemInfo.current.eCores)
    _ = await sampler.sample()

    let deadline = ContinuousClock.now + .seconds(1)
    var spin = 0.0
    while ContinuousClock.now < deadline { spin += sin(spin + 1) }

    let snapshot = await sampler.sample()
    let pid = ProcessInfo.processInfo.processIdentifier
    let me = try #require(snapshot.apps.flatMap(\.procs).first { $0.id == pid })
    #expect((700...1500).contains(me.cpuMs), "expected ~1000 ms/s for one pinned core, got \(me.cpuMs)")
    #expect(me.energyW > 0.05, "a pinned core should cost real power, got \(me.energyW) W")

    #expect(snapshot.cores.count == SystemInfo.current.eCores + SystemInfo.current.pCores)
    #expect(snapshot.cores.allSatisfy { (0...1).contains($0.usage) })
    #expect(snapshot.power.hasIOReport)
    // Absent only on a chip/OS pair with no live counter; never a false zero or a catch-up spike.
    if let cpuW = snapshot.power.cpuW {
        #expect((0.5...200).contains(cpuW), "implausible CPU power with a core pinned: \(cpuW) W")
    }
}

/// The same workload must read the same regardless of how far apart the samples are.
@Test func ratesDoNotDependOnTheSamplingInterval() async throws {
    let sampler = Sampler(eCoreCount: SystemInfo.current.eCores)
    let pid = ProcessInfo.processInfo.processIdentifier
    var readings: [Double] = []

    _ = await sampler.sample()
    for milliseconds in [300, 900] {
        let deadline = ContinuousClock.now + .milliseconds(milliseconds)
        var spin = 0.0
        while ContinuousClock.now < deadline { spin += sin(spin + 1) }
        let snapshot = await sampler.sample()
        readings.append(try #require(snapshot.apps.flatMap(\.procs).first { $0.id == pid }).cpuMs)
    }
    #expect(abs(readings[0] - readings[1]) < 350, "rates diverged across intervals: \(readings)")
}

}
