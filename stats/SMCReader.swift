import Foundation
import IOKit

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    // AppleSMC expects result at byte offset 40 in this C-compatible payload.
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

private struct SMCValue {
    let dataType: String
    let bytes: [UInt8]
}

enum SMCError: LocalizedError {
    case serviceNotFound
    case connectionFailed(kern_return_t)
    case callFailed(kern_return_t)
    case noSensors

    var errorDescription: String? {
        switch self {
        case .serviceNotFound:
            "未找到 AppleSMC 服务。此 Mac 可能不提供 SMC 传感器接口。"
        case .connectionFailed:
            "无法连接 AppleSMC。请确认应用未启用 App Sandbox。"
        case .callFailed:
            "AppleSMC 返回了读取错误。"
        case .noSensors:
            "没有发现可读取的温度、电压、电流或功耗传感器。"
        }
    }
}

final class SMCReader {
    private let readBytesCommand: UInt8 = 5
    private let readIndexCommand: UInt8 = 8
    private let readKeyInfoCommand: UInt8 = 9
    private let userClientSelector: UInt32 = 2

    private var connection: io_connect_t = 0
    private var sensorKeys: [(key: String, kind: SensorKind)]?
    private let platformReader = PlatformSensorReader()
    private(set) var isUsingRegistryFallback = false

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func readAllSensors() throws -> [SensorReading] {
        do {
            try openIfNeeded()

            if sensorKeys == nil {
                sensorKeys = try discoverSensorKeys()
            }

            let readings = sensorKeys?.compactMap { item -> SensorReading? in
                guard let value = try? readValue(item.key),
                      let number = decode(value),
                      number.isFinite,
                      isPlausible(number, for: item.kind) else {
                    return nil
                }

                return SensorReading(
                    key: item.key,
                    name: SensorName.name(for: item.key, kind: item.kind),
                    kind: item.kind,
                    value: number
                )
            } ?? []

            let combined = deduplicated(readings + platformReader.readAllSensors())
            guard !combined.isEmpty else { throw SMCError.noSensors }
            isUsingRegistryFallback = false
            return combined
        } catch {
            let fallback = deduplicated(RegistrySensorReader.readAllSensors() + platformReader.readAllSensors())
            guard !fallback.isEmpty else { throw error }
            isUsingRegistryFallback = true
            return fallback
        }
    }

    private func deduplicated(_ readings: [SensorReading]) -> [SensorReading] {
        var seen: Set<String> = []
        return readings.filter { seen.insert($0.key).inserted }
    }

    private func openIfNeeded() throws {
        guard connection == 0 else { return }
        guard let matching = IOServiceMatching("AppleSMC") else { throw SMCError.serviceNotFound }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else {
            connection = 0
            throw SMCError.connectionFailed(result)
        }
    }

    private func discoverSensorKeys() throws -> [(key: String, kind: SensorKind)] {
        let countValue = try readValue("#KEY")
        guard let count = decodeUnsignedInteger(countValue), count > 0 else {
            throw SMCError.noSensors
        }

        var result: [(key: String, kind: SensorKind)] = []
        for index in 0..<min(count, 10_000) {
            guard let key = try? key(at: UInt32(index)),
                  let kind = sensorKind(for: key) else { continue }
            result.append((key: key, kind: kind))
        }
        return result
    }

    private func key(at index: UInt32) throws -> String {
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.data8 = readIndexCommand
        input.data32 = index
        try call(input: &input, output: &output)
        return fourCCString(output.key)
    }

    private func readValue(_ key: String) throws -> SMCValue {
        var infoInput = SMCKeyData()
        var infoOutput = SMCKeyData()
        infoInput.key = fourCC(key)
        infoInput.data8 = readKeyInfoCommand
        try call(input: &infoInput, output: &infoOutput)

        var readInput = SMCKeyData()
        var readOutput = SMCKeyData()
        readInput.key = fourCC(key)
        readInput.keyInfo.dataSize = infoOutput.keyInfo.dataSize
        readInput.data8 = readBytesCommand
        try call(input: &readInput, output: &readOutput)

        let allBytes = withUnsafeBytes(of: readOutput.bytes) { Array($0) }
        let size = min(Int(infoOutput.keyInfo.dataSize), allBytes.count)
        return SMCValue(
            dataType: fourCCString(infoOutput.keyInfo.dataType),
            bytes: Array(allBytes.prefix(size))
        )
    }

    private func call(input: inout SMCKeyData, output: inout SMCKeyData) throws {
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(
            connection,
            userClientSelector,
            &input,
            MemoryLayout<SMCKeyData>.stride,
            &output,
            &outputSize
        )
        guard result == KERN_SUCCESS else { throw SMCError.callFailed(result) }
    }

