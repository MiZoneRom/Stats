import SwiftUI

struct SettingsView: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        TabView {
            SensorSelectionSettings(monitor: monitor)
                .tabItem { Label("显示项目", systemImage: "checklist") }

            GeneralSettings(monitor: monitor)
                .tabItem { Label("常规", systemImage: "gearshape") }
        }
        .frame(width: 720, height: 500)
    }
}

private enum SensorCategory: Hashable, Identifiable {
    case all
    case kind(SensorKind)

    var id: String {
        switch self {
        case .all: "all"
        case .kind(let kind): kind.rawValue
        }
    }

    var title: String {
        switch self {
        case .all: "全部"
        case .kind(let kind): kind.title
        }
    }

    var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .kind(let kind): kind.icon
        }
    }
}

private struct SensorSelectionSettings: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var category: SensorCategory = .all
    @State private var query = ""

    private var filteredSensors: [SensorReading] {
        monitor.sensors.filter { sensor in
            matchesCategory(sensor) &&
            (query.isEmpty || sensor.name.localizedCaseInsensitiveContains(query) || sensor.key.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        HSplitView {
            categorySidebar
            sensorPane
        }
    }

    private var categorySidebar: some View {
        List(selection: $category) {
            categoryRow(.all, count: monitor.sensors.count)

            Section("传感器类型") {
                ForEach(SensorKind.allCases) { kind in
                    categoryRow(
                        .kind(kind),
                        count: monitor.sensors.filter { $0.kind == kind }.count
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 170, idealWidth: 180, maxWidth: 190)
    }

    private var sensorPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(category.title)
                    .font(.system(size: 15, weight: .semibold))

                Spacer()

                TextField("搜索传感器", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
            }
            .padding(12)

            Divider()

            if monitor.sensors.isEmpty {
                ContentUnavailableView("没有可用传感器", systemImage: "sensor")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSensors.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredSensors) { sensor in
                    Toggle(isOn: binding(for: sensor.key)) {
                        SettingsSensorRow(sensor: sensor)
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("已选择 \(monitor.selectedSensorKeys.count) 项")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("清除当前列表") {
                    monitor.setAllSensors(filteredSensors, isVisible: false)
                }
                Button("选择当前列表") {
                    monitor.setAllSensors(filteredSensors, isVisible: true)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
        }
    }

    private func categoryRow(_ item: SensorCategory, count: Int) -> some View {
        HStack(spacing: 8) {
            Label(item.title, systemImage: item.icon)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .tag(item)
    }

    private func matchesCategory(_ sensor: SensorReading) -> Bool {
        switch category {
        case .all: true
        case .kind(let kind): sensor.kind == kind
        }
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { monitor.selectedSensorKeys.contains(key) },
            set: { monitor.setSensor(key, isVisible: $0) }
        )
    }
}

private struct GeneralSettings: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { monitor.launchAtLoginEnabled },
                    set: { monitor.setLaunchAtLogin($0) }
                ))

                if monitor.launchAtLoginRequiresApproval {
                    Label("请在系统设置的“通用 > 登录项”中允许此应用", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let error = monitor.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("采样") {
                Picker("刷新频率", selection: $monitor.refreshInterval) {
                    Text("每秒").tag(1.0)
                    Text("每 2 秒").tag(2.0)
                    Text("每 5 秒").tag(5.0)
                    Text("每 10 秒").tag(10.0)
                }
                .frame(width: 280)
            }

            Section("菜单栏") {
                Picker("功耗来源", selection: $monitor.menuPowerSensorKey) {
                    Text("自动选择系统总功耗").tag(SystemMonitor.automaticPowerKey)
                    ForEach(monitor.powerSensors) { sensor in
                        Text("\(sensor.name)  [\(sensor.key)]").tag(sensor.key)
                    }
                    if monitor.menuPowerSensorKey != SystemMonitor.automaticPowerKey,
                       !monitor.powerSensors.contains(where: { $0.key == monitor.menuPowerSensorKey }) {
                        Text("不可用  [\(monitor.menuPowerSensorKey)]").tag(monitor.menuPowerSensorKey)
                    }
                }
                .frame(width: 360)
            }

            Section("弹出窗口") {
                LabeledContent("当前显示") {
                    Text("\(monitor.displayedSensors.count) 个传感器")
                        .foregroundStyle(.secondary)
                }
                Button("恢复推荐项目") {
                    monitor.restoreRecommendedSensors()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear {
            monitor.refreshLaunchAtLoginStatus()
        }
    }
}

private struct SettingsSensorRow: View {
    let sensor: SensorReading

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: sensor.kind.icon)
                .foregroundStyle(sensor.kind.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(sensor.name)
                    .font(.system(size: 12, weight: .medium))
                Text(sensor.key)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(sensor.formattedValue)
                .font(.system(size: 12, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
