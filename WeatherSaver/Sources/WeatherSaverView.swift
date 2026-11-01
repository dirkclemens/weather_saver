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

private struct SeededRandom {
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
}

private struct CloudLayer {
    let width: CGFloat
    let height: CGFloat
    let baseX: CGFloat
    let y: CGFloat
    let speed: CGFloat  // screen widths per minute (like SkyBackgroundView)
    let phase: CGFloat
    let opacity: CGFloat
    let blur: CGFloat
}

private struct RainDrop {
    let x: CGFloat
    let length: CGFloat
    let speed: CGFloat
    let phase: CGFloat
    let opacity: CGFloat
    let slant: CGFloat
}

private struct SnowFlake {
    let x: CGFloat
    let size: CGFloat
    let speed: CGFloat
    let phase: CGFloat
    let sway: CGFloat
    let swaySpeed: CGFloat
    let opacity: CGFloat
}

private struct FogDrop {
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let opacity: CGFloat
    let driftSpeed: CGFloat
    let phase: CGFloat
}

private struct LightningState {
    var lastFlashTime: TimeInterval = 0
    var flashProgress: CGFloat = 0
}

@objc(WeatherSaverView)
public final class WeatherSaverView: ScreenSaverView {

    private struct ForecastEntry {
        let time: String
        let icon: String
        let temperature: String
        let precipitation: String
        let windSpeed: String
    }

    private var currentTemp: String = "22°C"
    private var currentIcon: String = "☀️"
    private var currentWind: String = "—"
    private var currentWindSpeed: Double = 3.0
    private var currentWindDirection: Double? = nil
    private var currentPressure: Double = 1013.0
    private var currentCloudCover: Double = 0.0
    private var currentPrecip: String = "—"
    private var currentHumidity: String = "—"
    private var currentCondition: String = "clear"
    private var forecast: [ForecastEntry] = []
    private var lastUpdateTime: Date = Date()
    private let updateInterval: TimeInterval = 300.0
    private let client = BrightSkyClient()
    private var isFetching = false
    private var animationTime: TimeInterval = 0
    
    // Particle systems (deterministic via seeded random)
    private var cloudLayers: [CloudLayer] = []
    private var rainDrops: [RainDrop] = []
    private var snowFlakes: [SnowFlake] = []
    private var fogDrops: [FogDrop] = []
    private var lightning = LightningState()
    private var configureSheetController: ConfigurationSheetController?
    private var lastFrameTime: CFTimeInterval = 0.0
    private var isLameDuck = false
    private var willStopObserver: NSObjectProtocol?
    private var fallbackTimer: Timer?
    private var settingsCancellable: AnyCancellable?
    
    private var currentLatitude: Double {
        WeatherPreferences.shared.latitude
    }
    
    private var currentLongitude: Double {
        WeatherPreferences.shared.longitude
    }
    
