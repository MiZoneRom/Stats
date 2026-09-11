import Foundation

final class PlatformSensorReader {
#if arch(arm64)
    private var channels: CFMutableDictionary?
    private var subscription: UnsafeMutableRawPointer?
    private var previousEnergy: [String: Double] = [:]
    private var previousDate: Date?

    init() {
        guard let copied = StatsIOReportCopyChannels("Energy Model" as CFString, nil) else {
            return
        }
        channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, copied)
        var subscribedChannels: Unmanaged<CFMutableDictionary>?
        subscription = StatsIOReportCreateSubscription(channels, &subscribedChannels)
        subscribedChannels?.release()
    }
#endif

    func readAllSensors() -> [SensorReading] {
#if arch(arm64)
        return readHIDSensors() + readPowerSensors()
#else
        return []
#endif
    }

#if arch(arm64)
    private func readHIDSensors() -> [SensorReading] {
        let presets: [(SensorKind, Int32, Int32, Int32)] = [
            (.temperature, 0xff00, 0x0005, 15),
            (.current, 0xff08, 0x0002, 25),
            (.voltage, 0xff08, 0x0003, 25)
        ]

        return presets.flatMap { kind, page, usage, eventType in
            let values = ReadAppleHIDSensors(page, usage, eventType) ?? [:]
            return values.compactMap { key, rawValue -> SensorReading? in
                guard plausible(rawValue.doubleValue, for: kind) else { return nil }
                return SensorReading(
                    key: "HID-\(kind.rawValue)-\(key)",
                    name: friendlyHIDName(key),
                    kind: kind,
                    value: rawValue.doubleValue
                )
            }
        }
    }

    private func readPowerSensors() -> [SensorReading] {
        guard let subscription, let channels,
              let sample = StatsIOReportCreateSamples(subscription, channels) as? [String: Any],
              let list = sample["IOReportChannels"] as? [Any] else { return [] }

        var current: [String: Double] = [:]
        for rawChannel in list {
            let channel = unsafeBitCast(rawChannel as AnyObject, to: CFDictionary.self)
            guard let rawGroup = StatsIOReportChannelGetGroup(channel),
                  rawGroup as String == "Energy Model",
                  let name = StatsIOReportChannelGetName(channel) as String?,
                  let unit = StatsIOReportChannelGetUnit(channel) as String? else { continue }

            let energy = energyInJoules(Double(StatsIOReportSimpleValue(channel)), unit: unit)
            if name.hasSuffix("CPU Energy") { current["IO-CPU"] = energy }
            else if name.hasSuffix("GPU Energy") { current["IO-GPU"] = energy }
            else if name.hasPrefix("ANE") { current["IO-ANE"] = energy }
            else if name.hasPrefix("DRAM") { current["IO-RAM"] = energy }
            else if name.hasPrefix("PCI") && name.hasSuffix("Energy") { current["IO-PCI"] = energy }
        }

        let now = Date()
        defer {
            previousEnergy = current
            previousDate = now
        }
        guard let previousDate else { return [] }
        let elapsed = now.timeIntervalSince(previousDate)
        guard elapsed > 0 else { return [] }

        let names = [
            "IO-CPU": "CPU 功耗", "IO-GPU": "GPU 功耗", "IO-ANE": "神经网络引擎功耗",
            "IO-RAM": "内存功耗", "IO-PCI": "PCI 功耗"
        ]
        return current.compactMap { key, energy in
            guard let previous = previousEnergy[key], energy >= previous else { return nil }
            let watts = (energy - previous) / elapsed
            guard watts.isFinite, (0...2_000).contains(watts) else { return nil }
            return SensorReading(key: key, name: names[key] ?? key, kind: .power, value: watts)
        }
    }

    private func energyInJoules(_ value: Double, unit: String) -> Double {
        switch unit {
        case "mJ": value / 1_000
        case "uJ": value / 1_000_000
        case "nJ": value / 1_000_000_000
        default: value
        }
    }

    private func plausible(_ value: Double, for kind: SensorKind) -> Bool {
        switch kind {
        case .temperature: (0..<110).contains(value)
        case .voltage: (0..<300).contains(value)
        case .current: (-100..<100).contains(value)
        case .power: (0..<2_000).contains(value)
        case .system, .battery: true
        }
    }

    private func friendlyHIDName(_ name: String) -> String {
        if name.hasPrefix("pACC MTR Temp") { return "CPU 性能核心温度" }
        if name.hasPrefix("eACC MTR Temp") { return "CPU 能效核心温度" }
        if name.hasPrefix("GPU MTR Temp") { return "GPU 核心温度" }
        if name.hasPrefix("SOC MTR Temp") { return "SoC 温度" }
        if name.hasPrefix("ANE MTR Temp") { return "神经网络引擎温度" }
        if name.hasPrefix("PMGR SOC Die Temp") { return "电源管理芯片温度" }
        if name == "gas gauge battery" { return "电池温度" }
        return name
    }
#endif
}