    private func sensorKind(for key: String) -> SensorKind? {
        guard let prefix = key.first else { return nil }
        switch prefix {
        case "T": return .temperature
        case "V": return .voltage
        case "I": return .current
        case "P": return .power
        default: return nil
        }
    }

    private func isPlausible(_ value: Double, for kind: SensorKind) -> Bool {
        switch kind {
        case .temperature: (-30...180).contains(value)
        case .voltage: (-1...100).contains(value)
        case .current: (-500...500).contains(value)
        case .power: (-10...2_000).contains(value)
        case .system, .battery: false
        }
    }

    private func decode(_ value: SMCValue) -> Double? {
        let bytes = value.bytes
        switch value.dataType {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            var float: Float = 0
            withUnsafeMutableBytes(of: &float) { destination in
                destination.copyBytes(from: bytes.prefix(4))
            }
            return Double(float)
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(uint16(bytes))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(uint32(bytes))
        case "si8 ":
            return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: uint16(bytes)))
        case "si32":
            guard bytes.count >= 4 else { return nil }
            return Double(Int32(bitPattern: uint32(bytes)))
        default:
            return decodeFixedPoint(bytes: bytes, type: value.dataType)
        }
    }

    private func decodeUnsignedInteger(_ value: SMCValue) -> Int? {
        guard let decoded = decode(value), decoded >= 0 else { return nil }
        return Int(decoded)
    }

    private func decodeFixedPoint(bytes: [UInt8], type: String) -> Double? {
        guard bytes.count >= 2, type.count == 4 else { return nil }
        let chars = Array(type)
        guard chars[0] == "f" || chars[0] == "s" else { return nil }
        guard let fractionalBits = Int(String(chars[3]), radix: 16) else { return nil }

        let raw = uint16(bytes)
        let divisor = pow(2.0, Double(fractionalBits))
        if chars[0] == "s" {
            return Double(Int16(bitPattern: raw)) / divisor
        }
        return Double(raw) / divisor
    }

    private func uint16(_ bytes: [UInt8]) -> UInt16 {
        (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    private func uint32(_ bytes: [UInt8]) -> UInt32 {
        (UInt32(bytes[0]) << 24) |
        (UInt32(bytes[1]) << 16) |
        (UInt32(bytes[2]) << 8) |
        UInt32(bytes[3])
    }

    private func fourCC(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func fourCCString(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

/// AppleSMC is a privileged user client on recent macOS releases. Battery
/// values remain available through the public IORegistry and provide a useful
/// no-helper fallback for portable Macs.
private enum RegistrySensorReader {
    static func readAllSensors() -> [SensorReading] {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [SensorReading] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let properties = properties(for: service) else { continue }
            result.append(contentsOf: readings(from: properties))
        }
        return result
    }

    private static func properties(for service: io_service_t) -> [String: Any]? {
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = raw?.takeRetainedValue() as? [String: Any] else { return nil }
        return dictionary
    }

    private static func readings(from properties: [String: Any]) -> [SensorReading] {
        var result: [SensorReading] = []
        let batteryData = properties["BatteryData"] as? [String: Any]

        if let rawTemperature = number(properties["Temperature"]) {
            let celsius = rawTemperature / 100.0
            if (-30...100).contains(celsius) {
                result.append(SensorReading(key: "BAT-TEMP", name: "电池温度", kind: .temperature, value: celsius))
            }
        }

        if let rawVoltage = number(properties["Voltage"]) {
            let volts = rawVoltage / 1000.0
            if (0...100).contains(volts) {
                result.append(SensorReading(key: "BAT-VOLT", name: "电池电压", kind: .voltage, value: volts))
            }
        }

        if let chargerData = properties["ChargerData"] as? [String: Any] {
            if let chargingVoltage = number(chargerData["ChargingVoltage"]), chargingVoltage > 0 {
                result.append(SensorReading(key: "CHG-VOLT", name: "充电器电压", kind: .voltage, value: chargingVoltage / 1000.0))
            }
            if let chargingCurrent = signedNumber(chargerData["ChargingCurrent"]), chargingCurrent != 0 {
                result.append(SensorReading(key: "CHG-CURR", name: "充电器电流", kind: .current, value: chargingCurrent / 1000.0))
            }
        }

        if let rawCurrent = signedNumber(properties["InstantAmperage"] ?? properties["Amperage"]) {
            let amps = rawCurrent / 1000.0
            if (-500...500).contains(amps) {
                result.append(SensorReading(key: "BAT-CURR", name: "电池电流", kind: .current, value: amps))
                if let volts = result.first(where: { $0.kind == .voltage })?.value {
                    result.append(SensorReading(key: "BAT-POWER", name: "电池功耗（回退）", kind: .power, value: abs(volts * amps)))
                }
            }
        }

        // Some Intel Macs publish a direct battery-system power estimate in mW.
        if result.first(where: { $0.kind == .power }) == nil,
           let rawSystemPower = number(batteryData?["SystemPower"]), rawSystemPower > 0 {
            result.append(SensorReading(key: "BAT-POWER", name: "电池功耗（回退）", kind: .power, value: rawSystemPower / 1000.0))
        }

        // BatteryData.CellVoltage is published as an array on some Intel Macs.
        if let cells = batteryData?["CellVoltage"] as? [NSNumber] {
            for (index, cell) in cells.enumerated() where cell.doubleValue > 0 {
                result.append(SensorReading(key: "BAT-CELL-\(index + 1)", name: "电池单元 \(index + 1) 电压", kind: .voltage, value: cell.doubleValue / 1000.0))
            }
        }
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }

    private static func signedNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let unsigned = number.uint64Value
        if unsigned > UInt64(Int64.max) {
            return Double(Int64(bitPattern: unsigned))
        }
        return Double(number.int64Value)
    }
}

private enum SensorName {
    private static let exact: [String: String] = [
        "TC0D": "CPU 二极管温度", "TC0E": "CPU 虚拟二极管温度",
        "TC0F": "CPU 滤波温度", "TC0H": "CPU 散热器温度",
        "TC0P": "CPU 近接温度", "TCAD": "CPU 封装温度",
        "TCGC": "Intel GPU 温度", "TG0D": "GPU 二极管温度",
        "TGDD": "AMD GPU 温度", "TG0H": "GPU 散热器温度",
        "TG0P": "GPU 近接温度", "Tm0P": "主板温度",
        "Tp0P": "电源板温度", "TB1T": "电池温度",
        "TW0P": "无线模块温度", "TL0P": "显示器温度",
        "TTLD": "左侧雷雳控制器温度", "TTRD": "右侧雷雳控制器温度",
        "TN0D": "北桥二极管温度", "TN0H": "北桥散热器温度",
        "TN0P": "北桥近接温度",

        "VCAC": "CPU IA 电压", "VCSC": "CPU System Agent 电压",
        "VCTC": "Intel GPU 电压", "VG0C": "GPU 电压",
        "VM0R": "内存电压", "Vb0R": "CMOS 电压",
        "VD0R": "直流输入电压", "VP0R": "12V 电源轨",
        "Vp0C": "12V VCC", "VV2S": "3V 电源轨",
        "VR3R": "3.3V 电源轨", "VV1S": "5V 电源轨",
        "VV9S": "12V 电源轨", "VeES": "PCI 12V 电压",

        "IC0R": "CPU 高侧电流", "IG0R": "GPU 高侧电流",
        "ID0R": "直流输入电流", "IBAC": "电池电流",
        "IDBR": "显示亮度电流", "IU1R": "左侧雷雳控制器电流",
        "IU2R": "右侧雷雳控制器电流",

        "PC0C": "CPU 核心功耗", "PCAM": "CPU 核心功耗（IMON）",
        "PCPC": "CPU 封装功耗", "PCTR": "CPU 总功耗",
        "PCPT": "CPU 封装总功耗", "PCPR": "CPU 封装功耗（SMC）",
        "PC0R": "CPU 计算单元功耗", "PC0G": "CPU 图形单元功耗",
        "PCEC": "CPU eDRAM 功耗", "PCPG": "Intel GPU 功耗",
        "PG0C": "GPU 功耗", "PG0R": "GPU 1 功耗", "PG1R": "GPU 2 功耗",
        "PCGC": "Intel GPU 功耗", "PCGM": "Intel GPU 功耗（IMON）",
        "PC3C": "内存功耗", "PPBR": "电池功耗", "PDTR": "直流输入功耗",
        "PMTR": "内存总功耗", "PSTR": "系统总功耗", "PST0": "系统总功耗",
        "Ptot": "系统总功耗", "PU1R": "左侧雷雳控制器功耗",
        "PU2R": "右侧雷雳控制器功耗"
    ]

    static func name(for key: String, kind: SensorKind) -> String {
        if let name = exact[key] { return name }

        let component: String
        if key.hasPrefix("TC") || key.hasPrefix("PC") || key.hasPrefix("VC") || key.hasPrefix("IC") {
            component = "CPU"
        } else if key.hasPrefix("TG") || key.hasPrefix("PG") || key.hasPrefix("VG") || key.hasPrefix("IG") {
            component = "GPU"
        } else if key.hasPrefix("TB") || key.hasPrefix("PB") || key.hasPrefix("VB") || key.hasPrefix("IB") {
            component = "电池"
        } else if key.hasPrefix("TN") {
            component = "存储"
        } else if key.hasPrefix("TM") || key.hasPrefix("Tm") {
            component = "内存"
        } else if key.hasPrefix("PD") || key.hasPrefix("VD") || key.hasPrefix("ID") {
            component = "直流输入"
        } else {
            component = "系统"
        }
        return component + kind.title + "传感器"
    }
}
