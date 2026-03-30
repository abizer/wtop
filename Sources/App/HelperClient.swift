import Foundation
import ServiceManagement

/// Client for the privileged wtop-helper daemon.
/// Registers the daemon via SMAppService and communicates over XPC.
@Observable
@MainActor
final class HelperClient {
    enum Status: String {
        case notRegistered = "Not Installed"
        case requiresApproval = "Needs Approval"
        case enabled = "Running"
        case failed = "Failed"
    }

    private(set) var status: Status = .notRegistered
    private var connection: NSXPCConnection?

    private let serviceName = "me.abizer.wtop.helper"
    private let plistName = "me.abizer.wtop.helper.plist"

    init() {
        refreshStatus()
    }

    // MARK: - Registration

    /// Register the privileged helper daemon. If it needs user approval,
    /// opens System Settings > Login Items.
    func register() {
        let service = SMAppService.daemon(plistName: plistName)
        do {
            try service.register()
            refreshStatus()
        } catch {
            refreshStatus()
            if status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    func refreshStatus() {
        let service = SMAppService.daemon(plistName: plistName)
        status = switch service.status {
        case .notRegistered: .notRegistered
        case .enabled:       .enabled
        case .requiresApproval: .requiresApproval
        case .notFound:      .notRegistered
        @unknown default:    .failed
        }
    }

    // MARK: - XPC Communication

    /// Fetch energy data for all processes from the privileged helper.
    /// Returns nil if the helper isn't available.
    func fetchAllProcessEnergy() async -> [Int32: UInt64]? {
        guard status == .enabled else { return nil }

        let conn = getConnection()
        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.status = .failed }
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
                self?.refreshStatus()
            }
        }
        conn.resume()
        connection = conn
        return conn
    }
}

/// Mirror of HelperProtocol for the client side (avoids importing the helper target)
@objc protocol HelperProtocolClient {
    func getAllProcessEnergy(reply: @escaping ([Int32: UInt64]) -> Void)
}
