import ScreenSaver
import Foundation
import SwiftUI
import Combine

private let logQueue = DispatchQueue(label: "weather.saver.log")
private var logMessages: [String] = []
private let maxLogMessages = 20

func addLog(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let entry = "[\(timestamp)] \(message)"
    logQueue.sync {
        logMessages.append(entry)
        if logMessages.count > maxLogMessages {
            logMessages.removeFirst(logMessages.count - maxLogMessages)
        }
    }
    NSLog("WeatherSaver: \(message)")
}

/// Layer-hosting view for the animated weather background.
private final class SceneHostView: NSView {
    let scene = WeatherScene()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = scene.rootLayer
        wantsLayer = true
        scene.resize(to: frameRect.size)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scene.resize(to: newSize)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scene.contentsScale = window?.backingScaleFactor ?? 2
    }
}

@objc(WeatherSaverView)
public final class WeatherSaverView: ScreenSaverView {

    private let client = BrightSkyClient()
    private let sceneHost: SceneHostView
    private let card = WeatherCardView(frame: .zero)

    private var snapshot: WeatherSnapshot?
    private var isFetching = false
    private var lastFetchAttempt = Date.distantPast
    private var lastMinute = -1
    private var lastSceneUpdate = Date.distantPast
    private var configureSheetController: ConfigurationSheetController?
    private var settingsCancellable: AnyCancellable?
    private var lastFetchSettings = ""
    private let startTime = Date()

    private var preferences: WeatherPreferences { .shared }

