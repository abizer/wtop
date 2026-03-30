import Foundation

/// XPC protocol exposed by the privileged helper daemon.
/// The helper runs as root and provides energy data for system processes
/// that the unprivileged app can't access via proc_pid_rusage.
@objc public protocol HelperProtocol {
    /// Returns a dictionary of [pid: energy_nj] for all running processes.
    /// The helper calls proc_pid_rusage with RUSAGE_INFO_V6 as root.
    func getAllProcessEnergy(reply: @escaping ([Int32: UInt64]) -> Void)
}

public let helperMachServiceName = "me.abizer.wtop.helper"
