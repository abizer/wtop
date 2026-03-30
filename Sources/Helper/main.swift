/// wtop-helper: On-demand privileged helper for wtop.
///
/// Launched by launchd when the app connects to its Mach service.
/// Exits automatically after 30 seconds of no active XPC connections.
/// Never runs persistently — only alive while wtop.app is open.

import Foundation
import Darwin

// MARK: - XPC Protocol

@objc protocol HelperProtocol {
    func getAllProcessEnergy(reply: @escaping ([Int32: UInt64]) -> Void)
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
        // Start countdown — exit if no new connections within timeout
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { _ in
            exit(0)
        }
    }
}

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

// Start idle timer immediately — exit if nobody connects within 30s
idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { _ in
    exit(0)
}

RunLoop.current.run()
