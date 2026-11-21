import Foundation
import IOKit

/// Who is using the GPU.
///
/// Every process that opens the GPU gets a user client under the accelerator in the IO
/// registry, carrying the nanoseconds of GPU time it has been given so far. Readable
/// without root, for every process — it is what Activity Monitor's GPU column shows.
final class GPUClients {
    private let accelerator: io_service_t
    private var previous: [Int32: UInt64] = [:]

    init?() {
        accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard accelerator != 0 else { return nil }
        previous = accumulatedTime()
    }

    deinit { IOObjectRelease(accelerator) }

    /// Each process's fraction of the GPU time handed out since the previous call.
    func shares() -> [Int32: Double] {
        let current = accumulatedTime()
        defer { previous = current }
        return Self.shares(previous: previous, current: current)
    }

    /// Fractions of the GPU time used between two readings, summing to 1 — or empty if the
    /// GPU did nothing. A process whose total went backwards closed a client and has no
    /// meaningful delta; a process seen for the first time counts from zero.
    static func shares(previous: [Int32: UInt64], current: [Int32: UInt64]) -> [Int32: Double] {
        var used: [Int32: UInt64] = [:]
        for (pid, time) in current {
            let before = previous[pid] ?? 0
            if time > before { used[pid] = time - before }
        }
        let total = used.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return used.mapValues { Double($0) / Double(total) }
    }

    /// Nanoseconds of GPU time per pid, summed over that process's open clients.
    private func accumulatedTime() -> [Int32: UInt64] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var times: [Int32: UInt64] = [:]
        while case let client = IOIteratorNext(iterator), client != 0 {
            defer { IOObjectRelease(client) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(client, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let usage = property("AppUsage") as? [[String: Any]], !usage.isEmpty,
                  let pid = Self.pid(fromCreator: property("IOUserClientCreator") as? String)
            else { continue }
            for entry in usage {
                times[pid, default: 0] += (entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
            }
        }
        return times
    }

    /// "pid 631, WindowServer" → 631
    static func pid(fromCreator creator: String?) -> Int32? {
        guard let creator, creator.hasPrefix("pid ") else { return nil }
        return Int32(creator.dropFirst(4).prefix { $0.isNumber })
    }
}
