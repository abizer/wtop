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
        // The content scrolls under a standard window toolbar. Built against the macOS 26 SDK
        // or later, that toolbar and its controls are Liquid Glass with no further code;
        // on macOS 14 and 15 the same toolbar renders in the classic style.
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
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle(monitor.system.hostname)
        .navigationSubtitle(systemSummary)
        .toolbar {
            // Padded so the label clears the ends of its glass capsule.
            ToolbarItem { helperBadge.padding(.horizontal, 8) }
            ToolbarItem {
                Picker("Refresh interval", selection: $monitor.interval) {
                    ForEach(Self.intervals, id: \.duration) { interval in
                        Text(interval.label).tag(interval.duration)
                    }
                }
                .pickerStyle(.segmented)
                .help("Refresh interval")
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    /// "Apple M3 Max · 4E+12P · 40-core GPU · 38/64 GB · macOS 27.2.1 · up 2h 6m"
    private var systemSummary: String {
        [
            monitor.system.cpuBrand,
            "\(monitor.eCoreCount)E+\(monitor.pCoreCount)P",
            "\(monitor.system.gpuCores)-core GPU",
            "\(monitor.memUsedGB)/\(monitor.system.memoryGB) GB",
            "macOS \(monitor.system.osVersion)",
            "up \(monitor.uptime)",
        ].joined(separator: " · ")
    }

    @ViewBuilder
    private var helperBadge: some View {
        switch monitor.helper {
        case .connected:
            Label("Admin", systemImage: "lock.open.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
                .help("Privileged helper connected — showing every process on the system")
        case .unavailable:
            Label("Limited", systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .help("Showing only your own processes. Run 'just install-helper' or 'brew reinstall --cask wtop' to install the privileged helper.")
        case .checking:
            ProgressView()
                .controlSize(.small)
        }
    }
}
