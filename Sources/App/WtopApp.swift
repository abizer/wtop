import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct WtopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        if let img = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "wtop") {
            NSApp.applicationIconImage = img.withSymbolConfiguration(
                .init(pointSize: 128, weight: .medium))
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .defaultSize(width: 760, height: 880)
    }
}

struct ContentView: View {
    @State private var monitor = SystemMonitor()
    @State private var helper = HelperClient()
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
                Text("macOS \(monitor.sysInfo.osVersion)")
                dot
                Text("up \(monitor.sysInfo.uptime)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer()

            adminButton

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

    @ViewBuilder
    private var adminButton: some View {
        switch helper.status {
        case .running:
            Label("Admin", systemImage: "lock.open.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .notInstalled:
            Label("Limited", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Run 'just install-helper' or 'brew postinstall wtop' for full system process energy data")
        case .checking:
            ProgressView()
                .controlSize(.small)
        }
    }

    private var dot: some View {
        Text("·").font(.caption2).foregroundStyle(.tertiary)
    }
}
