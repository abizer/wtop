import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct WtopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var monitor = SystemMonitor()

    init() {
        // Needed when launched as a bare binary (`just run`), harmless inside the bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        if let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "wtop") {
            NSApp.applicationIconImage = symbol.withSymbolConfiguration(
                .init(pointSize: 128, weight: .medium))
        }
    }

    var body: some Scene {
        // A single window: one monitor, one sampler, one helper connection.
        Window("wtop", id: "main") {
            ContentView(monitor: monitor)
        }
        .defaultSize(width: 760, height: 880)
    }
}

struct ContentView: View {
    @Bindable var monitor: SystemMonitor

    private static let intervals: [(label: String, duration: Duration)] = [
        ("0.5s", .milliseconds(500)),
        ("1s", .seconds(1)),
        ("2s", .seconds(2)),
        ("5s", .seconds(5)),
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
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(monitor.system.hostname)
                .font(.caption.bold())
                .lineLimit(1)

            Group {
                Text(monitor.system.cpuBrand)
                dot
                Text("\(monitor.eCoreCount)E+\(monitor.pCoreCount)P")
                dot
                Text("\(monitor.system.gpuCores)-core GPU")
                dot
                Text("\(monitor.memUsedGB)/\(monitor.system.memoryGB) GB")
                dot
                Text("macOS \(monitor.system.osVersion)")
                dot
                Text("up \(monitor.uptime)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer(minLength: 8)

            helperBadge

            Picker("Refresh interval", selection: $monitor.interval) {
                ForEach(Self.intervals, id: \.duration) { interval in
                    Text(interval.label).tag(interval.duration)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var helperBadge: some View {
        switch monitor.helper {
        case .connected:
            Label("Admin", systemImage: "lock.open.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .help("Privileged helper connected — showing every process on the system")
        case .unavailable:
            Label("Limited", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Showing only your own processes. Run 'just install-helper' or 'brew reinstall --cask wtop' to install the privileged helper.")
        case .checking:
            ProgressView()
                .controlSize(.small)
        }
    }

    private var dot: some View {
        Text("·").font(.caption2).foregroundStyle(.tertiary)
    }
}
