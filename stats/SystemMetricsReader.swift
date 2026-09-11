import Foundation
import IOKit
import IOKit.ps

final class SystemMetricsReader {
    private var cachedSpeedLimit: String?
    private var lastSpeedLimitRead: Date?

    func readMetrics() -> [SensorReading] {
        var metrics = readBatteryMetrics()
#if arch(x86_64)
        metrics.append(readSpeedLimit())
#endif
        return metrics
    }

    private func readBatteryMetrics() -> [SensorReading] {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return [] }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }

        var rawProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &rawProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = rawProperties?.takeRetainedValue() as? [String: Any] else { return [] }

        let batteryData = properties["BatteryData"] as? [String: Any]
        let designCapacity = integer(properties["DesignCapacity"])
            ?? integer(batteryData?["DesignCapacity"])
        let maximumCapacity = integer(properties["AppleRawMaxCapacity"])
            ?? integer(properties["MaxCapacity"])
            ?? integer(properties["NominalChargeCapacity"])
            ?? integer(batteryData?["NominalChargeCapacity"])
            ?? integer(batteryData?["FullChargeCapacity"])

        var metrics: [SensorReading] = []

        if let maximumCapacity, let designCapacity, designCapacity > 0 {
            let health = Double(maximumCapacity) / Double(designCapacity) * 100
            metrics.append(metric(
                key: "METRIC-BATTERY-HEALTH",
                name: "电池健康度",
                value: health,
                text: health.formatted(.number.precision(.fractionLength(0))) + " %"
            ))
        }

        if let watts = adapterWatts(properties: properties), watts > 0 {
            metrics.append(metric(
                key: "METRIC-ADAPTER-POWER",
                name: "电源适配器功率",
                value: watts,
                text: watts.formatted(.number.precision(.fractionLength(0))) + " W"
            ))
        }

        let charging = (properties["IsCharging"] as? NSNumber)?.boolValue ?? false
        let fullyCharged = (properties["FullyCharged"] as? NSNumber)?.boolValue ?? false
        let externalConnected = (properties["ExternalConnected"] as? NSNumber)?.boolValue ?? false
        let minutes = timeToFullCharge()
            ?? integer(properties["AvgTimeToFull"])
            ?? integer(properties["TimeRemaining"])
        let timeText: String
        if fullyCharged {
            timeText = "已充满"
        } else if !externalConnected {
            timeText = "未连接电源"
        } else if charging, let minutes, minutes > 0, minutes < 65_535 {
            timeText = duration(minutes: minutes)
        } else {
            timeText = "计算中"
        }
        metrics.append(metric(
            key: "METRIC-TIME-TO-CHARGE",
            name: "充电所需时间",
            value: Double(minutes ?? 0),
            text: timeText
        ))

        if let maximumCapacity {
            metrics.append(metric(
                key: "METRIC-MAX-CAPACITY",
                name: "最大容量",
                value: Double(maximumCapacity),
                text: "\(maximumCapacity) mAh"
            ))
        }

        if let designCapacity {
            metrics.append(metric(
                key: "METRIC-DESIGN-CAPACITY",
                name: "设计容量",
                value: Double(designCapacity),
                text: "\(designCapacity) mAh"
            ))
        }

        return metrics
    }

    private func readSpeedLimit() -> SensorReading {
        if lastSpeedLimitRead == nil || Date().timeIntervalSince(lastSpeedLimitRead!) >= 15 {
            cachedSpeedLimit = querySpeedLimit()
            lastSpeedLimitRead = Date()
        }
        let text = cachedSpeedLimit.map { "\($0) %" } ?? "不可用"
        return SensorReading(
            key: "METRIC-SPEED-LIMIT",
            name: "速度限制",
            kind: .system,
            value: Double(cachedSpeedLimit ?? "") ?? 0,
            formattedValueOverride: text
        )
    }

    private func querySpeedLimit() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "therm"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(separator: "\n") where line.localizedCaseInsensitiveContains("Speed") {
            let digits = line.filter(\.isNumber)
            if !digits.isEmpty { return String(digits) }
        }
        return nil
    }

    private func adapterWatts(properties: [String: Any]) -> Double? {
        if let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
           let watts = number(details[kIOPSPowerAdapterWattsKey as String]) ?? number(details["Watts"]) {
            return watts
        }
        if let details = properties["AdapterDetails"] as? [String: Any] {
            return number(details["Watts"])
        }
        return nil
    }

    private func timeToFullCharge() -> Int? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] else { continue }
            if let minutes = integer(description[kIOPSTimeToFullChargeKey as String]) {
                return minutes
            }
        }
        return nil
    }

    private func metric(key: String, name: String, value: Double, text: String) -> SensorReading {
        SensorReading(
            key: key,
            name: name,
            kind: .battery,
            value: value,
            formattedValueOverride: text
        )
    }

    private func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours == 0 { return "\(remainingMinutes) 分钟" }
        if remainingMinutes == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(remainingMinutes) 分钟"
    }

    private func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
