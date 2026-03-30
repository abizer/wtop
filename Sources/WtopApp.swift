import SwiftUI
import AppKit

@main
struct WtopApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .defaultSize(width: 760, height: 880)
    }
}

struct ContentView: View {
    @State private var monitor = SystemMonitor()
    @State private var interval: Duration = .seconds(2)

    private let intervals: [(String, Duration)] = [
        ("0.5s", .milliseconds(500)),
        ("1s",   .seconds(1)),
        ("2s",   .seconds(2)),
        ("5s",   .seconds(5)),
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PowerSection(power: monitor.power,
                                  history: monitor.powerHistory,
                                  temps: monitor.temps,
                                  thermalLevel: monitor.thermalLevel)
                    Divider()
                    CoresSection(cores: monitor.cores, eCoreCount: monitor.eCoreCount)
                    Divider()
                    AppSection(apps: monitor.apps)
                }
                .padding()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear { monitor.start(interval: interval) }
        .onDisappear { monitor.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(monitor.sysInfo.hostname)
                .font(.caption.bold())

            Group {
                Text(monitor.sysInfo.cpuBrand)
                dot
                Text("\(monitor.eCoreCount)E+\(monitor.pCoreCount)P")
                dot
                Text("\(monitor.sysInfo.gpuCores)-core GPU")
                dot
                Text("\(monitor.sysInfo.memUsedGB)/\(monitor.sysInfo.memoryGB) GB")
                dot
                Text("up \(monitor.sysInfo.uptime)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer()

            Picker("", selection: $interval) {
                ForEach(intervals, id: \.1) { label, dur in
                    Text(label).tag(dur)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)
            .onChange(of: interval) { _, newVal in
                monitor.stop()
                monitor.start(interval: newVal)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var dot: some View {
        Text("·").font(.caption2).foregroundStyle(.tertiary)
    }
}
