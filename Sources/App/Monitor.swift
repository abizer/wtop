import Foundation
import Observation

/// What the UI observes. Owns no measuring logic — it asks the `Sampler` for a
/// snapshot on a timer and publishes the result on the main actor.
@Observable
@MainActor
final class SystemMonitor {
    let system = SystemInfo.current
    let eCoreCount: Int
    let pCoreCount: Int

    private(set) var apps: [AppUsage] = []
    private(set) var cores: [CoreUsage] = []
    private(set) var power = PowerReading()
    private(set) var temps: [TempReading] = []
    private(set) var thermalLevel: ThermalLevel = .nominal
    private(set) var powerHistory: [Double] = []
    private(set) var memUsedGB = 0
    private(set) var uptime = ""
    private(set) var helper: HelperStatus = .checking

    /// Changing the interval while running takes effect immediately.
    var interval: Duration = .seconds(2) {
        didSet { if task != nil, interval != oldValue { start() } }
    }

    private let sampler: Sampler
    private var task: Task<Void, Never>?
    private let historyLimit = 150

    init() {
        eCoreCount = system.eCores > 0 ? system.eCores : 4
        pCoreCount = system.pCores > 0 ? system.pCores : 8
        sampler = Sampler(eCoreCount: eCoreCount)
    }

    func start() {
        let previous = task
        previous?.cancel()
        task = Task {
            // Never let two loops sample at once — the sampler's deltas assume one caller.
            await previous?.value
            while !Task.isCancelled {
                let snapshot = await sampler.sample()
                if Task.isCancelled { break }
                publish(snapshot)
                // Tolerance lets the system coalesce our wakeups with others'.
                try? await Task.sleep(for: interval, tolerance: interval / 10)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func publish(_ snapshot: Sampler.Snapshot) {
        apps = snapshot.apps
        cores = snapshot.cores
        power = snapshot.power
        temps = snapshot.temps
        thermalLevel = snapshot.thermalLevel
        memUsedGB = snapshot.memUsedGB
        uptime = snapshot.uptime
        helper = snapshot.helper

        if snapshot.power.systemW > 0 {
            powerHistory.append(snapshot.power.systemW)
            if powerHistory.count > historyLimit {
                powerHistory.removeFirst(powerHistory.count - historyLimit)
            }
        }
    }
}
