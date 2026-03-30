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
                        Text(String(format: "%.0f°", t.celsius))
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
    let watts: Double
    let color: Color
    let subtitle: String?

    init(_ label: String, watts: Double, color: Color, subtitle: String? = nil) {
        self.label = label; self.watts = watts; self.color = color; self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatWatts(watts))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText(value: watts))
            if let sub = subtitle {
                Text(sub).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .padding(.vertical, 10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let maxV = values.max() ?? 1
            let minV = values.min() ?? 0
            let range = max(maxV - minV, 0.1)
            let w = geo.size.width
            let h = geo.size.height

            // Filled area
            Path { path in
                for (i, v) in values.enumerated() {
                    let x = w * Double(i) / max(Double(values.count - 1), 1)
                    let y = h * (1 - (v - minV) / range) * 0.85 + h * 0.075
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                path.addLine(to: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: 0, y: h))
                path.closeSubpath()
            }
            .fill(color.opacity(0.1))

            // Line
            Path { path in
                for (i, v) in values.enumerated() {
                    let x = w * Double(i) / max(Double(values.count - 1), 1)
                    let y = h * (1 - (v - minV) / range) * 0.85 + h * 0.075
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
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
    @State private var cachedOrder: [String] = []  // stable ordering cache

    private var visible: [AppUsage] {
        var list = apps

        switch filter {
        case .all:    break
        case .apps:   list = list.filter(\.isUserApp)
        case .system: list = list.filter { !$0.isUserApp }
        }

        if !search.isEmpty {
            list = list.filter {
                $0.id.localizedCaseInsensitiveContains(search) ||
                $0.procs.contains { $0.name.localizedCaseInsensitiveContains(search) }
            }
        }

        // Use cached order for stability — only re-rank when user changes sort/filter/search
        // New items go to the end; removed items disappear
        if !cachedOrder.isEmpty {
            let currentIds = Set(list.map(\.id))
            let known = cachedOrder.filter { currentIds.contains($0) }
            let new = list.map(\.id).filter { !known.contains($0) }
            let order = known + new
            let lookup = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            list = order.compactMap { lookup[$0] }
        }

        return list
    }

    private func sortedList() -> [AppUsage] {
        var list = apps
        switch filter {
        case .all:    break
        case .apps:   list = list.filter(\.isUserApp)
        case .system: list = list.filter { !$0.isUserApp }
        }
        if !search.isEmpty {
            list = list.filter {
                $0.id.localizedCaseInsensitiveContains(search) ||
                $0.procs.contains { $0.name.localizedCaseInsensitiveContains(search) }
            }
        }
        switch sortBy {
        case .power:  list.sort { $0.totalEnergyW != $1.totalEnergyW ? $0.totalEnergyW > $1.totalEnergyW : $0.id < $1.id }
        case .cpu:    list.sort { $0.totalCpuMs != $1.totalCpuMs ? $0.totalCpuMs > $1.totalCpuMs : $0.id < $1.id }
        case .memory: list.sort { $0.totalMem != $1.totalMem ? $0.totalMem > $1.totalMem : $0.id < $1.id }
        case .name:   list.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        }
        return list
    }

    /// Re-sort and cache the order (called on user interaction, not on every data update)
    private func resort() {
        cachedOrder = sortedList().map(\.id)
    }

    private var peak: Double {
        let maxE = visible.map(\.totalEnergyW).max() ?? 0
        return max(maxE, 0.001)
    }

    var body: some View {
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

                Picker("", selection: $filter) {
                    ForEach(ProcessFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)

                Picker("", selection: $sortBy) {
                    ForEach(SortField.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 80)
            }
            .onChange(of: sortBy) { _, _ in resort() }
            .onChange(of: filter) { _, _ in resort() }
            .onChange(of: search) { _, _ in resort() }
            .onAppear { resort() }

            // Column header
            procGrid(
                name: Text("Name"),
                power: Text("Power"),
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
                        appRow(app)
                    }
                } else if let proc = app.procs.first {
                    flatRow(proc)
                }
            }
        }
    }

    // MARK: - Shared column grid

    private func procGrid<N: View, P: View, C: View, K: View, M: View>(
        name: N, power: P, cpu: C, count: K, mem: M
    ) -> some View {
        HStack(spacing: 0) {
            name.frame(maxWidth: .infinity, alignment: .leading)
            power.frame(width: 72, alignment: .trailing)
            cpu  .frame(width: 72, alignment: .trailing)
            count.frame(width: 48, alignment: .trailing)
            mem  .frame(width: 72, alignment: .trailing)
        }
    }

    // MARK: - Rows

    private func appRow(_ app: AppUsage) -> some View {
        procGrid(
            name: Text(app.id).fontWeight(.medium).lineLimit(1).truncationMode(.tail),
            power: energyText(app.totalEnergyW, available: app.hasEnergy),
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
                    .frame(width: geo.size.width * min(app.totalEnergyW / max(peak, 0.001), 1))
            }
        }
    }

    private func subProcRow(_ proc: ProcUsage) -> some View {
        procGrid(
            name: Text(proc.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary),
            power: energyText(proc.energyW, available: proc.hasEnergy),
            cpu: Text(String(format: "%.1f", proc.cpuMs)),
            count: Text("\(proc.threads)").foregroundStyle(.secondary),
            mem: Text(formatMem(proc.mem))
        )
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }

    private func flatRow(_ proc: ProcUsage) -> some View {
        procGrid(
            name: Text(proc.name).lineLimit(1).truncationMode(.middle),
            power: energyText(proc.energyW, available: proc.hasEnergy),
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
                    .frame(width: geo.size.width * min(proc.energyW / max(peak, 0.001), 1))
            }
        }
    }
}

// MARK: - Helpers

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
