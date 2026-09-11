import Combine
import ServiceManagement
import SwiftUI

enum SensorKind: String, CaseIterable, Identifiable {
    case temperature
    case voltage
    case current
    case power
    case system
    case battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: "温度"
        case .voltage: "电压"
        case .current: "电流"
        case .power: "功耗"
        case .system: "系统"
        case .battery: "电池"
        }
    }

    var unit: String {
        switch self {
        case .temperature: "°C"
        case .voltage: "V"
        case .current: "A"
        case .power: "W"
        case .system, .battery: ""
        }
    }

    var icon: String {
        switch self {
        case .temperature: "thermometer.medium"
        case .voltage: "waveform.path.ecg"
        case .current: "arrow.left.arrow.right"
        case .power: "bolt.fill"
        case .system: "gauge.with.dots.needle.50percent"
        case .battery: "battery.75percent"
        }
    }

    var color: Color {
        switch self {
        case .temperature: .red
        case .voltage: .blue
        case .current: .green
        case .power: .orange
        case .system: .purple
        case .battery: .mint
        }
    }
}

struct SensorReading: Identifiable, Equatable {
    let key: String
    let name: String
    let kind: SensorKind
    let value: Double
    let formattedValueOverride: String?

    init(
        key: String,
        name: String,
        kind: SensorKind,
        value: Double,
        formattedValueOverride: String? = nil
    ) {
        self.key = key
        self.name = name
        self.kind = kind
        self.value = value
        self.formattedValueOverride = formattedValueOverride
    }

    var id: String { key }

    var formattedValue: String {
        if let formattedValueOverride { return formattedValueOverride }
        let precision = kind == .temperature ? 1 : 2
        return value.formatted(.number.precision(.fractionLength(precision))) + " " + kind.unit
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    static let automaticPowerKey = "__automatic__"

    @Published private(set) var sensors: [SensorReading] = []
    @Published private(set) var averagePower: Double?
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isUsingFallback = false
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginRequiresApproval: Bool
    @Published private(set) var launchAtLoginError: String?
    @Published var selectedSensorKeys: Set<String> {
        didSet {
            defaults.set(Array(selectedSensorKeys).sorted(), forKey: Self.selectedSensorsDefaultsKey)
            hasStoredSelection = true
        }
    }
    @Published var menuPowerSensorKey: String {
        didSet {
            defaults.set(menuPowerSensorKey, forKey: Self.menuPowerDefaultsKey)
            powerSamples.removeAll()
            averagePower = nil
            updateAveragePower(from: sensors)
        }
    }
    @Published var refreshInterval: Double {
        didSet {
            defaults.set(refreshInterval, forKey: Self.refreshIntervalDefaultsKey)
            if isMonitoring {
                configureTimer()
            }
        }
    }

    private let reader = SMCReader()
    private let metricsReader = SystemMetricsReader()
    private let defaults = UserDefaults.standard
    private var timerCancellable: AnyCancellable?
    private var isMonitoring = false
    private var isRefreshInProgress = false
    private var monitoringGeneration = 0
    private var powerSamples: [Double] = []
    private let maximumSampleCount = 30
    private static let selectedSensorsDefaultsKey = "selectedSensorKeys"
    private static let menuPowerDefaultsKey = "menuPowerSensorKey"
    private static let refreshIntervalDefaultsKey = "refreshInterval"
    private var hasStoredSelection: Bool

    init() {
        let defaults = UserDefaults.standard
        hasStoredSelection = defaults.object(forKey: Self.selectedSensorsDefaultsKey) != nil
        selectedSensorKeys = Set(defaults.stringArray(forKey: Self.selectedSensorsDefaultsKey) ?? [])
        menuPowerSensorKey = defaults.string(forKey: Self.menuPowerDefaultsKey) ?? Self.automaticPowerKey
        let storedInterval = defaults.double(forKey: Self.refreshIntervalDefaultsKey)
        refreshInterval = storedInterval > 0 ? storedInterval : 2
        let loginItemStatus = SMAppService.mainApp.status
        launchAtLoginEnabled = loginItemStatus == .enabled
        launchAtLoginRequiresApproval = loginItemStatus == .requiresApproval
        launchAtLoginError = nil
    }

    var displayedSensors: [SensorReading] {
        sensors.filter { selectedSensorKeys.contains($0.key) }
    }

    var powerSensors: [SensorReading] {
        sensors.filter { $0.kind == .power }
    }

    func setSensor(_ key: String, isVisible: Bool) {
        if isVisible {
            selectedSensorKeys.insert(key)
        } else {
            selectedSensorKeys.remove(key)
        }
    }

    func setAllSensors(_ sensors: [SensorReading], isVisible: Bool) {
        var keys = selectedSensorKeys
        if isVisible {
            keys.formUnion(sensors.map(\.key))
        } else {
            keys.subtract(sensors.map(\.key))
        }
        selectedSensorKeys = keys
    }

    func restoreRecommendedSensors() {
        selectedSensorKeys = recommendedSensorKeys(from: sensors)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil

        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }

        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled
        launchAtLoginRequiresApproval = status == .requiresApproval
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        monitoringGeneration += 1
        refreshNow()
        configureTimer()
    }

