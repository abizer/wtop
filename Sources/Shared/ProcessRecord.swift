import Darwin
import Foundation

/// One process's cumulative counters, exactly as the kernel reports them.
///
/// Rates (watts, CPU ms/s) are the consumer's job: diff two records for the
/// same pid and divide by the time between them.
public struct ProcessRecord: Sendable, Equatable {
    public var pid: Int32
    public var uid: UInt32
    /// Cumulative CPU time in **Mach absolute time units**, not nanoseconds.
    /// On Apple Silicon one unit is 125/3 ns — scale with `mach_timebase_info`.
    public var cpuUser: UInt64
    public var cpuSystem: UInt64
    /// Cumulative energy in nanojoules; 0 when the kernel wouldn't say.
    public var energyNJ: UInt64
    public var threads: Int32
    public var memResident: UInt64
    /// Executable path, or the bare process name when the path is unavailable.
    public var path: String

    public init(pid: Int32, uid: UInt32, cpuUser: UInt64, cpuSystem: UInt64,
                energyNJ: UInt64, threads: Int32, memResident: UInt64, path: String) {
        self.pid = pid; self.uid = uid
        self.cpuUser = cpuUser; self.cpuSystem = cpuSystem
        self.energyNJ = energyNJ; self.threads = threads
        self.memResident = memResident; self.path = path
    }
}

// MARK: - Reading the process table

extension ProcessRecord {
    /// Every process the caller is allowed to inspect: all of them as root,
    /// only the caller's own as an ordinary user.
    public static func snapshot() -> [ProcessRecord] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, Int32(MemoryLayout<Int32>.stride * pids.count))
        guard count > 0 else { return [] }

        let infoSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        var nameBuffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        var records: [ProcessRecord] = []
        records.reserveCapacity(Int(count))

        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_taskallinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, infoSize) == infoSize else { continue }

            var usage = rusage_info_v6()
            let hasUsage = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) == 0
                }
            }

            var length = proc_pidpath(pid, &nameBuffer, UInt32(nameBuffer.count))
            if length <= 0 { length = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) }
            let path = String(decoding: nameBuffer.prefix(Int(max(length, 0))), as: UTF8.self)

            records.append(ProcessRecord(
                pid: pid,
                uid: info.pbsd.pbi_uid,
                cpuUser: info.ptinfo.pti_total_user,
                cpuSystem: info.ptinfo.pti_total_system,
                energyNJ: hasUsage ? usage.ri_energy_nj : 0,
                threads: info.ptinfo.pti_threadnum,
                memResident: info.ptinfo.pti_resident_size,
                path: path
            ))
        }
        return records
    }
}

// MARK: - Wire format

/// Little-endian, unaligned:
///
///     UInt32 count
///     count × { Int32 pid, UInt32 uid, UInt64 cpuUser, UInt64 cpuSystem, UInt64 energyNJ,
///               Int32 threads, UInt64 memResident, UInt16 pathLength, UTF-8 path }
///
/// The layout is frozen: an installed helper is only replaced when the user
/// reinstalls it, so old helpers and new apps (and vice versa) must keep agreeing.
extension ProcessRecord {
    private static let fixedSize = 4 + 4 + 8 + 8 + 8 + 4 + 8 + 2

    public static func encode(_ records: [ProcessRecord]) -> Data {
        var data = Data(capacity: 4 + records.count * (fixedSize + 80))
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        put(UInt32(records.count))
        for record in records {
            let path = record.path.utf8.prefix(Int(UInt16.max))
            put(record.pid)
            put(record.uid)
            put(record.cpuUser)
            put(record.cpuSystem)
            put(record.energyNJ)
            put(record.threads)
            put(record.memResident)
            put(UInt16(path.count))
            data.append(contentsOf: path)
        }
        return data
    }

    /// Returns nil for anything that isn't a complete, well-formed payload —
    /// a short read must never be mistaken for "no processes".
    public static func decode(_ data: Data) -> [ProcessRecord]? {
        data.withUnsafeBytes { bytes -> [ProcessRecord]? in
            var offset = 0
            func take<T: FixedWidthInteger>(_: T.Type) -> T? {
                let size = MemoryLayout<T>.size
                guard bytes.count - offset >= size else { return nil }
                defer { offset += size }
                return T(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: T.self))
            }

            guard let count = take(UInt32.self), count > 0 else { return nil }
            var records: [ProcessRecord] = []
            records.reserveCapacity(min(Int(count), bytes.count / fixedSize))

            for _ in 0..<count {
                guard let pid = take(Int32.self),
                      let uid = take(UInt32.self),
                      let cpuUser = take(UInt64.self),
                      let cpuSystem = take(UInt64.self),
                      let energyNJ = take(UInt64.self),
                      let threads = take(Int32.self),
                      let memResident = take(UInt64.self),
                      let pathLength = take(UInt16.self).map(Int.init),
                      bytes.count - offset >= pathLength
                else { return nil }

                let path = String(decoding: bytes[offset..<offset + pathLength], as: UTF8.self)
                offset += pathLength
                records.append(ProcessRecord(
                    pid: pid, uid: uid, cpuUser: cpuUser, cpuSystem: cpuSystem,
                    energyNJ: energyNJ, threads: threads, memResident: memResident, path: path
                ))
            }
            return records
        }
    }
}
