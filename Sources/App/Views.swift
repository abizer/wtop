import SwiftUI

// MARK: - Power Section

struct PowerSection: View {
    let power: PowerReading
    let history: [Double]
    let temps: [TempReading]
    let thermalLevel: ThermalLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Power", icon: "bolt.fill")

            // Top row: system totals
            HStack(spacing: 10) {
                PowerCard("System", watts: power.systemW, color: .orange)
                if power.onAC {
                    PowerCard("DC In", watts: power.adapterW, color: .green)
                }
                PowerCard("Battery", watts: power.batteryW,
                           color: power.onAC ? .blue : .yellow,
                           subtitle: batterySubtitle)
            }

            // SoC component breakdown (from IOReport)
            if power.hasIOReport {
                HStack(spacing: 10) {
                    PowerCard("CPU", watts: power.cpuW, color: .cyan)
                    PowerCard("GPU", watts: power.gpuW, color: .purple)
                    PowerCard("ANE", watts: power.aneW, color: .mint)
                    PowerCard("DRAM", watts: power.dramW, color: .teal)
                }
            }

            // Where the rest of the system figure goes. With the row above, these add up to it.
            if power.socOtherW != nil || power.displayW != nil {
                HStack(spacing: 10) {
                    if let socOther = power.socOtherW {
                        PowerCard("Other SoC", watts: socOther, color: .indigo,
                                  help: "The rest of the chip: display controller, video and camera blocks, I/O.")
                    }
                    if let display = power.displayW {
                        PowerCard("Display", watts: display, color: .yellow, help: "The display backlight.")
                    }
                    if let unattributed = power.unattributedW {
                        PowerCard("Everything Else", watts: unattributed, color: .gray,
                                  help: "System power no sensor accounts for: SSD, Wi-Fi and Bluetooth, the display's electronics, speakers, and power-conversion losses. It grows under heavy GPU load, when the system draws more than the chip's own counters report.")
                    }
                }
            }

