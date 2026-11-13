import Foundation
import CoreGraphics

// MARK: - Condition

/// Normalised weather condition used by both the animated scene and the info card.
/// Accepts BrightSky icon names (`clear-day`, `partly-cloudy-night`, …) as well as the
/// simplified names used by the simulation mode (`sunny`, `rain`, …).
enum SkyCondition: String, CaseIterable {
    case clear
    case partlyCloudy
    case cloudy
    case overcast
    case fog
    case drizzle
    case rain
    case heavyRain
    case sleet
    case snow
    case heavySnow
    case thunderstorm

    init(icon: String, weatherCode: String? = nil, cloudCover: Double? = nil, precipitation: Double? = nil) {
        let key = icon.lowercased()
            .replacingOccurrences(of: "-day", with: "")
            .replacingOccurrences(of: "-night", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        let amount = precipitation ?? 0

        switch key {
        case "clear", "sunny":
            self = .clear
        case "partlycloudy", "dry":
            self = .partlyCloudy
        case "cloudy":
            self = (cloudCover ?? 0) >= 90 ? .overcast : .cloudy
        case "overcast":
            self = .overcast
        case "fog", "mist":
            self = .fog
        case "drizzle", "lightrain":
            self = .drizzle
        case "rain", "wet":
            if precipitation == nil { self = .rain }
            else if amount < 0.3 { self = .drizzle }
            else if amount >= 4 { self = .heavyRain }
            else { self = .rain }
        case "heavyrain", "hail":
            self = .heavyRain
        case "sleet":
            self = .sleet
        case "snow", "lightsnow":
            self = amount >= 2 ? .heavySnow : .snow
        case "heavysnow":
            self = .heavySnow
        case "thunderstorm":
            self = .thunderstorm
        case "wind":
            let cover = cloudCover ?? 50
            self = cover >= 90 ? .overcast : (cover >= 60 ? .cloudy : .partlyCloudy)
        default:
            switch weatherCode?.lowercased() {
            case "fog": self = .fog
            case "rain": self = .rain
            case "snow": self = .snow
            case "sleet", "hail": self = .sleet
            case "thunderstorm": self = .thunderstorm
            default:
                let cover = cloudCover ?? 30
                self = cover >= 90 ? .overcast : (cover >= 60 ? .cloudy : (cover >= 20 ? .partlyCloudy : .clear))
            }
        }
    }

    var title: String {
        switch self {
        case .clear: return "Clear"
        case .partlyCloudy: return "Partly Cloudy"
        case .cloudy: return "Cloudy"
        case .overcast: return "Overcast"
        case .fog: return "Fog"
        case .drizzle: return "Drizzle"
        case .rain: return "Rain"
        case .heavyRain: return "Heavy Rain"
        case .sleet: return "Sleet"
        case .snow: return "Snow"
        case .heavySnow: return "Heavy Snow"
        case .thunderstorm: return "Thunderstorm"
        }
    }

    func symbolName(isNight: Bool) -> String {
        switch self {
        case .clear: return isNight ? "moon.stars.fill" : "sun.max.fill"
        case .partlyCloudy: return isNight ? "cloud.moon.fill" : "cloud.sun.fill"
        case .cloudy: return isNight ? "cloud.moon.fill" : "cloud.fill"
        case .overcast: return "smoke.fill"
        case .fog: return "cloud.fog.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .rain: return isNight ? "cloud.moon.rain.fill" : "cloud.rain.fill"
        case .heavyRain: return "cloud.heavyrain.fill"
        case .sleet: return "cloud.sleet.fill"
        case .snow, .heavySnow: return "cloud.snow.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        }
    }

    /// 0 = blue sky, 1 = completely grey sky.
    var greyness: CGFloat {
        switch self {
        case .clear: return 0
        case .partlyCloudy: return 0.12
        case .cloudy: return 0.45
        case .overcast: return 0.85
        case .fog: return 0.9
        case .drizzle: return 0.8
        case .rain: return 0.9
        case .heavyRain: return 0.95
        case .sleet: return 0.88
        case .snow: return 0.82
        case .heavySnow: return 0.9
        case .thunderstorm: return 1
        }
    }

    /// How much darker than a plain grey sky the scene is (storm clouds etc.).
    var darkness: CGFloat {
        switch self {
        case .rain: return 0.25
        case .heavyRain: return 0.4
        case .sleet: return 0.25
        case .drizzle: return 0.12
        case .thunderstorm: return 0.6
        case .overcast: return 0.08
        case .snow, .heavySnow: return 0.0
        case .fog: return -0.05
        default: return 0
        }
    }

    /// Default precipitation intensity (0…1) when no measured amount is available.
    var basePrecipitation: Double {
        switch self {
        case .drizzle: return 0.3
        case .rain: return 0.6
        case .heavyRain: return 1.0
        case .sleet: return 0.55
        case .snow: return 0.55
        case .heavySnow: return 1.0
        case .thunderstorm: return 0.95
        default: return 0
        }
    }

    var defaultCloudCover: Double {
        switch self {
        case .clear: return 0.05
        case .partlyCloudy: return 0.35
        case .cloudy: return 0.7
        default: return 1
        }
    }

    var isRain: Bool { [.drizzle, .rain, .heavyRain, .sleet, .thunderstorm].contains(self) }
    var isSnow: Bool { [.snow, .heavySnow, .sleet].contains(self) }
    var hasDeck: Bool { ![.clear, .partlyCloudy, .cloudy].contains(self) }
}

// MARK: - Data model shown on screen

struct HourlyForecast {
    let date: Date
    let condition: SkyCondition
    let isNight: Bool
    let temperature: Double?
    let precipitation: Double      // mm
    let probability: Double?       // 0…1, nil if unknown
}

struct WeatherSnapshot {
    var condition: SkyCondition
    var isNightIcon: Bool?
    var temperature: Double?
    var windSpeed: Double          // m/s
    var windDirection: Double?     // degrees, direction the wind comes from
    var pressure: Double           // hPa
    var cloudCover: Double         // %
    var precipitation: Double      // mm
    var humidity: Double           // %
    var dayHigh: Double?
    var dayLow: Double?
    var hourly: [HourlyForecast]
    var updated: Date
    var isSimulated: Bool

    static let placeholder = WeatherSnapshot(
        condition: .partlyCloudy, isNightIcon: nil, temperature: nil, windSpeed: 3, windDirection: 250,
        pressure: 1013, cloudCover: 35, precipitation: 0, humidity: 60, dayHigh: nil, dayLow: nil,
        hourly: [], updated: Date(), isSimulated: false
    )
}

// MARK: - Astronomy

enum Astronomy {
    /// Approximate solar elevation in degrees (accurate to well under a degree – plenty for sky colours).
    static func solarElevation(date: Date, latitude: Double, longitude: Double) -> Double {
        let rad = Double.pi / 180
        let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
        let n = jd - 2451545.0
        let meanLongitude = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let meanAnomaly = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360) * rad
        let eclipticLongitude = (meanLongitude + 1.915 * sin(meanAnomaly) + 0.020 * sin(2 * meanAnomaly)) * rad
        let obliquity = (23.439 - 0.0000004 * n) * rad
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude))
        let declination = asin(sin(obliquity) * sin(eclipticLongitude))
        var gmst = (18.697374558 + 24.06570982441908 * n).truncatingRemainder(dividingBy: 24)
        if gmst < 0 { gmst += 24 }
        let hourAngle = (gmst * 15 + longitude) * rad - rightAscension
        let lat = latitude * rad
        let elevation = asin(sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hourAngle))
        return elevation / rad
    }

    /// Moon phase 0…1 (0 = new moon, 0.5 = full moon).
    static func moonPhase(date: Date) -> Double {
        let synodicMonth = 29.530588853
        let knownNewMoon = Date(timeIntervalSince1970: 947_182_440) // 2000-01-06 18:14 UTC
        let days = date.timeIntervalSince(knownNewMoon) / 86400
        var phase = (days / synodicMonth).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        return phase
    }
}

// MARK: - Helpers

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double {
        Double(next() & 0xFFFFFFFFFFFF) / Double(0xFFFFFFFFFFFF)
    }
    mutating func range(_ lower: Double, _ upper: Double) -> Double {
        lower + (upper - lower) * unit()
    }
    mutating func cg(_ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        CGFloat(range(Double(lower), Double(upper)))
    }
}

@inline(__always) func clamp01<T: BinaryFloatingPoint>(_ v: T) -> T { min(1, max(0, v)) }

@inline(__always) func smoothstep<T: BinaryFloatingPoint>(_ e0: T, _ e1: T, _ x: T) -> T {
    let t = clamp01((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)
}

// MARK: - Clock

/// The current time for scene and card. Debug builds honour `WEATHERSAVER_HOUR`
/// (a fixed local hour today), so sky, clock and simulated forecast stay consistent
/// in previews and screenshots.
enum SceneClock {
    static var now: Date {
        #if DEBUG
        if let hourString = ProcessInfo.processInfo.environment["WEATHERSAVER_HOUR"], let hour = Double(hourString) {
            return Calendar.current.startOfDay(for: Date()).addingTimeInterval(hour * 3600)
        }
        #endif
        return Date()
    }
}
