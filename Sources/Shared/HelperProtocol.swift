import Foundation

/// XPC interface of the privileged helper — the one declaration both sides compile against.
///
/// The helper runs as root because `proc_pidinfo` refuses to describe system
/// processes (uid < 500) to an ordinary user.
@objc public protocol HelperProtocol {
    /// Replies with every running process, packed by `ProcessRecord.encode`.
    func getProcessData(reply: @escaping @Sendable (Data) -> Void)
}

public let helperMachServiceName = "me.abizer.wtop.helper"
