import Foundation

/// Client for the privileged wtop-helper daemon.
/// Connects over XPC to get energy data for system processes.
///
/// The helper can be installed two ways:
/// 1. Source builds: `just install-helper` (uses sudo + launchctl directly)
/// 2. Signed releases: SMAppService.daemon() (requires Developer ID)
@Observable
@MainActor
final class HelperClient {
    enum Status: String {
        case notInstalled = "Not Installed"
        case running = "Running"
        case checking = "Checking..."
    }

    private(set) var status: Status = .checking
    private var connection: NSXPCConnection?

    private let serviceName = "me.abizer.wtop.helper"

    init() {
        checkConnection()
    }

    /// Probe the XPC service to see if the helper daemon is running.
    func checkConnection() {
        status = .checking
        let conn = getConnection()
        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.status = .notInstalled }
        }

        if let helper = proxy as? HelperProtocolClient {
            // Ping it with a real call — if it responds, it's running
            helper.getAllProcessEnergy { [weak self] _ in
                Task { @MainActor in self?.status = .running }
            }
        } else {
            status = .notInstalled
        }
    }

    /// Fetch energy data for all processes from the privileged helper.
    /// Returns nil if the helper isn't available.
    func fetchAllProcessEnergy() async -> [Int32: UInt64]? {
        guard status == .running else { return nil }

        let conn = getConnection()
        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.status = .notInstalled }
        }

        guard let helper = proxy as? HelperProtocolClient else { return nil }

        return await withCheckedContinuation { cont in
            helper.getAllProcessEnergy { result in
                cont.resume(returning: result)
            }
        }
    }

    private func getConnection() -> NSXPCConnection {
        if let connection { return connection }
        let conn = NSXPCConnection(machServiceName: serviceName)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocolClient.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.status = .notInstalled
            }
        }
        conn.resume()
        connection = conn
        return conn
    }
}

/// Mirror of HelperProtocol for the client side
@objc protocol HelperProtocolClient {
    func getAllProcessEnergy(reply: @escaping ([Int32: UInt64]) -> Void)
}
