import Foundation

/// Counts live connections and fires once nobody has been connected for `timeout`.
///
/// The helper uses it to exit when the app goes away. XPC delivers its
/// callbacks on arbitrary queues, so all state lives on one serial queue.
public final class IdleTimer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.abizer.wtop.idle")
    private let timeout: DispatchTimeInterval
    private let onIdle: @Sendable () -> Void
    private var connections = 0
    private var pending: DispatchWorkItem?

    /// Starts counting down immediately — being launched with no client is idle too.
    public init(timeout: DispatchTimeInterval, onIdle: @escaping @Sendable () -> Void) {
        self.timeout = timeout
        self.onIdle = onIdle
        queue.async { self.arm() }
    }

    public func connectionOpened() {
        queue.async {
            self.connections += 1
            self.pending?.cancel()
            self.pending = nil
        }
    }

    public func connectionClosed() {
        queue.async {
            self.connections = max(self.connections - 1, 0)
            if self.connections == 0 { self.arm() }
        }
    }

    private func arm() {
        pending?.cancel()
        let item = DispatchWorkItem(block: onIdle)
        pending = item
        queue.asyncAfter(deadline: .now() + timeout, execute: item)
    }
}
