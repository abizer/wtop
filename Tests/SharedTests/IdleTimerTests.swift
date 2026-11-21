import Foundation
import Testing
@testable import WtopShared

/// Thread-safe fire counter for the timer's callback.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

// The timer under test fires after 150 ms.
private let beforeTimeout = Duration.milliseconds(50)
private let afterTimeout = Duration.milliseconds(400)

private func makeTimer(_ fired: Counter) -> IdleTimer {
    IdleTimer(timeout: .milliseconds(150)) { fired.increment() }
}

@Test func firesWhenNobodyEverConnects() async throws {
    let fired = Counter()
    let timer = makeTimer(fired)
    try await Task.sleep(for: afterTimeout)
    #expect(fired.count == 1)
    _ = timer
}

@Test func staysQuietWhileAConnectionIsOpen() async throws {
    let fired = Counter()
    let timer = makeTimer(fired)
    timer.connectionOpened()
    try await Task.sleep(for: afterTimeout)
    #expect(fired.count == 0)

    timer.connectionClosed()
    try await Task.sleep(for: beforeTimeout)
    #expect(fired.count == 0, "must wait out the full timeout after the last client leaves")
    try await Task.sleep(for: afterTimeout)
    #expect(fired.count == 1)
}

@Test func aReconnectCancelsThePendingExit() async throws {
    let fired = Counter()
    let timer = makeTimer(fired)
    timer.connectionOpened()
    timer.connectionClosed()
    try await Task.sleep(for: beforeTimeout)
    timer.connectionOpened()
    try await Task.sleep(for: afterTimeout)
    #expect(fired.count == 0)
}

/// One client leaving — or reporting its departure twice — must not strand the others.
@Test func waitsForEveryConnectionToClose() async throws {
    let fired = Counter()
    let timer = makeTimer(fired)
    timer.connectionOpened()
    timer.connectionOpened()
    timer.connectionClosed()
    try await Task.sleep(for: afterTimeout)
    #expect(fired.count == 0)

    timer.connectionClosed()
    timer.connectionClosed()  // spurious extra close
    timer.connectionOpened()
    try await Task.sleep(for: afterTimeout)
    #expect(fired.count == 0, "an extra close must not drive the count negative")
}
