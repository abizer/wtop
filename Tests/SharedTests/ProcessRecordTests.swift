import Foundation
import Testing
@testable import WtopShared

private let sample = [
    ProcessRecord(pid: 1, uid: 0, cpuUser: 10, cpuSystem: 20, energyNJ: 30,
                  threads: 4, memResident: 4096, path: "/sbin/launchd"),
    ProcessRecord(pid: 501, uid: 501, cpuUser: .max, cpuSystem: 0, energyNJ: 0,
                  threads: 1, memResident: 0, path: ""),
    ProcessRecord(pid: 9000, uid: 501, cpuUser: 1, cpuSystem: 2, energyNJ: 3,
                  threads: 12, memResident: 1 << 33, path: "/Applications/Café ☕.app/Contents/MacOS/Café"),
]

@Test func roundTripsEveryField() {
    #expect(ProcessRecord.decode(ProcessRecord.encode(sample)) == sample)
}

/// Byte-for-byte what the v0.4 helper emits, so a still-installed old helper keeps working.
@Test func matchesTheFrozenWireLayout() {
    let record = ProcessRecord(pid: 0x0102_0304, uid: 0x0506_0708, cpuUser: 1, cpuSystem: 2,
                               energyNJ: 3, threads: 4, memResident: 5, path: "ab")
    var expected: [UInt8] = [1, 0, 0, 0]                    // count
    expected += [4, 3, 2, 1]                                // pid
    expected += [8, 7, 6, 5]                                // uid
    expected += [1, 0, 0, 0, 0, 0, 0, 0]                    // cpuUser
    expected += [2, 0, 0, 0, 0, 0, 0, 0]                    // cpuSystem
    expected += [3, 0, 0, 0, 0, 0, 0, 0]                    // energyNJ
    expected += [4, 0, 0, 0]                                // threads
    expected += [5, 0, 0, 0, 0, 0, 0, 0]                    // memResident
    expected += [2, 0]                                      // pathLength
    expected += Array("ab".utf8)
    #expect(Array(ProcessRecord.encode([record])) == expected)
}

@Test func rejectsEmptyAndTruncatedPayloads() {
    let encoded = ProcessRecord.encode(sample)
    #expect(ProcessRecord.decode(Data()) == nil)
    #expect(ProcessRecord.decode(ProcessRecord.encode([])) == nil)
    for length in 0..<encoded.count {
        #expect(ProcessRecord.decode(encoded.prefix(length)) == nil, "accepted a \(length)-byte prefix")
    }
}

@Test func decodesASliceWithNonZeroStartIndex() {
    let padded = Data([0xFF, 0xFF, 0xFF]) + ProcessRecord.encode(sample)
    #expect(ProcessRecord.decode(padded.dropFirst(3)) == sample)
}

@Test func snapshotSeesThisProcess() throws {
    let me = try #require(ProcessRecord.snapshot().first { $0.pid == getpid() })
    #expect(me.uid == getuid())
    #expect(me.threads > 0)
    #expect(me.memResident > 0)
    #expect(!me.path.isEmpty)
}