    private var currentLocationName: String {
        WeatherPreferences.shared.locationName
    }

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        addLog("WeatherSaverView initialized frame: \(frame), isPreview: \(isPreview)")
        animationTimeInterval = 1.0 / 30.0
        initializeParticles()
        fetchWeather()
        needsDisplay = true
        setupSettingsObserver()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        addLog("WeatherSaverView init(coder:) called")
        animationTimeInterval = 1.0 / 30.0
        initializeParticles()
        fetchWeather()
        needsDisplay = true
        setupSettingsObserver()
    }
    
    private func setupSettingsObserver() {
        settingsCancellable = WeatherPreferences.shared.$simulateWeather
            .combineLatest(WeatherPreferences.shared.$simulatedCondition)
            .sink { [weak self] _, _ in
                Task { @MainActor in
                    self?.fetchWeather()
                }
            }
    }
    
    private func initializeParticles() {
        // Cloud layers - matching SkyBackgroundView DriftingCloudsView exactly (half size)
        // speed = screen widths per minute (divided by 60 in drift formula)
        // Scale by wind speed: base speeds * (windSpeed / 3.0) where 3 m/s = reference
        let windFactor = max(0.3, min(3.0, currentWindSpeed / 3.0))
        cloudLayers = [
            // Large cloud upper (width 0.15, y 0.30, opacity 0.10, base speed 6)
            CloudLayer(
                width: bounds.width * 0.15,
                height: bounds.height * 0.055,
                baseX: -bounds.width * 0.15,
                y: bounds.height * 0.30,
                speed: 6.0 * windFactor,
                phase: 0,
                opacity: 0.10,
                blur: 12
            ),
            // Medium cloud middle (width 0.1125, y 0.40, opacity 0.07, base speed 4)
            CloudLayer(
                width: bounds.width * 0.1125,
                height: bounds.height * 0.045,
                baseX: -bounds.width * 0.15,
                y: bounds.height * 0.40,
                speed: 4.0 * windFactor,
                phase: 0.45,
                opacity: 0.07,
                blur: 12
            ),
            // Medium cloud lower (width 0.125, y 0.60, opacity 0.06, base speed 3)
            CloudLayer(
                width: bounds.width * 0.125,
                height: bounds.height * 0.05,
                baseX: -bounds.width * 0.15,
                y: bounds.height * 0.60,
                speed: 3.0 * windFactor,
                phase: 0.8,
                opacity: 0.06,
                blur: 12
            ),
            // Additional subtle clouds for depth
            CloudLayer(
                width: bounds.width * 0.0875,
                height: bounds.height * 0.0375,
                baseX: -bounds.width * 0.1,
                y: bounds.height * 0.35,
                speed: 5.0 * windFactor,
                phase: 0.2,
                opacity: 0.04,
                blur: 15
            ),
            CloudLayer(
                width: bounds.width * 0.1,
                height: bounds.height * 0.04,
                baseX: -bounds.width * 0.125,
                y: bounds.height * 0.75,
                speed: 2.0 * windFactor,
                phase: 0.6,
                opacity: 0.03,
                blur: 15
            )
        ]
        
        // Rain drops
        var rngRain = SeededRandom(seed: 13)
        rainDrops = (0..<120).map { _ in
            RainDrop(
                x: CGFloat(rngRain.unit()),
                length: CGFloat(12 + rngRain.unit() * 18),
                speed: CGFloat(0.5 + rngRain.unit() * 0.7),
                phase: CGFloat(rngRain.unit()),
                opacity: CGFloat(0.25 + rngRain.unit() * 0.25),
                slant: CGFloat(-4 + rngRain.unit() * 8)
            )
        }
        
        // Snow flakes
        var rngSnow = SeededRandom(seed: 91)
        snowFlakes = (0..<70).map { _ in
            SnowFlake(
                x: CGFloat(rngSnow.unit()),
                size: CGFloat(2 + rngSnow.unit() * 3),
                speed: CGFloat(0.15 + rngSnow.unit() * 0.25),
                phase: CGFloat(rngSnow.unit()),
                sway: CGFloat(10 + rngSnow.unit() * 20),
                swaySpeed: CGFloat(0.3 + rngSnow.unit() * 0.5),
                opacity: CGFloat(0.4 + rngSnow.unit() * 0.35)
            )
        }
        
        // Fog drops in lower quarter
        var rngFogDrop = SeededRandom(seed: 77)
        fogDrops = (0..<10000).map { _ in
            FogDrop(
                x: CGFloat(rngFogDrop.unit()),
                y: CGFloat(pow(rngFogDrop.unit(), 5.0) * 1.1), // denser near ground
                size: CGFloat(0.5 + rngFogDrop.unit() * 10),
                opacity: CGFloat(0.005 + rngFogDrop.unit() * 0.01),
                driftSpeed: CGFloat(0.01 + rngFogDrop.unit() * 0.05),
                phase: CGFloat(rngFogDrop.unit() * 2 * .pi)
            )
        }
    }

    public override var animationTimeInterval: TimeInterval {
        get { return 1.0 / 30.0 }
        set { super.animationTimeInterval = newValue }
    }

    public override func draw(_ rect: NSRect) {
        //addLog("draw() called, bounds: \(bounds)")
        drawBackground()
        drawContent()
    }

    private func drawBackground() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        context.setFillColor(NSColor(red: 0.08, green: 0.12, blue: 0.22, alpha: 1.0).cgColor)
        context.fill(bounds)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            NSColor(red: 0.05, green: 0.1, blue: 0.2, alpha: 1.0).cgColor,
            NSColor(red: 0.1, green: 0.15, blue: 0.3, alpha: 1.0).cgColor,
            NSColor(red: 0.08, green: 0.12, blue: 0.25, alpha: 1.0).cgColor
        ] as CFArray

        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.5, 1.0]) else {
            return
        }

        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bounds.midX, y: bounds.minY),
            end: CGPoint(x: bounds.midX, y: bounds.maxY),
            options: []
        )

        drawWeatherAnimation(context)
        drawSubtlePattern(context)
    }

    private func drawSubtlePattern(_ context: CGContext) {
        context.setFillColor(NSColor.white.withAlphaComponent(0.02).cgColor)
        let spacing: CGFloat = 30
        for x in stride(from: 0, to: bounds.width, by: spacing) {
            for y in stride(from: 0, to: bounds.height, by: spacing) {
                let offset = sin(CGFloat(animationTime) + x * 0.01 + y * 0.01) * 2
                let rect = CGRect(x: x + offset, y: y + offset, width: 1, height: 1)
                context.fill(rect)
            }
        }
    }
    
    private func drawWeatherAnimation(_ context: CGContext) {
        let t = animationTime
        let condition = currentCondition.lowercased()
        let cloudOpacity = WeatherPreferences.shared.cloudOpacity
        
        switch condition {
        case "rain", "lightrain", "heavyrain", "drizzle", "wet":
            drawClouds(context, opacityMultiplier: 0.7 * cloudOpacity)
            drawRain(context, time: t, intensity: 1.0)
        case "snow", "lightsnow", "heavysnow", "sleet":
            drawClouds(context, opacityMultiplier: 0.6 * cloudOpacity)
            drawSnow(context, time: t, intensity: 1.0)
        case "cloudy", "overcast":
            drawClouds(context, opacityMultiplier: 1.4 * cloudOpacity)
        case "partlycloudy", "dry":
            drawClouds(context, opacityMultiplier: 1.0 * cloudOpacity)
        case "sunny", "clear":
            drawSun(context, time: t)
        case "thunderstorm":
            drawClouds(context, opacityMultiplier: 0.9 * cloudOpacity)
            drawRain(context, time: t, intensity: 1.5)
            drawLightning(context, time: t)
        case "fog", "mist":
            drawClouds(context, opacityMultiplier: 0.8 * cloudOpacity)
            drawFog(context, time: t)
            drawShimmeringFog(context, time: t)
        default:
            drawClouds(context, opacityMultiplier: 1.0 * cloudOpacity)
        }
    }
    
    private func drawClouds(_ context: CGContext, opacityMultiplier: CGFloat = 1.0) {
        for layer in cloudLayers {
            // Drift formula from SkyBackgroundView: progress = (t * speed / 60.0 + phase) % 1.0
            let progress = (animationTime * layer.speed / 60.0 + layer.phase).truncatingRemainder(dividingBy: 1.0)
            let screenWidth = bounds.width + layer.width * 2
            let x = layer.baseX + progress * screenWidth
            
            context.saveGState()
            context.translateBy(x: x, y: layer.y)
            
            drawCloudShape(context,
                          width: layer.width,
                          height: layer.height,
                          opacity: layer.opacity * opacityMultiplier,
                          blur: layer.blur)
            
            context.restoreGState()
        }
    }
    
    private func drawCloudShape(_ context: CGContext, width: CGFloat, height: CGFloat, opacity: CGFloat, blur: CGFloat) {
        // Single unified cloud shape (like SF Symbol cloud.fill) with one blur
        let path = NSBezierPath()
        let w = width
        let h = height
        
        // Cloud profile - similar to SF Symbol cloud.fill
        // Made of 5 overlapping ellipses merged into one path
        let bubbles: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.12, 0.45, 0.45, 0.65),  // left large
            (0.35, 0.15, 0.50, 0.70),  // top left
            (0.62, 0.10, 0.45, 0.60),  // top middle
            (0.88, 0.35, 0.38, 0.55),  // right
            (0.50, 0.60, 0.55, 0.75),  // bottom center
        ]
        
        // Build cloud path by combining ellipses
        var first = true
        for (cx, cy, cw, ch) in bubbles {
            let x = cx * w
            let y = cy * h
            let rx = cw * w * 0.5
            let ry = ch * h * 0.5
            
            let bubbleRect = CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2)
            let bubblePath = NSBezierPath(ovalIn: bubbleRect)
            
            if first {
                path.append(bubblePath)
                first = false
            } else {
                // Union via even-odd fill rule
                path.append(bubblePath)
            }
        }
        
        // Use even-odd winding to merge overlapping ellipses
        path.windingRule = .evenOdd
        
        context.saveGState()
        
        if blur > 0 {
            // Single blur for entire cloud (like .blur(radius: 12) in SwiftUI)
            context.setShadow(offset: .zero, blur: blur, color: NSColor(white: 1.0, alpha: opacity * 0.8).cgColor)
        }
        
        context.setFillColor(NSColor(white: 1.0, alpha: opacity).cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
        
        context.restoreGState()
    }
    
    private func drawRain(_ context: CGContext, time: TimeInterval, intensity: CGFloat) {
        context.setLineWidth(1.2)
        context.setLineCap(.round)
        
        for drop in rainDrops {
            let progress = ((time * drop.speed) + drop.phase).truncatingRemainder(dividingBy: 1.0)
            let yStart = bounds.height - progress * (bounds.height + drop.length)
            let x = drop.x * bounds.width
            
            let alpha = drop.opacity * min(1.0, intensity)
            context.setStrokeColor(NSColor(white: 1.0, alpha: alpha).cgColor)
            
            context.move(to: CGPoint(x: x, y: yStart))
            context.addLine(to: CGPoint(x: x + drop.slant, y: yStart + drop.length))
            context.strokePath()
        }
    }
    
    private func drawSnow(_ context: CGContext, time: TimeInterval, intensity: CGFloat) {
        for flake in snowFlakes {
            let progress = ((time * flake.speed) + flake.phase).truncatingRemainder(dividingBy: 1.0)
            let yStart = bounds.height - progress * (bounds.height + flake.size)
            let x = flake.x * bounds.width + sin(time * flake.swaySpeed + flake.phase * 6) * flake.sway
            
            let alpha = flake.opacity * min(1.0, intensity)
            context.setFillColor(NSColor(white: 1.0, alpha: alpha).cgColor)
            
            let rect = CGRect(x: x - flake.size/2, y: yStart - flake.size/2,
                             width: flake.size, height: flake.size)
            context.fillEllipse(in: rect)
        }
    }
    
    private func drawSun(_ context: CGContext, time: TimeInterval) {
        let centerX = bounds.width * 0.78
        let centerY = bounds.height * 0.15
        let maxRadius = max(bounds.width, bounds.height) * 0.85
        
        // Radial gradient glow
        let glowColors = [
            NSColor(white: 1.0, alpha: 0.28).cgColor,
            NSColor(white: 1.0, alpha: 0.12).cgColor,
            NSColor(white: 1.0, alpha: 0.0).cgColor
        ] as CFArray
        if let glowGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0.0, 0.4, 1.0]) {
            context.drawRadialGradient(
                glowGradient,
                startCenter: CGPoint(x: centerX, y: centerY),
                startRadius: 10,
                endCenter: CGPoint(x: centerX, y: centerY),
                endRadius: maxRadius,
                options: []
            )
        }
        
        // Sun core with subtle pulse
        let coreRadius: CGFloat = 50 + sin(time * 0.5) * 8
        context.setFillColor(NSColor(white: 1.0, alpha: 0.25).cgColor)
        let coreRect = CGRect(x: centerX - coreRadius, y: centerY - coreRadius,
                             width: coreRadius * 2, height: coreRadius * 2)
        context.fillEllipse(in: coreRect)
    }
    
    private func drawFog(_ context: CGContext, time: TimeInterval) {
        context.saveGState()
        
        // Fog only in the bottom quarter of the screen
        let groundHeight = bounds.height * 0.25
        
        for drop in fogDrops {
            // Very slow horizontal drift
            let driftX = sin(time * drop.driftSpeed + drop.phase) * bounds.width * 0.05
            let x = drop.x * bounds.width + driftX
            let y = drop.y * groundHeight
            
            let rect = CGRect(
                x: x - drop.size / 2,
                y: y - drop.size / 2,
                width: drop.size,
                height: drop.size
            )
            
            context.setFillColor(NSColor(white: 1.0, alpha: drop.opacity).cgColor)
            context.fillEllipse(in: rect)
        }
        
        context.restoreGState()
    }
    
    // MARK: - Shimmering gradient fog 
    // A subtle, traveling wave of light at ground level, like distant heat haze.
    // Strongest at the bottom (pixel 0), smoothly fading to fully transparent at top.
    private func drawShimmeringFog(_ context: CGContext, time: TimeInterval) {
        context.saveGState()
        
        // Fog area: bottom fifth of screen (smaller area)
        let fogHeight = bounds.height * 0.20
        
        // Very slow traveling motion
        let shift = CGFloat(time * 0.04).truncatingRemainder(dividingBy: 1.0)
        let humps = 3.0
        let n = 24
        
        // Draw horizontal bands: strongest at bottom (i=0), fading to transparent at top
        let bandCount = 16
        let bandHeight = fogHeight / CGFloat(bandCount)
        
        for i in 0..<bandCount {
            let y = CGFloat(i) * bandHeight
            // Vertical opacity: 1.0 at bottom band (pixel 0), 0 at top band
            let verticalOpacity = 1.0 - (CGFloat(i) / CGFloat(bandCount - 1))
            // Strong exponential fade so top blends into heaven without hard edge
            let softVertical = verticalOpacity * verticalOpacity * verticalOpacity
            let bandOpacity = 0.03 * softVertical
            
            guard bandOpacity > 0.0001 else { continue }
            
            var colors: [CGColor] = []
            var locations: [CGFloat] = []
            for k in 0...n {
                let loc = CGFloat(k) / CGFloat(n)
                let wavePos = loc + shift
                let wave = 0.5 + 0.5 * sin(2 * CGFloat.pi * humps * wavePos)
                let alpha = bandOpacity * (0.4 + 0.6 * wave)
                colors.append(NSColor(white: 1.0, alpha: alpha).cgColor)
                locations.append(loc)
            }
            
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors as CFArray,
                                            locations: locations) else { continue }
            
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: y),
                                       end: CGPoint(x: bounds.width, y: y + bandHeight),
                                       options: [])
        }
        
        context.restoreGState()
    }
    
    private func drawLightning(_ context: CGContext, time: TimeInterval) {
        let cycle = time.truncatingRemainder(dividingBy: 6.0)
        let primary = max(0, 1.0 - cycle * 8)
        let echo = (cycle > 0.28 && cycle < 0.38) ? max(0, (0.38 - cycle) * 10) : 0
        let intensity = min(1, primary + echo) * 0.35
        
        guard intensity > 0.01 else { return }
        
        context.setFillColor(NSColor(white: 1.0, alpha: intensity).cgColor)
        context.fill(bounds)
    }

    private func drawContent() {
        guard bounds.width > 0 && bounds.height > 0 else { return }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let cardWidth: CGFloat = min(bounds.width * 0.85, 580)
        let cardHeight: CGFloat = min(bounds.height * 0.9, 700)
        let cardRect = CGRect(
            x: center.x - cardWidth / 2,
            y: center.y - cardHeight / 2,
            width: max(1, cardWidth),
            height: max(1, cardHeight)
        )

        let horizontalPadding: CGFloat = 10
        let contentWidth = cardRect.width - horizontalPadding * 2
        let contentLeft = cardRect.minX + horizontalPadding
//        let contentRight = cardRect.maxX - horizontalPadding

        var currentY = cardRect.minY + 20

        drawMainCard(cardRect)

        currentY = drawLastUpdated(atY: currentY, width: contentWidth, left: contentLeft)
        currentY += 16

        if WeatherPreferences.shared.showForecast {
            currentY = drawForecast(atY: currentY, width: contentWidth, left: contentLeft, cardWidth: cardRect.width)
            currentY += 40
        }

        if WeatherPreferences.shared.showDetails {
            currentY = drawDetails(atY: currentY, width: contentWidth, left: contentLeft)
            currentY += 30
        }

        currentY = drawCurrentWeather(atY: currentY, width: contentWidth, left: contentLeft)

        drawLocationLabel(atY: cardRect.maxY - 44, width: contentWidth, left: contentLeft)
    }

    private func drawMainCard(_ rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let cornerRadius: CGFloat = 24
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

        context.saveGState()
        path.addClip()

        let glassColors = [
            NSColor.white.withAlphaComponent(0.08).cgColor,
            NSColor.white.withAlphaComponent(0.03).cgColor
        ]
        let glassGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: glassColors as CFArray,
            locations: [0.0, 1.0]
        )!
        context.drawLinearGradient(
            glassGradient,
            start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY),
            options: []
        )

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
        context.setLineWidth(1)
        context.strokePath()

        context.restoreGState()

        drawGlowEffect(context, rect: rect, cornerRadius: cornerRadius)
    }

    private func drawGlowEffect(_ context: CGContext, rect: CGRect, cornerRadius: CGFloat) {
        let glowRect = rect.insetBy(dx: -20, dy: -20)
        let glowPath = NSBezierPath(roundedRect: glowRect, xRadius: cornerRadius + 20, yRadius: cornerRadius + 20)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 40, color: NSColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.3).cgColor)
        context.setFillColor(NSColor.clear.cgColor)
        context.addPath(glowPath.cgPath)
        context.fillPath()
        context.restoreGState()
    }

    @discardableResult
    private func drawCurrentWeather(atY y: CGFloat, width: CGFloat, left: CGFloat) -> CGFloat {
        let iconSize: CGFloat = 100
        let iconRect = CGRect(
            x: left + (width - iconSize) / 2,
            y: y,
            width: iconSize,
            height: iconSize
        )

        drawText(text: currentIcon, color: .white, fontName: "Apple Color Emoji", fontSize: 100, rect: iconRect, alignment: .center)

        let tempRect = CGRect(x: left, y: y + iconSize + 30, width: width, height: 110)
        drawText(text: currentTemp, color: .white, fontName: "SF Pro Display", fontSize: 100, rect: tempRect, alignment: .center, weight: .thin)
        return y + iconSize + 40 + 100
    }

    @discardableResult
    private func drawDetails(atY y: CGFloat, width: CGFloat, left: CGFloat) -> CGFloat {
        let detailHeight: CGFloat = 120
        let detailWidth: CGFloat = 90
        let spacing: CGFloat = 16
        let count = 5
        let totalWidth = CGFloat(count) * detailWidth + CGFloat(count - 1) * spacing
        let startX = left + (width - totalWidth) / 2

//        let windDirText = currentWindDirection.map { String(format: "%.0f°", $0) } ?? "—"
        let pressureText = String(format: "%.0f hPa", currentPressure)
        let cloudText = String(format: "%.0f%%", currentCloudCover)

        let details = [
            ("💨", currentWind, "Wind"),
            ("💧", currentPrecip, "Precip"),
            ("💦", currentHumidity, "Humidity"),
            ("☁️", cloudText, "Clouds"),
            ("📊", pressureText, "Press"),
        ]
        //            ("🧭", windDirText, "Dir"),

        for (index, (icon, value, label)) in details.enumerated() {
            let x = startX + CGFloat(index) * (detailWidth + spacing)
            let detailRect = CGRect(x: x, y: y, width: detailWidth, height: detailHeight)
            drawDetailCard(detailRect, icon: icon, value: value, label: label)
        }
        return y + detailHeight
    }

    private func drawDetailCard(_ rect: CGRect, icon: String, value: String, label: String) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let cornerRadius: CGFloat = 16
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

        context.saveGState()
        path.addClip()

        let colors = [
            NSColor.white.withAlphaComponent(0.1).cgColor,
            NSColor.white.withAlphaComponent(0.04).cgColor
        ]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0.0, 1.0])!
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.1).cgColor)
        context.setLineWidth(0.5)
        context.strokePath()
        context.restoreGState()

        let iconRect = CGRect(x: rect.minX, y: rect.midY + 10, width: rect.width, height: 28)
        drawText(text: icon, color: .white.withAlphaComponent(0.85), fontName: "Apple Color Emoji", fontSize: 24, rect: iconRect, alignment: .center)

        let valueRect = CGRect(x: rect.minX, y: rect.minY + 32, width: rect.width, height: 30)
        drawText(text: value, color: .white, fontName: "SF Pro Display", fontSize: 20, rect: valueRect, alignment: .center, weight: .medium)

        let labelRect = CGRect(x: rect.minX, y: rect.minY + 4, width: rect.width, height: 20)
        drawText(text: label, color: .white.withAlphaComponent(0.5), fontName: "SF Pro Text", fontSize: 11, rect: labelRect, alignment: .center)
    }

    @discardableResult
    private func drawForecast(atY y: CGFloat, width: CGFloat, left: CGFloat, cardWidth: CGFloat) -> CGFloat {
        guard !forecast.isEmpty else { return y }

        let forecastHeight: CGFloat = 160
        let itemWidth: CGFloat = 82
        let spacing: CGFloat = 8
        let totalWidth = CGFloat(forecast.count) * itemWidth + CGFloat(forecast.count - 1) * spacing
        let startX = left + (width - totalWidth) / 2

        for (index, entry) in forecast.enumerated() {
            let x = startX + CGFloat(index) * (itemWidth + spacing)
            let itemRect = CGRect(x: x, y: y, width: itemWidth, height: forecastHeight)
            drawForecastItem(itemRect, entry: entry, isFirst: index == 0, isLast: index == forecast.count - 1)
        }
        return y + forecastHeight
    }

    private func drawForecastItem(_ rect: CGRect, entry: ForecastEntry, isFirst: Bool, isLast: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let cornerRadius: CGFloat = 16
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

        context.saveGState()
        path.addClip()

        let alpha: CGFloat = isFirst || isLast ? 0.1 : 0.06
        let colors = [
            NSColor.white.withAlphaComponent(alpha + 0.03).cgColor,
            NSColor.white.withAlphaComponent(alpha).cgColor
        ]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0.0, 1.0])!
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])

        if isFirst || isLast {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.2).cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }
        context.restoreGState()

        let timeRect = CGRect(x: rect.minX, y: rect.maxY - 28, width: rect.width, height: 24)
        drawText(text: entry.time, color: .white.withAlphaComponent(0.85), fontName: "SF Pro Text", fontSize: 13, rect: timeRect, alignment: .center, weight: .medium)

        let iconRect = CGRect(x: rect.minX, y: rect.midY - 0, width: rect.width, height: 42)
        drawText(text: entry.icon, color: .white, fontName: "Apple Color Emoji", fontSize: 34, rect: iconRect, alignment: .center)

        let tempRect = CGRect(x: rect.minX, y: rect.minY + 50, width: rect.width, height: 28)
        drawText(text: entry.temperature, color: .white, fontName: "SF Pro Display", fontSize: 22, rect: tempRect, alignment: .center, weight: .medium)

        let precipRect = CGRect(x: rect.minX + 4, y: rect.minY + 10, width: rect.width - 8, height: 18)
        drawText(text: entry.precipitation, color: NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 0.9), fontName: "SF Pro Text", fontSize: 10, rect: precipRect, alignment: .center)

        let windRect = CGRect(x: rect.minX + 4, y: rect.minY + 30, width: rect.width - 8, height: 16)
        drawText(text: entry.windSpeed, color: .white.withAlphaComponent(0.5), fontName: "SF Pro Text", fontSize: 10, rect: windRect, alignment: .center)
    }

    private func drawLocationLabel(atY y: CGFloat, width: CGFloat, left: CGFloat) {
        let labelRect = CGRect(x: left, y: y, width: width, height: 24)
        guard WeatherPreferences.shared.showLocationName else { return }
        drawText(text: currentLocationName.uppercased(), color: .white.withAlphaComponent(0.5), fontName: "SF Pro Text", fontSize: 13, rect: labelRect, alignment: .center, weight: .medium, tracking: 2.5)
    }

    @discardableResult
    private func drawLastUpdated(atY y: CGFloat, width: CGFloat, left: CGFloat) -> CGFloat {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let timeString = "Updated \(formatter.string(from: lastUpdateTime))"

        let labelRect = CGRect(x: left, y: y, width: width, height: 18)
        drawText(text: timeString, color: .white.withAlphaComponent(0.4), fontName: "SF Pro Text", fontSize: 10, rect: labelRect, alignment: .center)
        return y + 18
    }

    private func drawText(
        text: String,
        color: NSColor,
        fontName: String,
        fontSize: CGFloat,
        rect: CGRect,
        alignment: NSTextAlignment = .center,
        weight: NSFont.Weight? = nil,
        tracking: CGFloat = 0
    ) {
        var font: NSFont
        if let weight = weight, let customFont = NSFont.systemFont(ofSize: fontSize, weight: weight) as NSFont? {
            font = customFont
        } else {
            font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        }

        let style = NSMutableParagraphStyle()
        style.alignment = alignment

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]

        if tracking != 0 {
            attributes[.kern] = tracking
        }

        text.draw(in: rect, withAttributes: attributes)
    }

    public override func animateOneFrame() {
        let now = Date()
        if now.timeIntervalSince(lastUpdateTime) >= WeatherPreferences.shared.updateInterval {
            fetchWeather()
            lastUpdateTime = now
        }
        animationTime += animationTimeInterval * WeatherPreferences.shared.animationSpeed
        needsDisplay = true
    }

    private func fetchWeather() {
        if WeatherPreferences.shared.simulateWeather {
            processSimulatedWeatherData()
            return
        }
        guard !isFetching else {
            addLog("fetchWeather skipped: isFetching=\(isFetching)")
            return
        }
        isFetching = true
        addLog("Fetching weather for \(currentLatitude), \(currentLongitude)")

        Task {
            do {
                let data = try await client.fetchWeatherData(
                    for: currentLatitude,
                    longitude: currentLongitude,
                    timeZone: TimeZone.current
                )
                addLog("Weather data received: \(data.count) entries")
                await MainActor.run {
                    self.processWeatherData(data)
                    self.initializeParticles()
                    self.isFetching = false
                }
            } catch {
                addLog("Weather fetch failed: \(error)")
                await MainActor.run {
                    self.isFetching = false
                }
            }
        }
    }

    private func processSimulatedWeatherData() {
        let now = Date()
        let condition = WeatherPreferences.shared.simulatedCondition.lowercased()

        let tempRange: ClosedRange<Double>
        let cloudCover: Double
        let precip: String
        let humidity: Int
        let windSpeed: Double

        switch condition {
        case "rain":
            tempRange = 10...18
            cloudCover = 100
            precip = "\(Double.random(in: 2...8).formatted(.number.precision(.fractionLength(1)))) mm"
            humidity = Int.random(in: 80...98)
            windSpeed = Double.random(in: 3...7)
        case "snow":
            tempRange = -5...5
            cloudCover = 90
            precip = "\(Double.random(in: 1...4).formatted(.number.precision(.fractionLength(1)))) mm"
            humidity = Int.random(in: 70...90)
            windSpeed = Double.random(in: 2...5)
        case "thunderstorm":
            tempRange = 15...25
            cloudCover = 100
            precip = "\(Double.random(in: 5...15).formatted(.number.precision(.fractionLength(1)))) mm"
            humidity = Int.random(in: 75...95)
            windSpeed = Double.random(in: 5...10)
        case "fog", "mist":
            tempRange = 5...15
            cloudCover = 100
            precip = "0 mm"
            humidity = Int.random(in: 85...100)
            windSpeed = Double.random(in: 1...3)
        case "cloudy", "overcast":
            tempRange = 10...20
            cloudCover = 90
            precip = "0 mm"
            humidity = Int.random(in: 60...80)
            windSpeed = Double.random(in: 2...5)
        default: // sunny, clear, etc.
            tempRange = 18...28
            cloudCover = 20
            precip = "0 mm"
            humidity = Int.random(in: 40...60)
            windSpeed = Double.random(in: 1...4)
        }

        currentTemp = String(format: "%.0f°C", Double.random(in: tempRange))
        currentIcon = iconForCondition(condition)
        currentWind = String(format: "%.0f km/h", windSpeed * 3.6)
        currentWindSpeed = max(0.5, min(15.0, windSpeed))
        currentPressure = Double.random(in: 980...1040)
        currentCloudCover = cloudCover
        currentPrecip = precip
        currentHumidity = String(format: "%d%%", humidity)
        currentCondition = condition
        lastUpdateTime = now

        addLog("Simulated weather: \(condition), temp=\(currentTemp)")
        initializeParticles()
    }

    private func processWeatherData(_ data: [WeatherData]) {
        let now = Date()
        let calendar = Calendar.current

        let current = data.min { abs($0.timestamp.timeIntervalSince(now)) < abs($1.timestamp.timeIntervalSince(now)) }
            ?? data.first

        guard let current = current else {
            addLog("processWeatherData: no current data")
            return
        }

        addLog("Processing weather: temp=\(current.temperature ?? 0), icon=\(current.icon), wind=\(current.windSpeed), precip=\(current.amount), humidity=\(current.humidity)")
//        for (i, entry) in data.prefix(10).enumerated() {
//            addLog("  [\(i)] \(entry.timestamp) temp=\(entry.temperature ?? -999) precip=\(entry.amount) prob=\(entry.probability) icon=\(entry.icon)")
//        }

        currentTemp = String(format: "%.0f°C", current.temperature ?? 22)
        currentIcon = iconForCondition(current.icon)
        currentWind = String(format: "%.0f km/h", (current.windSpeed) * 3.6)
        currentWindSpeed = max(0.5, min(15.0, current.windSpeed))
        currentWindDirection = current.windDirection
        currentPressure = current.pressure
        currentCloudCover = current.cloud
        currentPrecip = (current.amount) > 0 ? String(format: "%.1f mm", current.amount) : "0 mm"
        currentHumidity = String(format: "%.0f%%", current.humidity)
        currentCondition = current.icon

        forecast = data
            .filter { $0.timestamp > now && $0.timestamp < calendar.date(byAdding: .hour, value: 12, to: now)! }
            .prefix(6)
            .map { entry in
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                formatter.timeZone = TimeZone.current
                let precipStr = (entry.amount) > 0 ? String(format: "%.1fmm", entry.amount) : "0 mm"
                //addLog("  Forecast entry: time=\(formatter.string(from: entry.timestamp)) temp=\(entry.temperature ?? -999) precip=\(entry.amount) -> \(precipStr)")
                return ForecastEntry(
                    time: formatter.string(from: entry.timestamp),
                    icon: iconForCondition(entry.icon),
                    temperature: String(format: "%.0f°", entry.temperature ?? 0),
                    precipitation: precipStr,
                    windSpeed: String(format: "%.0fkm/h", (entry.windSpeed) * 3.6)
                )
            }
        addLog("Forecast entries: \(forecast.count)")
    }

    private func iconForCondition(_ icon: String) -> String {
        switch icon.lowercased() {
        case "sunny", "clear": return "☀️"
        case "partlycloudy": return "🌤"
        case "cloudy": return "⛅️"
        case "overcast": return "☁️"
        case "rain", "lightrain": return "🌧"
        case "heavyrain": return "🌧"
        case "snow", "lightsnow": return "❄️"
        case "heavysnow": return "❄️"
        case "sleet": return "🌨"
        case "thunderstorm": return "⛈"
        case "fog", "mist": return "🌫"
        default: return "🌤"
        }
    }

    public override var hasConfigureSheet: Bool { true }
    
    public override var configureSheet: NSWindow? {
        configureSheetController = ConfigurationSheetController()
        return configureSheetController?.window
    }
}
