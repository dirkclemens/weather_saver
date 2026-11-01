# WeatherSaver

A macOS screensaver that displays live weather conditions with animated clouds, rain, snow, fog, and thunderstorm effects. Powered by weather data from the Deutscher Wetterdienst (DWD) via the BrightSky API.

## Features

- **Live weather**: Fetches current conditions and forecast from BrightSky API (DWD data)
- **Animated weather effects**: Clouds, rain, snow, thunderstorms with lightning, and fog
- **Configuration panel**: Set location (latitude/longitude), location name, units (metric/imperial), animation speed, cloud opacity, update interval, and display toggles
- **Location services**: "Use Current Location" button fetches your GPS position via Core Location and reverse-geocodes it to a place name
- **Simulation mode**: Fake weather conditions (Sunny, Cloudy, Rain, Snow, Thunderstorm, Fog) for testing without API calls
- **Preview app**: Standalone macOS app to preview and configure the screensaver

## Project Structure

```
weather_saver/
├── WeatherAPI/                 # Weather data fetching layer
│   ├── BrightSkyClient.swift   # BrightSky API client (HTTP + JSON decoding)
│   ├── LocationManager.swift   # Core Location wrapper (async/await)
│   └── WeatherTypes.swift      # Shared WeatherData model + WeatherProvider protocol
├── WeatherSaver/               # The screensaver bundle target
│   ├── Sources/
│   │   ├── ConfigurationView.swift   # SwiftUI configuration sheet
│   │   ├── WeatherPreferences.swift  # UserDefaults-backed settings (ObservableObject)
│   │   ├── WeatherSaverView.swift    # ScreenSaverView with Core Graphics animation
│   │   ├── generate_preview.swift    # Preview generation helpers
│   │   ├── preview.png                 # Screensaver thumbnail
│   │   └── thumbnail.png               # Alternative thumbnail
│   └── Support/
│       ├── Info.plist
│       └── WeatherSaver.entitlements
├── Preview/                    # Standalone preview app target
│   ├── Sources/
│   │   ├── AppDelegate.swift         # Menu bar + preferences command
│   │   ├── PreviewWindowController.swift  # Shows WeatherSaverView in a window
│   │   └── main.swift                # App entry point
│   └── Support/
│       ├── Info.plist
│       └── Preview.entitlements
├── WeatherSaver.xcodeproj/     # Xcode project (2 targets: WeatherSaver + Preview)
├── screenshot.jpg              # README screenshot
└── README.md
```

## Requirements

- macOS 14.0 or later
- Xcode 15 or later
- Internet connection (for BrightSky API)
- Location services permission (optional, for "Use Current Location")

## Building

1. Open `WeatherSaver.xcodeproj` in Xcode
2. Select the **WeatherSaver** target to build the screensaver (`.saver` bundle)
3. Select the **Preview** target to run the standalone preview app
4. Build and run

The screensaver product is `WeatherSaver.saver`. Install it by copying to `~/Library/Screen Savers/` or `/Library/Screen Savers/`, then enable it in System Settings > Desktop & Screen Saver.

## Configuration

The configuration sheet is accessible:
- **From the screensaver**: Open System Settings > Desktop & Screen Saver > WeatherSaver > Options
- **From the Preview app**: WeatherSaver Preview ▸ Preferences… (⌘ ,)

### Settings

| Setting | Description |
|---------|-------------|
| Latitude / Longitude | Fixed coordinates for weather lookup |
| Location Name | Display name shown in the screensaver |
| Use Current Location | Fetches GPS position and reverse-geocodes a place name |
| Show Forecast | Display upcoming forecast entries |
| Show Details | Display wind, precipitation, humidity, clouds, pressure |
| Show Location Name | Show the location name at the bottom |
| Use Metric Units | Use metric units for display values |
| Animation Speed | Slow / Normal / Fast / Very Fast |
| Cloud Opacity | Cloud layer transparency |
| Update Interval | How often to refresh weather data |
| Simulation Mode | Override live API with a fake condition (Sunny, Cloudy, Rain, Snow, Thunderstorm, Fog) |

## Simulation Mode

For testing or visual preview without calling the API, enable **Simulation Mode** in the configuration panel and choose a condition. The screensaver will render the matching animation (e.g., falling snow, rain drops, fog bands, lightning flashes) with simulated temperature and conditions instead of live data.

## Permissions

The screensaver requests:
- **Location Services** (`NSLocationWhenInUseUsageDescription`) — for "Use Current Location"
- **Network client** (`com.apple.security.network.client`) — sandbox entitlement for BrightSky API HTTPS requests

Both entitlements are configured in `WeatherSaver/Support/WeatherSaver.entitlements`.

## License

Copyright © 2026. All rights reserved.