            // Sparkline
            if history.count > 2 {
                Sparkline(values: history, color: .orange)
                    .frame(height: 36)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            // Status row: thermal + temps + battery time
            HStack(spacing: 12) {
                ThermalBadge(level: thermalLevel)

                ForEach(temps) { t in
                    HStack(spacing: 2) {
                        Text(t.label).foregroundStyle(.secondary)
                        Text(String(format: "%.0f°C", t.celsius))
                    }
                    .font(.caption)
                }

                Spacer()

                if let hours = power.batteryTimeRemaining {
                    let h = Int(hours)
                    let m = Int((hours - Double(h)) * 60)
                    Label("\(h)h \(m)m remaining", systemImage: "battery.50")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if power.onAC {
                    Label("AC Power", systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var batterySubtitle: String? {
        guard power.batteryPct >= 0 else { return nil }
        return "\(power.batteryPct)%"
    }
}

struct PowerCard: View {
    let label: String
    /// nil when the sensor exists but isn't reporting — shown as a dash, never as zero.
    let watts: Double?
    let color: Color
    let subtitle: String?
    let help: String

    init(_ label: String, watts: Double?, color: Color, subtitle: String? = nil, help: String = "") {
        self.label = label; self.watts = watts; self.color = color; self.subtitle = subtitle; self.help = help
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let watts {
                Text(formatWatts(watts))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText(value: watts))
            } else {
                Text("—")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .help("macOS doesn't give wtop a live energy counter for this on this Mac, so there is no reading to show.")
            }
            if let sub = subtitle {
                Text(sub).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .padding(.vertical, 10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .help(help)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let line = Self.points(for: values, width: w, height: h)

            // Filled area
            Path { path in
                path.addLines(line)
                path.addLine(to: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: 0, y: h))
                path.closeSubpath()
            }
            .fill(color.opacity(0.1))

            Path { $0.addLines(line) }
                .stroke(color.opacity(0.6), lineWidth: 1.5)

            // Current value label
            if let last = values.last {
                Text(formatWatts(last))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                    .position(x: w - 30, y: 10)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("System power history")
        .accessibilityValue(values.last.map(formatWatts) ?? "")
    }

    /// Scales the series to the frame, leaving 7.5% headroom above and below.
    private static func points(for values: [Double], width: Double, height: Double) -> [CGPoint] {
        let low = values.min() ?? 0
        let spread = (values.max() ?? low) - low
        let step = width / Double(max(values.count - 1, 1))
        return values.enumerated().map { index, value in
            // A flat series sits mid-height rather than hugging the floor.
            let level = spread > 0.1 ? (value - low) / spread : 0.5
            return CGPoint(x: step * Double(index),
                           y: height * (1 - level) * 0.85 + height * 0.075)
        }
    }
}

// MARK: - Thermal Badge

struct ThermalBadge: View {
    let level: ThermalLevel

    private var color: Color {
        switch level {
        case .nominal:  .green
        case .fair:     .yellow
        case .serious:  .orange
        case .critical: .red
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(level.rawValue)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - CPU Cores Section

struct CoresSection: View {
    let cores: [CoreUsage]
    let eCoreCount: Int

    private var eCores: [CoreUsage] { Array(cores.prefix(eCoreCount)) }
    private var pCores: [CoreUsage] { Array(cores.dropFirst(eCoreCount)) }

    /// Split P-cores into columns of `rowCount` to match E-core row count
    private var pCoreColumns: [[CoreUsage]] {
        let rowCount = max(eCoreCount, 4)
        return stride(from: 0, to: pCores.count, by: rowCount).map { start in
            Array(pCores[start..<min(start + rowCount, pCores.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("CPU Cores", icon: "cpu")
            HStack(alignment: .top, spacing: 20) {
                if !eCores.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Efficiency").font(.caption).foregroundStyle(.secondary)
                        ForEach(eCores) { core in
                            CoreBar(core: core, color: .cyan, label: "E")
                        }
                    }
                }
                if !pCores.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Performance").font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(pCoreColumns.indices, id: \.self) { col in
                                VStack(spacing: 4) {
                                    ForEach(pCoreColumns[col]) { core in
                                        CoreBar(core: core, color: .orange, label: "P")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct CoreBar: View {
    let core: CoreUsage
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text("\(label)\(core.id)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(height: 12)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.4 + core.usage * 0.6))
                        .frame(width: max(geo.size.width * core.usage, 0))
                }.frame(height: 12)
            }
            Text(String(format: "%2.0f%%", core.usage * 100))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

// MARK: - Sort / Filter types

enum SortField: String, CaseIterable {
    case power = "Power"
    case gpu = "GPU"
    case cpu = "CPU"
    case memory = "Memory"
    case name = "Name"
}

enum ProcessFilter: String, CaseIterable {
    case all = "All"
    case apps = "Apps"
    case system = "System"
}

// MARK: - App-Grouped Process List

struct AppSection: View {
    let apps: [AppUsage]
    @State private var sortBy: SortField = .power
    @State private var filter: ProcessFilter = .all
    @State private var search: String = ""
    /// Ranking frozen at the last user interaction, so rows don't jump around every tick.
    @State private var frozenOrder: [String] = []

    /// Apps passing the filter and search, in no particular order.
    private var matching: [AppUsage] {
        apps.filter { app in
            switch filter {
            case .all: true
            case .apps: app.isUserApp
            case .system: !app.isUserApp
            }
        }
        .filter { app in
            search.isEmpty
                || app.id.localizedCaseInsensitiveContains(search)
                || app.procs.contains { $0.name.localizedCaseInsensitiveContains(search) }
        }
    }

    private func ranked(_ list: [AppUsage]) -> [AppUsage] {
        switch sortBy {
        case .power:  list.sorted { ($1.totalEnergyW, $0.id) < ($0.totalEnergyW, $1.id) }
        case .gpu:    list.sorted { ($1.totalGpuW, $0.id) < ($0.totalGpuW, $1.id) }
        case .cpu:    list.sorted { ($1.totalCpuMs, $0.id) < ($0.totalCpuMs, $1.id) }
        case .memory: list.sorted { ($1.totalMem, $0.id) < ($0.totalMem, $1.id) }
        case .name:   list.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        }
    }

    /// Matching apps in the frozen order; anything that appeared since is ranked and appended.
    private var visible: [AppUsage] {
        let matching = matching
        let byID = Dictionary(matching.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let frozen = Set(frozenOrder)
        return frozenOrder.compactMap { byID[$0] } + ranked(matching.filter { !frozen.contains($0.id) })
    }

    /// Re-rank now (called on user interaction, not on every data update).
    private func resort() {
        frozenOrder = ranked(matching).map(\.id)
    }

    var body: some View {
        // Computed once per render — every row needs the list's peak to scale its bar.
        let visible = visible
        let peak = max(visible.lazy.map(\.totalEnergyW).max() ?? 0, 0.001)

        VStack(alignment: .leading, spacing: 6) {
            // Controls bar
            HStack(spacing: 8) {
                SectionHeader("Processes (\(visible.count))", icon: "flame")
                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Filter", text: $search)
                        .textFieldStyle(.plain)
                        .frame(width: 100)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 6))

                Picker("Show", selection: $filter) {
                    ForEach(ProcessFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)

                Picker("Sort by", selection: $sortBy) {
                    ForEach(SortField.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 80)
            }
            .onChange(of: sortBy) { resort() }
            .onChange(of: filter) { resort() }
            .onChange(of: search) { resort() }
            .onAppear { resort() }

            // Column header
            procGrid(
                name: Text("Name"),
                power: Text("Power"),
                gpu: Text("GPU")
                    .help("The app's share of GPU power, split by GPU time. Included in Power."),
                cpu: Text("CPU ms/s"),
                count: Text("Procs"),
                mem: Text("Memory")
            )
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)

            // Process list — stable order, values update in place
            ForEach(visible.prefix(60)) { app in
                if app.procs.count > 1 {
                    DisclosureGroup {
                        ForEach(app.procs) { proc in
                            subProcRow(proc)
                        }
                    } label: {
                        appRow(app, peak: peak)
                    }
                } else if let proc = app.procs.first {
                    flatRow(proc, peak: peak)
                }
            }
        }
    }

    // MARK: - Shared column grid

    private func procGrid<N: View, P: View, G: View, C: View, K: View, M: View>(
        name: N, power: P, gpu: G, cpu: C, count: K, mem: M
    ) -> some View {
        HStack(spacing: 0) {
            name.frame(maxWidth: .infinity, alignment: .leading)
            power.frame(width: 72, alignment: .trailing)
            gpu  .frame(width: 72, alignment: .trailing)
            cpu  .frame(width: 72, alignment: .trailing)
            count.frame(width: 48, alignment: .trailing)
            mem  .frame(width: 72, alignment: .trailing)
        }
    }

    // MARK: - Rows

    private func appRow(_ app: AppUsage, peak: Double) -> some View {
        procGrid(
            name: Text(app.id).fontWeight(.medium).lineLimit(1).truncationMode(.tail),
            power: energyText(app.totalEnergyW, available: app.hasEnergy),
            gpu: gpuText(app.totalGpuW),
            cpu: Text(String(format: "%.0f", app.totalCpuMs)),
            count: Text("\(app.procs.count)"),
            mem: Text(formatMem(app.totalMem))
        )
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(.orange.opacity(0.06))
                    .frame(width: geo.size.width * min(app.totalEnergyW / peak, 1))
            }
        }
    }

    private func subProcRow(_ proc: ProcUsage) -> some View {
        procGrid(
            name: Text(proc.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary),
            power: energyText(proc.energyW, available: proc.hasEnergy),
            gpu: gpuText(proc.gpuW),
            cpu: Text(String(format: "%.1f", proc.cpuMs)),
            count: Text("\(proc.threads)").foregroundStyle(.secondary),
            mem: Text(formatMem(proc.mem))
        )
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }

    private func flatRow(_ proc: ProcUsage, peak: Double) -> some View {
        procGrid(
            name: Text(proc.name).lineLimit(1).truncationMode(.middle),
            power: energyText(proc.energyW, available: proc.hasEnergy),
            gpu: gpuText(proc.gpuW),
            cpu: Text(String(format: "%.1f", proc.cpuMs)),
            count: Text("\(proc.threads)").foregroundStyle(.secondary),
            mem: Text(formatMem(proc.mem))
        )
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(.orange.opacity(0.06))
                    .frame(width: geo.size.width * min(proc.energyW / peak, 1))
            }
        }
    }
}

// MARK: - Helpers

/// A process's GPU share; blank rather than "0 mW" for the many that never touch the GPU.
func gpuText(_ watts: Double) -> Text {
    watts >= 0.001 ? Text(formatWatts(watts)).foregroundStyle(.purple) : Text("")
}

@ViewBuilder
func energyText(_ watts: Double, available: Bool) -> some View {
    if available {
        Text(formatWatts(watts)).foregroundStyle(energyColor(watts))
    } else {
        Text("—").foregroundStyle(.tertiary)
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String
    init(_ title: String, icon: String) { self.title = title; self.icon = icon }
    var body: some View {
        Label(title, systemImage: icon).font(.headline)
    }
}

func formatWatts(_ w: Double) -> String {
    if w >= 100   { return String(format: "%.0f W", w) }
    if w >= 10    { return String(format: "%.1f W", w) }
    if w >= 1     { return String(format: "%.2f W", w) }
    if w >= 0.1   { return String(format: "%.0f mW", w * 1000) }
    if w >= 0.001 { return String(format: "%.1f mW", w * 1000) }
    return "0 mW"
}

func formatMem(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    return mb >= 1024
        ? String(format: "%.1f GB", mb / 1024)
        : String(format: "%.0f MB", mb)
}

func energyColor(_ watts: Double) -> Color {
    if watts >= 2   { return .red }
    if watts >= 0.5 { return .orange }
    if watts >= 0.1 { return .yellow }
    return .secondary
}
