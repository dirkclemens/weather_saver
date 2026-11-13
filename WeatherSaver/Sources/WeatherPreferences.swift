import Foundation
import ScreenSaver
import Combine

public final class WeatherPreferences: ObservableObject {
    public static let shared = WeatherPreferences()
    public static let moduleName = "com.weathersaver.screensaver"

    private let defaults: UserDefaults

    @Published public var latitude: Double {
        didSet {
            defaults.set(latitude, forKey: Keys.latitude)
            defaults.synchronize()
        }
    }

    @Published public var longitude: Double {
        didSet {
            defaults.set(longitude, forKey: Keys.longitude)
            defaults.synchronize()
        }
    }

    @Published public var locationName: String {
        didSet {
            defaults.set(locationName, forKey: Keys.locationName)
            defaults.synchronize()
        }
    }

    @Published public var updateInterval: Double {
        didSet {
            defaults.set(updateInterval, forKey: Keys.updateInterval)
            defaults.synchronize()
        }
    }

    @Published public var showForecast: Bool {
        didSet {
            defaults.set(showForecast, forKey: Keys.showForecast)
            defaults.synchronize()
        }
    }

    @Published public var showDetails: Bool {
        didSet {
            defaults.set(showDetails, forKey: Keys.showDetails)
            defaults.synchronize()
        }
    }

    @Published public var animationSpeed: Double {
        didSet {
            defaults.set(animationSpeed, forKey: Keys.animationSpeed)
            defaults.synchronize()
        }
    }

    @Published public var cloudOpacity: Double {
        didSet {
            defaults.set(cloudOpacity, forKey: Keys.cloudOpacity)
            defaults.synchronize()
        }
    }

    @Published public var useMetricUnits: Bool {
        didSet {
            defaults.set(useMetricUnits, forKey: Keys.useMetricUnits)
            defaults.synchronize()
        }
    }

    @Published public var showLocationName: Bool {
        didSet {
            defaults.set(showLocationName, forKey: Keys.showLocationName)
            defaults.synchronize()
        }
    }

    @Published public var glossyCard: Bool {
        didSet {
            defaults.set(glossyCard, forKey: Keys.glossyCard)
            defaults.synchronize()
        }
    }

    @Published public var simulateWeather: Bool {
        didSet {
            defaults.set(simulateWeather, forKey: Keys.simulateWeather)
            defaults.synchronize()
        }
    }

    @Published public var simulatedCondition: String {
        didSet {
            defaults.set(simulatedCondition, forKey: Keys.simulatedCondition)
            defaults.synchronize()
        }
    }

    private enum Keys {
        static let latitude = "WeatherLatitude"
        static let longitude = "WeatherLongitude"
        static let locationName = "WeatherLocationName"
        static let updateInterval = "WeatherUpdateInterval"
        static let showForecast = "WeatherShowForecast"
        static let showDetails = "WeatherShowDetails"
        static let animationSpeed = "WeatherAnimationSpeed"
        static let cloudOpacity = "WeatherCloudOpacity"
        static let useMetricUnits = "WeatherUseMetricUnits"
        static let showLocationName = "WeatherShowLocationName"
        static let glossyCard = "WeatherGlossyCard"
        static let simulateWeather = "WeatherSimulateWeather"
        static let simulatedCondition = "WeatherSimulatedCondition"
    }

    public init() {
        if let screenSaverDefaults = ScreenSaverDefaults(forModuleWithName: WeatherPreferences.moduleName) {
            self.defaults = screenSaverDefaults
        } else {
            self.defaults = UserDefaults.standard
        }

        var lat = defaults.double(forKey: Keys.latitude)
        if lat == 0 { lat = 51.2 }
        self.latitude = lat

        var lon = defaults.double(forKey: Keys.longitude)
        if lon == 0 { lon = 6.69 }
        self.longitude = lon

        self.locationName = defaults.string(forKey: Keys.locationName) ?? "Meerbusch, Germany"

        var interval = defaults.double(forKey: Keys.updateInterval)
        if interval <= 0 { interval = 300.0 }
        self.updateInterval = interval

        self.showForecast = defaults.object(forKey: Keys.showForecast) != nil
            ? defaults.bool(forKey: Keys.showForecast) : true

        self.showDetails = defaults.object(forKey: Keys.showDetails) != nil
            ? defaults.bool(forKey: Keys.showDetails) : true

        var speed = defaults.double(forKey: Keys.animationSpeed)
        if speed <= 0 { speed = 1.0 }
        self.animationSpeed = speed

        var opacity = defaults.double(forKey: Keys.cloudOpacity)
        if opacity <= 0 { opacity = 1.0 }
        self.cloudOpacity = opacity

        self.useMetricUnits = defaults.object(forKey: Keys.useMetricUnits) != nil
            ? defaults.bool(forKey: Keys.useMetricUnits) : true

        self.showLocationName = defaults.object(forKey: Keys.showLocationName) != nil
            ? defaults.bool(forKey: Keys.showLocationName) : true

        self.glossyCard = defaults.bool(forKey: Keys.glossyCard)

        self.simulateWeather = defaults.object(forKey: Keys.simulateWeather) != nil
            ? defaults.bool(forKey: Keys.simulateWeather) : false

        self.simulatedCondition = defaults.string(forKey: Keys.simulatedCondition) ?? "sunny"
    }
}
