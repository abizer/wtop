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
    let clpc = ["CPU Energy": 4.0, "GPU Energy": 0.3, "ANE": 0.0, "DRAM": 0.5, "DCS": 0.25]

    // CLPC wins where present, an idle ANE is a real zero, and the GPU keeps its own live channel.
    #expect(IOReportPower.resolve(energyModel: energyModel, clpc: clpc, energyModelFreezes: true)
        == .init(cpuW: 4, gpuW: 0.2, aneW: 0, dramW: 0.75))

    // Without CLPC a macOS 27 Energy Model is frozen (0) or catching up (a spike): show neither.
    let spike = IOReportPower.Watts(cpu: 700, gpu: 0.2, ane: 3, dram: 90)
    #expect(IOReportPower.resolve(energyModel: spike, clpc: [:], energyModelFreezes: true)
        == .init(cpuW: nil, gpuW: 0.2, aneW: nil, dramW: nil))

    // Before macOS 27 the Energy Model is live and is the only source.
    let live = IOReportPower.Watts(cpu: 5, gpu: 0.2, ane: 0, dram: 1)
    #expect(IOReportPower.resolve(energyModel: live, clpc: [:], energyModelFreezes: false)
        == .init(cpuW: 5, gpuW: 0.2, aneW: 0, dramW: 1))
}

@Test func buildsCLPCReportIDsOnlyForKnownChipsOnMacOS27() throws {
    let m3Max = try #require(CLPCEnergy.channels(bundle: "com.apple.driver.AppleT6031CLPC", osMajor: 27))
    #expect(m3Max.map(\.name) == ["CPU Energy", "GPU Energy", "ANE", "DRAM", "DCS"])
    #expect(m3Max[0].id == 0x0000_0010_d81e_0084)
    #expect(m3Max[4].id == 0x0000_001b_10cb_1f6a)

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
