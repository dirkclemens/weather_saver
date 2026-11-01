import SwiftUI
import AppKit
import CoreLocation

public struct ConfigurationView: View {
    @ObservedObject var preferences = WeatherPreferences.shared
    public var onClose: (() -> Void)?

    @State private var isFetchingLocation = false
    @State private var locationError: String?
    @State private var locationSuccess = false

    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    private func fetchCurrentLocation() {
        isFetchingLocation = true
        locationError = nil
        locationSuccess = false

        Task {
            do {
                let locationManager = LocationManager()
                let location = try await locationManager.requestLocation()

                let locationName = await reverseGeocode(location: location) ?? "Current Location"

                await MainActor.run {
                    preferences.latitude = location.coordinate.latitude
                    preferences.longitude = location.coordinate.longitude
                    preferences.locationName = locationName
                    isFetchingLocation = false
                    locationSuccess = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        locationSuccess = false
                    }
                }
            } catch {
                await MainActor.run {
                    isFetchingLocation = false
                    locationError = error.localizedDescription
                }
            }
        }
    }

    private func reverseGeocode(location: CLLocation) async -> String? {
        await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                let placemark = placemarks?.first
                let name = placemark?.locality
                    ?? placemark?.subLocality
                    ?? placemark?.name
                    ?? placemark?.administrativeArea
                continuation.resume(returning: name)
            }
        }
    }

    public var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack(spacing: 12) {
                Text("🌤")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("WeatherSaver")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Weather screensaver with live conditions")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 4)

            Divider()

            // Settings Form
            Form {
                Section("Location") {
                    HStack {
                        Text("Latitude")
                            .frame(alignment: .leading)
                        TextField("", value: $preferences.latitude, format: .number.precision(.fractionLength(6)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }

                    HStack {
                        Text("Longitude")
                            .frame(alignment: .leading)
                        TextField("", value: $preferences.longitude, format: .number.precision(.fractionLength(6)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    
                    HStack {
                            Text("Location Name")
                                .frame(alignment: .leading)                            
                            TextField("", text: $preferences.locationName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                        }

                    HStack {
                        Button(action: fetchCurrentLocation) {
                            if isFetchingLocation {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Fetching...")
                                }
                            } else {
                                Text("Use Current Location")
                            }
                        }
                        .disabled(isFetchingLocation)
                        .buttonStyle(.borderedProminent)

                        if let error = locationError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        } else if locationSuccess {
                            Text("Location updated!")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }
                    
                Section("Display Options") {
                    Toggle("Show Forecast", isOn: $preferences.showForecast)
                    Toggle("Show Details (Wind, Humidity, Pressure)", isOn: $preferences.showDetails)
                    Toggle("Show Location Name", isOn: $preferences.showLocationName)
                    Toggle("Use Metric Units", isOn: $preferences.useMetricUnits)
                }
                
                Section("Animation") {
                    HStack {
                        Text("Animation Speed:")
                            .frame(alignment: .leading)
                        Picker("", selection: $preferences.animationSpeed) {
                            Text("Slow (0.5x)").tag(0.5)
                            Text("Normal (1.0x)").tag(1.0)
                            Text("Fast (1.5x)").tag(1.5)
                            Text("Very Fast (2.0x)").tag(2.0)
                        }
                        .pickerStyle(.automatic)
                    }
                    
                    HStack {
                        Text("Cloud Opacity:")
                            .frame(alignment: .leading)
                        Picker("", selection: $preferences.cloudOpacity) {
                            Text("Low (0.5x)").tag(0.5)
                            Text("Normal (1.0x)").tag(1.0)
                            Text("High (1.5x)").tag(1.5)
                            Text("Very High (2.0x)").tag(2.0)
                        }
                        .pickerStyle(.automatic)
                    }
                }
                
                Section("Update Interval") {
                    Picker("Update Interval:", selection: $preferences.updateInterval) {
                        Text("1 Minute").tag(60.0)
                        Text("5 Minutes (Default)").tag(300.0)
                        Text("10 Minutes").tag(600.0)
                        Text("30 Minutes").tag(1800.0)
                        Text("1 Hour").tag(3600.0)
                    }
                    .pickerStyle(.menu)
                    .frame(alignment: .leading)
                }

                Section("Simulation") {
                    Toggle("Simulation Mode", isOn: $preferences.simulateWeather)

                    Picker("Condition:", selection: $preferences.simulatedCondition) {
                        Text("Sunny").tag("sunny")
                        Text("Cloudy").tag("cloudy")
                        Text("Rain").tag("rain")
                        Text("Snow").tag("snow")
                        Text("Thunderstorm").tag("thunderstorm")
                        Text("Fog").tag("fog")
                    }
                    .disabled(!preferences.simulateWeather)
                    .pickerStyle(.menu)
                    .frame(alignment: .leading)

                    if preferences.simulateWeather {
                        Text("Using simulated weather data instead of live API")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Footer
            HStack {
                Text("Weather data by Deutscher Wetterdienst (DWD)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Done") {
                    onClose?()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

// MARK: - Configuration Sheet Controller for ScreenSaverView
public final class ConfigurationSheetController: NSObject {
    public private(set) var window: NSWindow?
    private var hostingController: NSHostingController<ConfigurationView>?

    public override init() {
        super.init()
        setupWindow()
    }

    private func setupWindow() {
        let view = ConfigurationView { [weak self] in
            self?.close()
        }

        hostingController = NSHostingController(rootView: view)
        window = NSWindow(contentViewController: hostingController!)
        window?.title = "WeatherSaver Preferences"
        window?.styleMask = [.titled, .closable]
        window?.isReleasedWhenClosed = false
        window?.center()
    }

    public func close() {
        if let sheetParent = window?.sheetParent {
            sheetParent.endSheet(window!)
        } else {
            window?.close()
        }
    }
}
