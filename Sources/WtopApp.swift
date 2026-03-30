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
        escalatePrivilegesIfNeeded()
        // Set dock icon from SF Symbol since we don't have an .icns
        if let img = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "wtop") {
            let config = NSImage.SymbolConfiguration(pointSize: 128, weight: .medium)
            NSApp.applicationIconImage = img.withSymbolConfiguration(config)
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .defaultSize(width: 760, height: 880)
    }
}

/// If not running as root, relaunch via AppleScript `with administrator privileges`.
/// Shows the native macOS password dialog. If the user cancels, the app continues
/// unprivileged (system power and user-process data still work).
private func escalatePrivilegesIfNeeded() {
    guard getuid() != 0 else { return }  // already root

    let exe = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
    // Fully detach: redirect all I/O so the shell exits immediately after backgrounding
    let source = "do shell script \"'\(exe)' </dev/null >/dev/null 2>&1 &\" with administrator privileges"

    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)

    if error == nil {
        // Privileged instance launched — exit immediately
        exit(0)
    }
    // User cancelled or error — continue unprivileged
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
