import Foundation
import WtopShared

/// Connection to the privileged wtop-helper daemon.
///
/// There is no separate "is it installed?" probe: every fetch is the probe.
/// A failure backs off for a few seconds and then tries again, so a helper
/// installed (or restarted) while the app is open is picked up on its own.
actor HelperClient {
    private var connection: NSXPCConnection?
    private var connectionID = 0
    private var retryAt = ContinuousClock.now
    private let retryDelay: Duration = .seconds(10)

    /// Every process on the system, or nil when the helper can't be reached.
    func processes() async -> [ProcessRecord]? {
        guard ContinuousClock.now >= retryAt else { return nil }

        let connection = self.connection ?? connect()
        // NSXPC calls exactly one of the two blocks, exactly once.
        let payload: Data? = await withCheckedContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                continuation.resume(returning: nil)
            }
            guard let helper = proxy as? HelperProtocol else {
                continuation.resume(returning: nil)
                return
            }
            helper.getProcessData { continuation.resume(returning: $0) }
        }

        guard let payload, let records = ProcessRecord.decode(payload) else {
            retryAt = .now + retryDelay
            return nil
        }
        return records
    }

    private func connect() -> NSXPCConnection {
        connectionID += 1
        let id = connectionID
        let connection = NSXPCConnection(machServiceName: helperMachServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { await self?.discard(id) }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    /// An invalidated connection is dead for good; the next fetch builds a fresh one.
    private func discard(_ id: Int) {
        if id == connectionID { connection = nil }
    }
}
