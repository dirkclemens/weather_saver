import Foundation

protocol WeatherProvider {
    func fetchWeatherData(for latitude: Double, longitude: Double, timeZone: TimeZone) async throws -> [WeatherData]
}

struct WeatherData {
    let timestamp: Date
    let probability: Double?   // 0…1, nil when the source does not provide it
    let amount: Double
    let temperature: Double?
    let cloud: Double
    let humidity: Double
    let pressure: Double
    let icon: String
    let windSpeed: Double
    let windDirection: Double?
    let weatherCode: String
    let source: String
    let color: String
}