    func stopMonitoring() {
        isMonitoring = false
        monitoringGeneration += 1
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    private func configureTimer() {
        timerCancellable?.cancel()
        timerCancellable = Timer.publish(every: refreshInterval, tolerance: min(0.5, refreshInterval / 4), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshNow() }
    }

    var menuBarTitle: String {
        guard let averagePower else { return "-- W" }
        return averagePower.formatted(.number.precision(.fractionLength(1))) + " W"
    }

    var lastRefreshText: String {
        guard let lastUpdated else { return isLoading ? "正在刷新" : "尚未刷新" }
        return "上次刷新 \(lastUpdated.formatted(date: .omitted, time: .standard))"
    }

    func refreshNow() {
        // Sensor and power source APIs can block while talking to the hardware.
        // Keep them off the main actor so opening the menu bar window stays smooth.
        guard !isRefreshInProgress else { return }
        isRefreshInProgress = true
        isLoading = sensors.isEmpty

        let reader = self.reader
        let metricsReader = self.metricsReader
        let generation = monitoringGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<[SensorReading], Error>
            do {
                result = .success(try reader.readAllSensors() + metricsReader.readMetrics())
            } catch {
                result = .failure(error)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRefreshInProgress = false
                // The menu may have been closed while hardware access was in progress.
                // Ignore stale results so closing the menu truly stops monitoring.
                guard self.isMonitoring, self.monitoringGeneration == generation else {
                    // If the menu was reopened, immediately start a fresh sample.
                    if self.isMonitoring { self.refreshNow() }
                    return
                }
                self.applyRefreshResult(result)
            }
        }
    }

    private func applyRefreshResult(_ result: Result<[SensorReading], Error>) {
        switch result {
        case .success(let readings):
            sensors = readings.sorted {
                if $0.kind != $1.kind {
                    return SensorKind.allCases.firstIndex(of: $0.kind)! < SensorKind.allCases.firstIndex(of: $1.kind)!
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if !hasStoredSelection {
                selectedSensorKeys = recommendedSensorKeys(from: sensors)
            }
            updateAveragePower(from: readings)
            errorMessage = nil
            isUsingFallback = reader.isUsingRegistryFallback
            lastUpdated = Date()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func updateAveragePower(from readings: [SensorReading]) {
        let powerReadings = readings.filter { $0.kind == .power && $0.value >= 0 }
        let selectedPower = powerReadings.first { $0.key == menuPowerSensorKey }?.value
        guard let systemPower = selectedPower ?? preferredSystemPower(in: powerReadings) else { return }

        powerSamples.append(systemPower)
        if powerSamples.count > maximumSampleCount {
            powerSamples.removeFirst(powerSamples.count - maximumSampleCount)
        }
        averagePower = powerSamples.reduce(0, +) / Double(powerSamples.count)
    }

    private func preferredSystemPower(in readings: [SensorReading]) -> Double? {
        let priorityKeys = ["PSTR", "PST0", "Ptot", "PCPC", "PCTR"]
        for key in priorityKeys {
            if let reading = readings.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                return reading.value
            }
        }

        let energyModel = readings.filter { $0.key.hasPrefix("IO-") }
        if !energyModel.isEmpty {
            return energyModel.reduce(0) { $0 + $1.value }
        }

        // The total rail is normally the largest power reading when no standard total key exists.
        return readings.map(\.value).max()
    }

    private func recommendedSensorKeys(from readings: [SensorReading]) -> Set<String> {
        var keys: Set<String> = []
        for kind in SensorKind.allCases {
            keys.formUnion(readings.filter { $0.kind == kind }.prefix(2).map(\.key))
        }
        if let totalPower = readings.first(where: { ["PSTR", "PST0", "Ptot"].contains($0.key) }) {
            keys.insert(totalPower.key)
        }
        return keys
    }
}