    public override init?(frame: NSRect, isPreview: Bool) {
        sceneHost = SceneHostView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        sceneHost = SceneHostView(frame: .zero)
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        addLog("WeatherSaverView initialized frame: \(frame), isPreview: \(isPreview)")
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true

        sceneHost.frame = bounds
        sceneHost.autoresizingMask = [.width, .height]
        addSubview(sceneHost)
        addSubview(card)

        updateCardOptions()
        lastFetchSettings = fetchSettingsKey
        updateScene(animated: false)
        layoutCard(animated: false)
        fetchWeather()

        settingsCancellable = preferences.objectWillChange
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.preferencesChanged() }
    }

    public override var animationTimeInterval: TimeInterval {
        get { 1.0 / 30.0 }
        set { super.animationTimeInterval = newValue }
    }

    public override var isOpaque: Bool { true }

    public override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutCard(animated: false)
    }

    // MARK: Animation loop

    public override func animateOneFrame() {
        let now = Date()
        if now.timeIntervalSince(lastFetchAttempt) >= preferences.updateInterval {
            fetchWeather()
        }

        sceneHost.scene.tick()

        let minute = Calendar.current.component(.minute, from: now)
        if minute != lastMinute {
            lastMinute = minute
            card.refreshClock()
        }
        // Sun position / sky colours and the anti burn-in drift change slowly.
        if now.timeIntervalSince(lastSceneUpdate) >= 30 {
            lastSceneUpdate = now
            updateScene(animated: true)
            layoutCard(animated: true)
        }
    }

    // MARK: Layout

    private var uiScale: CGFloat {
        let s = min(bounds.width / 1500, bounds.height / 950)
        return max(0.3, min(1.35, s))
    }

    private func layoutCard(animated: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        card.scale = isPreview ? max(0.3, min(1, bounds.height / 300)) : uiScale
        let size = card.preferredSize(in: bounds.size)

        // Very slow drift so that nothing stays on exactly the same pixels for hours.
        let t = Date().timeIntervalSince(startTime)
        let amplitude = isPreview ? 0 : min(bounds.width, bounds.height) * 0.035
        let dx = CGFloat(sin(t / 900 * 2 * .pi)) * amplitude
        let dy = CGFloat(sin(t / 1300 * 2 * .pi + 1)) * amplitude * 0.7

        let origin = CGPoint(x: (bounds.width - size.width) / 2 + dx, y: (bounds.height - size.height) / 2 + dy)
        let target = CGRect(origin: origin, size: size).integral
        if animated && card.frame.size == target.size {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 6
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                card.animator().frame = target
            }
        } else {
            card.frame = target
        }
    }

    // MARK: State → views

    private var effectiveDate: Date { SceneClock.now }

    private func updateScene(animated: Bool) {
        let snap = snapshot ?? .placeholder
        let date = effectiveDate
        let elevation = Astronomy.solarElevation(date: date, latitude: preferences.latitude, longitude: preferences.longitude)

        var intensity = snap.condition.basePrecipitation
        if intensity > 0, snap.precipitation > 0, !snap.isSimulated {
            intensity = min(1, 0.25 + log2(1 + snap.precipitation) * 0.3)
        }
        var cover = snapshot == nil ? snap.condition.defaultCloudCover : snap.cloudCover / 100
        if snap.condition.hasDeck { cover = max(cover, 0.9) }
        if snap.condition == .clear { cover = min(cover, 0.15) }

        let state = SceneState(
            condition: snap.condition,
            cloudCover: cover,
            precipitation: intensity,
            windSpeed: snap.windSpeed,
            windDirection: snap.windDirection,
            sunElevation: elevation,
            moonPhase: Astronomy.moonPhase(date: date),
            cloudOpacity: preferences.cloudOpacity,
            animationSpeed: preferences.animationSpeed
        )
        sceneHost.scene.apply(state, animated: animated)
        card.isNight = elevation < -0.8
    }

    private func updateCardOptions() {
        var o = WeatherCardView.Options()
        o.showForecast = preferences.showForecast
        o.showDetails = preferences.showDetails
        o.showLocation = preferences.showLocationName
        o.metric = preferences.useMetricUnits
        o.glossy = preferences.glossyCard
        #if DEBUG
        if let glossy = ProcessInfo.processInfo.environment["WEATHERSAVER_GLOSSY"] { o.glossy = glossy == "1" }
        #endif
        o.locationName = shortLocationName(preferences.locationName)
        o.compact = isPreview && bounds.height < 400
        card.options = o
    }

    private func shortLocationName(_ name: String) -> String {
        name.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? name
    }

    private var fetchSettingsKey: String {
        "\(preferences.simulateWeather)|\(preferences.simulatedCondition)|\(preferences.latitude)|\(preferences.longitude)|\(simulationOverride ?? "")"
    }

    private func preferencesChanged() {
        updateCardOptions()
        let key = fetchSettingsKey
        if key != lastFetchSettings {
            lastFetchSettings = key
            lastFetchAttempt = .distantPast
            fetchWeather()
        }
        updateScene(animated: true)
        layoutCard(animated: false)
    }

    // MARK: Fetching

    private var simulationOverride: String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["WEATHERSAVER_SIMULATE"]
        #else
        return nil
        #endif
    }

    private func fetchWeather() {
        lastFetchAttempt = Date()
        if let condition = simulationOverride ?? (preferences.simulateWeather ? preferences.simulatedCondition : nil) {
            apply(snapshot: Self.simulatedSnapshot(for: condition))
            return
        }
        guard !isFetching else { return }
        isFetching = true
        let latitude = preferences.latitude, longitude = preferences.longitude
        addLog("Fetching weather for \(latitude), \(longitude)")

        Task {
            do {
                let data = try await client.fetchWeatherData(for: latitude, longitude: longitude, timeZone: .current)
                addLog("Weather data received: \(data.count) entries")
                await MainActor.run {
                    if let snap = Self.snapshot(from: data) { self.apply(snapshot: snap) }
                    self.isFetching = false
                }
            } catch {
                addLog("Weather fetch failed: \(error)")
                await MainActor.run { self.isFetching = false }
            }
        }
    }

    private func apply(snapshot newSnapshot: WeatherSnapshot) {
        snapshot = newSnapshot
        card.snapshot = newSnapshot
        updateScene(animated: true)
        layoutCard(animated: false)
    }

    private static func isNight(icon: String) -> Bool? {
        if icon.hasSuffix("-night") { return true }
        if icon.hasSuffix("-day") { return false }
        return nil
    }

    private static func snapshot(from data: [WeatherData]) -> WeatherSnapshot? {
        let now = Date()
        guard let current = data.min(by: { abs($0.timestamp.timeIntervalSince(now)) < abs($1.timestamp.timeIntervalSince(now)) }) else {
            addLog("processWeatherData: no current data")
            return nil
        }
        let calendar = Calendar.current
        let todayTemps = data.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }.compactMap(\.temperature)

        let hourly = data
            .filter { $0.timestamp > now }
            .sorted { $0.timestamp < $1.timestamp }
            .prefix(6)
            .map { entry in
                HourlyForecast(
                    date: entry.timestamp,
                    condition: SkyCondition(icon: entry.icon, weatherCode: entry.weatherCode, cloudCover: entry.cloud, precipitation: entry.amount),
                    isNight: isNight(icon: entry.icon) ?? false,
                    temperature: entry.temperature,
                    precipitation: entry.amount,
                    probability: entry.probability
                )
            }

        addLog("Current: icon=\(current.icon) code=\(current.weatherCode) temp=\(current.temperature ?? .nan) cloud=\(current.cloud)")
        return WeatherSnapshot(
            condition: SkyCondition(icon: current.icon, weatherCode: current.weatherCode, cloudCover: current.cloud, precipitation: current.amount),
            isNightIcon: isNight(icon: current.icon),
            temperature: current.temperature,
            windSpeed: current.windSpeed,
            windDirection: current.windDirection,
            pressure: current.pressure,
            cloudCover: current.cloud,
            precipitation: current.amount,
            humidity: current.humidity,
            dayHigh: todayTemps.max(),
            dayLow: todayTemps.min(),
            hourly: Array(hourly),
            updated: now,
            isSimulated: false
        )
    }

    private static func simulatedSnapshot(for name: String) -> WeatherSnapshot {
        let condition = SkyCondition(icon: name)
        let base: Double
        let humidity: Double
        let wind: Double
        switch condition {
        case .clear: (base, humidity, wind) = (23, 45, 2.5)
        case .partlyCloudy: (base, humidity, wind) = (19, 55, 3.5)
        case .cloudy, .overcast: (base, humidity, wind) = (14, 72, 4.5)
        case .fog: (base, humidity, wind) = (7, 97, 1.2)
        case .drizzle, .rain: (base, humidity, wind) = (12, 88, 5)
        case .heavyRain: (base, humidity, wind) = (13, 94, 8)
        case .sleet: (base, humidity, wind) = (1, 90, 6)
        case .snow, .heavySnow: (base, humidity, wind) = (-2, 85, 3)
        case .thunderstorm: (base, humidity, wind) = (21, 86, 9)
        }
        let precip: Double = [.drizzle: 0.2, .rain: 2.4, .heavyRain: 7.5, .sleet: 1.2, .snow: 0.8, .heavySnow: 3, .thunderstorm: 9][condition] ?? 0
        let now = SceneClock.now
        let startHour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        // Plausible chance of precipitation: high when it is wet, small otherwise.
        let baseChance: Double = precip > 0 ? 0.75 : (condition == .clear ? 0.02 : 0.12)
        let hourly = (1...6).map { i -> HourlyForecast in
            let date = startHour.addingTimeInterval(Double(i) * 3600)
            let hour = Calendar.current.component(.hour, from: date)
            return HourlyForecast(
                date: date,
                condition: condition,
                isNight: hour < 7 || hour >= 19,
                temperature: base + sin(Double(i) * 0.7) * 1.5 - Double(i) * 0.3,
                precipitation: precip * (0.6 + 0.4 * sin(Double(i))),
                probability: min(1, max(0, baseChance + sin(Double(i) * 1.3) * (precip > 0 ? 0.15 : 0.06)))
            )
        }
        return WeatherSnapshot(
            condition: condition,
            isNightIcon: nil,
            temperature: base,
            windSpeed: wind,
            windDirection: 250,
            pressure: condition == .clear ? 1024 : (condition.isRain ? 998 : 1012),
            cloudCover: condition.defaultCloudCover * 100,
            precipitation: precip,
            humidity: humidity,
            dayHigh: base + 3,
            dayLow: base - 4,
            hourly: hourly,
            updated: now,
            isSimulated: true
        )
    }

    // MARK: Configuration

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        configureSheetController = ConfigurationSheetController()
        return configureSheetController?.window
    }
}
