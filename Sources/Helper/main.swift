/// wtop-helper: Privileged helper daemon for wtop.
///
/// Runs as root via SMAppService.daemon(). Exposes energy data for
/// system processes over XPC that the unprivileged app can't access.
///
/// Installed to /Library/PrivilegedHelperTools/ by macOS when the user
/// approves the daemon in System Settings > Login Items.

import Foundation
import Darwin

// MARK: - XPC Protocol (duplicated from Shared — SPM can't share across exec targets easily)

@objc protocol HelperProtocol {
    func getAllProcessEnergy(reply: @escaping ([Int32: UInt64]) -> Void)
}

let machServiceName = "me.abizer.wtop.helper"

// MARK: - Implementation

class HelperImpl: NSObject, HelperProtocol {
    func getAllProcessEnergy(reply: @escaping ([Int32: UInt64]) -> Void) {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { reply([:]); return }

        var pids = [Int32](repeating: 0, count: Int(count))
        let actual = proc_listallpids(&pids, Int32(MemoryLayout<Int32>.size * Int(count)))

        var results: [Int32: UInt64] = [:]
        results.reserveCapacity(Int(actual))

        for i in 0..<Int(actual) {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var ri = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &ri) { ptr -> Bool in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { buf in
                    proc_pid_rusage(pid, Int32(RUSAGE_INFO_V6), buf)
                } == 0
            }
            if ok, ri.ri_energy_nj > 0 {
                results[pid] = ri.ri_energy_nj
            }
        }

        reply(results)
    }
}

// MARK: - XPC Listener

class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // TODO: When Developer ID signing is available, validate the client:
        // conn.setCodeSigningRequirement(
        //     "identifier \"me.abizer.wtop\" and anchor apple generic " +
        //     "and certificate leaf[subject.OU] = \"YOUR_TEAM_ID\""
        // )

        conn.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.exportedObject = HelperImpl()
        conn.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
