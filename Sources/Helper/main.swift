/// wtop-helper: On-demand privileged helper for wtop.
///
/// Provides process data for system processes (uid < 500) that the
/// unprivileged app can't query via proc_pidinfo.
/// Exits after 30 seconds of no active XPC connections.

import Foundation
import Darwin

// MARK: - XPC Protocol

@objc protocol HelperProtocol {
    /// Returns process data for ALL processes as a serialized array.
    /// Each entry: [pid, uid, cpuUser, cpuSystem, energy, threads, memResident, pathLength, ...pathBytes]
    /// Encoded as Data for XPC transport.
    func getProcessData(reply: @escaping (Data) -> Void)
}

let machServiceName = "me.abizer.wtop.helper"

// MARK: - Connection tracking + auto-exit

var activeConnections = 0
var idleTimer: Timer?
let idleTimeout: TimeInterval = 30

func connectionOpened() {
    activeConnections += 1
    idleTimer?.invalidate()
    idleTimer = nil
}

func connectionClosed() {
    activeConnections -= 1
    if activeConnections <= 0 {
        activeConnections = 0
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { _ in
            exit(0)
        }
    }
}

// MARK: - Process data encoding

struct ProcessEntry {
    let pid: Int32
    let uid: UInt32
    let cpuUser: UInt64     // nanoseconds
    let cpuSystem: UInt64   // nanoseconds
    let energyNJ: UInt64    // nanojoules
    let threads: Int32
    let memResident: UInt64  // bytes
    let path: String
}

func encodeEntries(_ entries: [ProcessEntry]) -> Data {
    var data = Data()
    // Header: entry count
    var count = UInt32(entries.count)
    data.append(Data(bytes: &count, count: 4))

    for e in entries {
        var pid = e.pid; data.append(Data(bytes: &pid, count: 4))
        var uid = e.uid; data.append(Data(bytes: &uid, count: 4))
        var cu = e.cpuUser; data.append(Data(bytes: &cu, count: 8))
        var cs = e.cpuSystem; data.append(Data(bytes: &cs, count: 8))
        var en = e.energyNJ; data.append(Data(bytes: &en, count: 8))
        var th = e.threads; data.append(Data(bytes: &th, count: 4))
        var mr = e.memResident; data.append(Data(bytes: &mr, count: 8))
        let pathBytes = Array(e.path.utf8)
        var pathLen = UInt16(pathBytes.count)
        data.append(Data(bytes: &pathLen, count: 2))
        data.append(Data(pathBytes))
    }
    return data
}

// MARK: - Implementation

class HelperImpl: NSObject, HelperProtocol {
    func getProcessData(reply: @escaping (Data) -> Void) {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { reply(Data()); return }

        var pids = [Int32](repeating: 0, count: Int(count))
        let actual = proc_listallpids(&pids, Int32(MemoryLayout<Int32>.size * Int(count)))

        var entries: [ProcessEntry] = []
        let allInfoSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))

        for i in 0..<Int(actual) {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var allInfo = proc_taskallinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &allInfo, allInfoSize) == allInfoSize else {
                continue
            }

            let info = allInfo.ptinfo
            let uid = allInfo.pbsd.pbi_uid

            // Energy
            var ri = rusage_info_v6()
            let riOk = withUnsafeMutablePointer(to: &ri) { ptr -> Bool in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { buf in
                    proc_pid_rusage(pid, Int32(RUSAGE_INFO_V6), buf)
                } == 0
            }

            // Path
            pathBuf.withUnsafeMutableBufferPointer { $0.baseAddress!.initialize(repeating: 0, count: $0.count) }
            proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN))
            var path = String(cString: pathBuf)
            if path.isEmpty {
                proc_name(pid, &pathBuf, UInt32(MAXPATHLEN))
                path = String(cString: pathBuf)
            }

            entries.append(ProcessEntry(
                pid: pid,
                uid: uid,
                cpuUser: info.pti_total_user,
                cpuSystem: info.pti_total_system,
                energyNJ: riOk ? ri.ri_energy_nj : 0,
                threads: info.pti_threadnum,
                memResident: info.pti_resident_size,
                path: path
            ))
        }

        reply(encodeEntries(entries))
    }
}

// MARK: - XPC Listener

class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.exportedObject = HelperImpl()

        connectionOpened()
        conn.invalidationHandler = { connectionClosed() }
        conn.interruptionHandler = { connectionClosed() }

        conn.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: machServiceName)
listener.delegate = delegate
listener.resume()

idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { _ in
    exit(0)
}

RunLoop.current.run()
