import Foundation

/// Raw process data from the privileged helper.
struct HelperProcessEntry {
    let pid: Int32
    let uid: UInt32
    let cpuUser: UInt64
    let cpuSystem: UInt64
    let energyNJ: UInt64
    let threads: Int32
    let memResident: UInt64
    let path: String
}

/// Client for the privileged wtop-helper daemon.
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

    func checkConnection() {
        status = .checking
        let conn = getConnection()
        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.status = .notInstalled }
        }
        if let helper = proxy as? HelperProtocolClient {
            helper.getProcessData { [weak self] _ in
                Task { @MainActor in self?.status = .running }
            }
        } else {
            status = .notInstalled
        }
    }

    /// Fetch all process data from the privileged helper.
    func fetchProcessData() async -> [HelperProcessEntry]? {
        guard status == .running else { return nil }

        let conn = getConnection()
        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.status = .notInstalled }
        }
        guard let helper = proxy as? HelperProtocolClient else { return nil }

        return await withCheckedContinuation { cont in
            helper.getProcessData { data in
                cont.resume(returning: Self.decode(data))
            }
        }
    }

    // MARK: - Decode

    private static func decode(_ data: Data) -> [HelperProcessEntry] {
        guard data.count >= 4 else { return [] }
        var offset = 0

        func read<T>(_ type: T.Type) -> T {
            let val = data[offset..<offset+MemoryLayout<T>.size].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            offset += MemoryLayout<T>.size
            return val
        }

        let count = Int(read(UInt32.self))
        var entries: [HelperProcessEntry] = []
        entries.reserveCapacity(count)

        for _ in 0..<count {
            guard offset < data.count else { break }
            let pid = read(Int32.self)
            let uid = read(UInt32.self)
            let cpuUser = read(UInt64.self)
            let cpuSystem = read(UInt64.self)
            let energyNJ = read(UInt64.self)
            let threads = read(Int32.self)
            let memResident = read(UInt64.self)
            let pathLen = Int(read(UInt16.self))
            let path: String
            if pathLen > 0, offset + pathLen <= data.count {
                path = String(bytes: data[offset..<offset+pathLen], encoding: .utf8) ?? ""
                offset += pathLen
            } else {
                path = ""
            }
            entries.append(HelperProcessEntry(
                pid: pid, uid: uid, cpuUser: cpuUser, cpuSystem: cpuSystem,
                energyNJ: energyNJ, threads: threads, memResident: memResident, path: path
            ))
        }
        return entries
    }

    // MARK: - Connection

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

@objc protocol HelperProtocolClient {
    func getProcessData(reply: @escaping (Data) -> Void)
}
