import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var monitor: SystemMonitor

    private var visibleSensors: [SensorReading] {
        monitor.displayedSensors
    }

    private var popoverHeight: CGFloat {
        min(500, max(190, CGFloat(max(visibleSensors.count, 3)) * 49 + 39))
    }

    var body: some View {
        VStack(spacing: 0) {
            sensorList
            Divider()
            footer
        }
        .frame(width: 390, height: popoverHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            monitor.startMonitoring()
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
    }

    @ViewBuilder
    private var sensorList: some View {
        if monitor.isLoading && monitor.sensors.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取传感器")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = monitor.errorMessage, monitor.sensors.isEmpty {
            ContentUnavailableView {
                Label("无法读取传感器", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重新读取") { monitor.refreshNow() }
            }
        } else if visibleSensors.isEmpty {
            ContentUnavailableView {
                Label("尚未选择监控项目", systemImage: "slider.horizontal.3")
            } description: {
                Text("在设置中选择要显示的传感器")
            } actions: {
                SettingsLink {
                    Text("打开设置")
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleSensors) { sensor in
                        SensorRow(sensor: sensor)
                        if sensor.id != visibleSensors.last?.id {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(monitor.lastRefreshText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                monitor.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("立即刷新")

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("退出系统状态")
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

private struct SensorRow: View {
    let sensor: SensorReading

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sensor.kind.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(sensor.kind.color)
                .frame(width: 26, height: 26)
                .background(sensor.kind.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(sensor.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(sensor.key)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            Text(sensor.formattedValue)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .contentShape(Rectangle())
    }
}
