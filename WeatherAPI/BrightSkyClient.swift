//
//  BrightSkyClient.swift
//
//  Created by Dirk Clemens on 14.06.25.
//
//  BrightSky API documentation: https://www.brightsky.dev/api
//  https://brightsky.dev/docs/#/%23quickstart
//  https://brightsky.dev/docs/#/operations/getWeather
//  https://api.brightsky.dev/openapi.json
//
// Example response entry:
//    "timestamp": "2025-08-31T00:00:00+00:00",
//    "source_id": 6153,
//    "precipitation": 0,
//    "pressure_msl": 1009.3,
//    "sunshine": 0,
//    "temperature": 16.3,
//    "wind_direction": 150,
//    "wind_speed": 15.1,
//    "cloud_cover": 88,
//    "dew_point": 11.7,
//    "relative_humidity": 74,
//    "visibility": 62300,
//    "wind_gust_direction": null,
//    "wind_gust_speed": 20.9,  //     km / h
//    "condition": "dry",
//    "precipitation_probability": null,
//    "precipitation_probability_6h": null,
//    "solar": 0,
//    "fallback_source_ids": {
//    "sunshine": 6155,
//    "solar": 6155
//    },
//    "icon": "cloudy"


import Foundation
import os

// Wind (gust) speed in BrightSky (units?DWD) is "km/h", so needs conversation to m/s (divide by 3.6)
class BrightSkyClient: WeatherProvider {
    
    let logger = Logger(subsystem: "de.adcore.WeatherSaver", category: "BrightSkyClient")

    func fetchRainData(for latitude: Double, longitude: Double, timeZone: TimeZone, hours: Int) async throws -> [WeatherData] {
        return try await fetchInternal(for: latitude, longitude: longitude, timeZone: timeZone, hours: hours)
    }
    
    func fetchWeatherData(for latitude: Double, longitude: Double, timeZone: TimeZone) async throws -> [WeatherData] {
        return try await fetchInternal(for: latitude, longitude: longitude, timeZone: timeZone, hours: 240)
    }
    
    private func fetchInternal(for latitude: Double, longitude: Double, timeZone: TimeZone, hours: Int) async throws -> [WeatherData] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = timeZone

        // Set 'now' to today at 00:00
        let calendar = Calendar.current
        var calendarWithTZ = calendar
        calendarWithTZ.timeZone = timeZone
        let now = calendarWithTZ.startOfDay(for: Date())
        let endDate = calendarWithTZ.date(byAdding: .hour, value: hours, to: now) ?? now
        let todayString = dateFormatter.string(from: now) // ISO-8601 format
        let lastdayString = dateFormatter.string(from: endDate) // ISO-8601 format

        let urlString = "https://api.brightsky.dev/weather?lat=\(latitude)&lon=\(longitude)&units=dwd&date=\(todayString)&last_date=\(lastdayString)&max_dist=50000"//&tz=\(timeZone.identifier)"
        
        logger.debug("📡 BrightSky request: \(urlString)")

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(BrightSkyResponse.self, from: data)

        let isoFormatter = ISO8601DateFormatter()
        let logFormatter = DateFormatter()
        logFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let results = decoded.weather.compactMap { entry -> WeatherData? in
            guard let date = isoFormatter.date(from: entry.timestamp),
                  date >= now && date <= endDate else { return nil }

            let normalizedDate = calendarWithTZ.date(bySetting: .second, value: 0, of: date) ?? date

//            logger.debug("  BrightSky Entry – timestamp: \(normalizedDate), precip: \(entry.precipitation_probability ?? 0) %, amount: \(entry.precipitation ?? 0), temp: \(entry.temperature ?? -999), cloud: \(entry.cloud_cover ?? 0), humidity: \(entry.relative_humidity ?? 0), pressure: \(entry.pressure_msl ?? 0), icon: \(entry.icon ?? "unknown" )" )
//            BrightSky Entry – timestamp: 2025-10-11 00:00:00 +0000, precip: 0.000000 %, amount: 0.000000, temp: 14.800000, cloud: 100.000000, humidity: 87.000000, pressure: 1033.900000, icon: cloudy

            return WeatherData(
                timestamp: normalizedDate,
                probability: entry.precipitation_probability.map { min(max($0 / 100, 0), 1) },
                amount: max(0, entry.precipitation ?? 0),
                temperature: entry.temperature,
                cloud: max(0, entry.cloud_cover ?? 0),
                humidity: max(0, entry.relative_humidity ?? 0),
                pressure: max(0, entry.pressure_msl ?? 0),
                icon: entry.icon ?? "unknown",
                windSpeed: Double((entry.wind_speed ?? 0.0001) / 3.6), // convert from km/h to m/s
                windDirection: entry.wind_direction,
                weatherCode: entry.condition ?? "unknown", // "dry", "rain", "snow", "sleet", "hail", "thunderstorm", "fog"
                source: "BrightSky",
                color: "green"
            )
        }

        logger.debug("✅ BrightSky liefert \(results.count) Datenpunkte zurück")
        return results
    }
}

private struct BrightSkyResponse: Decodable {
    let weather: [WeatherEntry]
}

private struct WeatherEntry: Decodable {
    let timestamp: String
    let precipitation: Double?
    let precipitation_probability: Double?
    let temperature: Double?
    let cloud_cover: Double?
    let relative_humidity: Double?
    let pressure_msl: Double?
    let icon: String?
    let wind_speed: Double?
    let wind_direction: Double?
    let condition: String?
}
