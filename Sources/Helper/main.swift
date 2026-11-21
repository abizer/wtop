/// wtop-helper: on-demand privileged helper for wtop.
///
/// Reads the process table as root, because `proc_pidinfo` won't describe
/// system processes (uid < 500) to an ordinary user. launchd starts it when
/// the app first connects; it exits once nobody has been connected for 30s.

import Foundation
import WtopShared

final class HelperService: NSObject, HelperProtocol {
    func getProcessData(reply: @escaping @Sendable (Data) -> Void) {
        reply(ProcessRecord.encode(ProcessRecord.snapshot()))
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let idle = IdleTimer(timeout: .seconds(30)) { exit(0) }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService()

        // Invalidation is the one callback guaranteed to fire exactly once per connection.
        idle.connectionOpened()
        connection.invalidationHandler = { [idle] in idle.connectionClosed() }

        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
listener.resume()

dispatchMain()
