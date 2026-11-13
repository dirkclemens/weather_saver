import AppKit

/// Frosted glass card showing current conditions, details and the hourly forecast.
/// With `Options.glossy` it uses Apple's Liquid Glass (macOS 26+) or a drawn glossy look.
final class WeatherCardView: NSView {

    struct Options: Equatable {
        var showForecast = true
        var showDetails = true
        var showLocation = true
        var metric = true
        var locationName = ""
        var compact = false
        var glossy = false
    }

    var snapshot: WeatherSnapshot? { didSet { canvas.needsDisplay = true } }
    var isNight = false { didSet { if oldValue != isNight { canvas.needsDisplay = true } } }
    var options = Options() {
        didSet {
            guard oldValue != options else { return }
            updateBackdrop()
            canvas.needsDisplay = true
        }
    }
    var scale: CGFloat = 1 {
        didSet {
            guard oldValue != scale else { return }
            updateBackdrop()
            canvas.needsDisplay = true
        }
    }

    private let backdrop = NSVisualEffectView()
    private var glassView: NSView?
    private let canvas = CardCanvas()

    /// True when the native Liquid Glass material is behind the canvas.
    fileprivate var usesNativeGlass: Bool { glassView?.isHidden == false }

    private var cornerRadius: CGFloat { (options.compact ? 18 : 28) * scale }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)

        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = cornerRadius
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        canvas.card = self
        canvas.autoresizingMask = [.width, .height]
        canvas.frame = bounds
        addSubview(canvas)
        updateBackdrop()
    }

    /// Switches between the frosted HUD material and Liquid Glass.
    private func updateBackdrop() {
        backdrop.layer?.cornerRadius = cornerRadius
        if #available(macOS 26.0, *) {
            if options.glossy, glassView == nil {
                let glass = NSGlassEffectView()
                glass.style = .clear
                glass.tintColor = NSColor(calibratedRed: 0.03, green: 0.06, blue: 0.12, alpha: 0.18)
                glass.autoresizingMask = [.width, .height]
                glass.frame = bounds
                addSubview(glass, positioned: .below, relativeTo: canvas)
                glassView = glass
            }
            (glassView as? NSGlassEffectView)?.cornerRadius = cornerRadius
        }
        glassView?.isHidden = !options.glossy
        backdrop.isHidden = options.glossy && glassView != nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Width and height the card wants for the given available space.
    func preferredSize(in available: CGSize) -> CGSize {
        let width = min(available.width * 0.9, (options.compact ? 270 : 720) * scale)
        return CGSize(width: width, height: canvas.render(width: width, draw: false))
    }

    func refreshClock() { canvas.needsDisplay = true }

    fileprivate var cardCornerRadius: CGFloat { cornerRadius }
}

// MARK: - Drawing

private final class CardCanvas: NSView {
    weak var card: WeatherCardView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let card = card else { return }
        let radius = card.cardCornerRadius
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        if card.options.glossy {
            drawGlossy(shape: shape, rect: rect, native: card.usesNativeGlass, scale: card.scale)
        } else {
            // Tint + subtle top light, so the card reads well on bright skies too.
            NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.10, alpha: 0.30).setFill()
            shape.fill()
            if let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.07), NSColor.white.withAlphaComponent(0)]) {
                sheen.draw(in: shape, angle: -90)
            }
            NSColor.white.withAlphaComponent(0.13).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }

        _ = render(width: bounds.width, draw: true)
    }

    /// Glass look: specular highlight on the upper part, a light-catching rim that is
    /// brightest at the top-left and fades towards the bottom-right, and a faint inner glow
    /// along the lower edge. With native Liquid Glass most of this comes from the material,
    /// so only lighter accents are added.
    private func drawGlossy(shape: NSBezierPath, rect: CGRect, native: Bool, scale s: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = shape.cgPath

        // Slight dark tint keeps white text readable on bright skies.
        NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.10, alpha: native ? 0.10 : 0.22).setFill()
        shape.fill()

        // Specular highlight: a broad soft band across the top.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let sheen = NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(native ? 0.10 : 0.20), 0),
            (NSColor.white.withAlphaComponent(native ? 0.03 : 0.07), 0.35),
            (NSColor.white.withAlphaComponent(0), 0.6)) {
            sheen.draw(in: rect, angle: -90)
        }
        // Faint light bouncing up from the bottom edge.
        if let bounce = NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(native ? 0.03 : 0.06), 0),
            (NSColor.white.withAlphaComponent(0), 0.25)) {
            bounce.draw(in: rect, angle: 90)
        }
        ctx.restoreGState()

        // Rim light: stroke clipped and filled with a diagonal gradient.
        let rimWidth = max(1, 1.5 * s)
        let rim = path.copy(strokingWithWidth: rimWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.saveGState()
        ctx.addPath(rim)
        ctx.clip()
        if let rimGradient = NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(native ? 0.45 : 0.6), 0),
            (NSColor.white.withAlphaComponent(0.12), 0.45),
            (NSColor.white.withAlphaComponent(0.06), 0.7),
            (NSColor.white.withAlphaComponent(native ? 0.2 : 0.3), 1)) {
            // Same convention as the top sheen (-90° = top → bottom): -45° = top-left → bottom-right.
            rimGradient.draw(in: rect, angle: -45)
        }
        ctx.restoreGState()
    }

    // MARK: Layout + rendering (shared by measuring and drawing)

    func render(width: CGFloat, draw: Bool) -> CGFloat {
        guard let card = card else { return 0 }
        let s = card.scale
        let o = card.options
        let snap = card.snapshot ?? .placeholder
        let hasData = card.snapshot != nil
        let isNight = snap.isNightIcon ?? card.isNight
        let pad = (o.compact ? 20 : 34) * s
        let inner = width - pad * 2
        var y = pad

        if o.compact {
            if o.showLocation, !o.locationName.isEmpty {
                if draw { text(o.locationName.uppercased(), x: pad, y: y, size: 10 * s, weight: .semibold, alpha: 0.75, kern: 1.6 * s, maxWidth: inner) }
                y += 20 * s
            }
            let hero = 64 * s
            if draw {
                symbol(snap.condition.symbolName(isNight: isNight), size: 46 * s, in: CGRect(x: pad, y: y, width: hero, height: hero))
                text(hasData ? formatTemp(snap.temperature, o) : "—", x: pad + hero + 12 * s, y: y + hero / 2 - 34 * s,
                     size: 54 * s, weight: .thin, alpha: 1)
            }
            y += hero + 4 * s
            if draw { text(snap.condition.title, x: pad, y: y, size: 13 * s, weight: .medium, alpha: 0.8, maxWidth: inner) }
            y += 18 * s
            return y + pad
        }

        // Header: location + date on the left, clock on the right
        let now = Date()
        if draw {
            if o.showLocation, !o.locationName.isEmpty {
                text(o.locationName.uppercased(), x: pad, y: y, size: 13 * s, weight: .semibold, alpha: 0.82, kern: 2.4 * s, maxWidth: inner * 0.65)
            }
            text(Self.dateFormatter.string(from: now), x: pad, y: y + 21 * s, size: 14 * s, weight: .regular, alpha: 0.5, maxWidth: inner * 0.65)
            text(Self.timeFormatter.string(from: now), x: pad, y: y - 2 * s, size: 34 * s, weight: .ultraLight, alpha: 0.9,
                 align: .right, maxWidth: inner, monospaced: true)
        }
        y += 44 * s + 20 * s

        // Hero: symbol, temperature, condition
        let heroH = 116 * s
        if draw {
            symbol(snap.condition.symbolName(isNight: isNight), size: 76 * s, in: CGRect(x: pad - 6 * s, y: y, width: heroH, height: heroH))
            text(hasData ? formatTemp(snap.temperature, o) : "—", x: pad + heroH + 6 * s, y: y + heroH / 2 - 64 * s,
                 size: 108 * s, weight: .thin, alpha: 1, monospaced: true)
            text(snap.condition.title, x: pad, y: y + heroH / 2 - 30 * s, size: 22 * s, weight: .medium, alpha: 0.95,
                 align: .right, maxWidth: inner)
            if let hi = snap.dayHigh, let lo = snap.dayLow {
                text("H \(formatTemp(hi, o))   L \(formatTemp(lo, o))", x: pad, y: y + heroH / 2 + 2 * s, size: 15 * s,
                     weight: .regular, alpha: 0.6, align: .right, maxWidth: inner, monospaced: true)
            }
        }
        y += heroH + 22 * s

        // Details row
        if o.showDetails {
            if draw { hairline(y: y, x: pad, width: inner) }
            y += 20 * s
            let items: [(String, String, String)] = [
                ("wind", "WIND", formatWind(snap, o)),
                ("drop.fill", "PRECIP", formatPrecip(snap.precipitation, o)),
                ("humidity.fill", "HUMIDITY", String(format: "%.0f%%", snap.humidity)),
                ("cloud.fill", "CLOUDS", String(format: "%.0f%%", snap.cloudCover)),
                ("gauge.with.dots.needle.33percent", "PRESSURE", formatPressure(snap.pressure, o)),
            ]
            let colW = inner / CGFloat(items.count)
            if draw {
                for (i, item) in items.enumerated() {
                    let x = pad + CGFloat(i) * colW
                    symbol(item.0, size: 11 * s, in: CGRect(x: x, y: y, width: 15 * s, height: 15 * s),
                           multicolor: false, tint: NSColor.white.withAlphaComponent(0.5))
                    text(item.1, x: x + 19 * s, y: y + 0.5 * s, size: 10 * s, weight: .semibold, alpha: 0.48, kern: 1.1 * s, maxWidth: colW - 22 * s)
                    text(item.2, x: x, y: y + 21 * s, size: 18 * s, weight: .medium, alpha: 0.95, maxWidth: colW - 6 * s)
                }
            }
            y += 46 * s + 20 * s
        }

        // Hourly forecast
        if o.showForecast, !snap.hourly.isEmpty {
            if draw { hairline(y: y, x: pad, width: inner) }
            y += 18 * s
            let hours = Array(snap.hourly.prefix(6))
            let colW = inner / CGFloat(hours.count)
            if draw {
                for (i, h) in hours.enumerated() {
                    let x = pad + CGFloat(i) * colW
                    text(Self.hourFormatter.string(from: h.date), x: x, y: y, size: 12 * s, weight: .medium, alpha: 0.55,
                         align: .center, maxWidth: colW, monospaced: true)
                    symbol(h.condition.symbolName(isNight: h.isNight), size: 22 * s,
                           in: CGRect(x: x + colW / 2 - 18 * s, y: y + 20 * s, width: 36 * s, height: 34 * s))
                    text(formatTemp(h.temperature, o), x: x, y: y + 58 * s, size: 18 * s, weight: .medium, alpha: 0.95,
                         align: .center, maxWidth: colW, monospaced: true)
                    // Chance of precipitation, plus the amount when some is expected.
                    let wet = h.precipitation > 0.05
                    let chance = h.probability.map { "\(Int(($0 * 100).rounded()))%" }
                    let line: String
                    switch (chance, wet) {
                    case let (c?, true): line = "\(c) · \(formatPrecip(h.precipitation, o))"
                    case let (c?, false): line = c
                    case (nil, true): line = formatPrecip(h.precipitation, o)
                    case (nil, false): line = "–"
                    }
                    let likely = wet || (h.probability ?? 0) >= 0.3
                    text(line, x: x, y: y + 82 * s, size: 11 * s, weight: .medium,
                         alpha: wet ? 0.95 : (likely ? 0.8 : 0.45), align: .center, maxWidth: colW, monospaced: true,
                         color: likely ? NSColor(calibratedRed: 0.55, green: 0.78, blue: 1, alpha: 1) : .white)
                }
            }
            y += 100 * s + 12 * s
        }

        // Footer
        if draw {
            let updated = hasData ? "Updated \(Self.timeFormatter.string(from: snap.updated))" : "Loading weather…"
            text(updated, x: pad, y: y, size: 10.5 * s, weight: .regular, alpha: 0.36, maxWidth: inner * 0.5)
            let source = snap.isSimulated ? "Simulated weather" : "DWD · Bright Sky"
            text(source, x: pad, y: y, size: 10.5 * s, weight: .regular, alpha: 0.36, align: .right, maxWidth: inner)
        }
        y += 14 * s
        return y + pad - 6 * s
    }

    // MARK: Primitives

    private func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat,
                      kern: CGFloat = 0, align: NSTextAlignment = .left, maxWidth: CGFloat = .greatestFiniteMagnitude,
                      monospaced: Bool = false, color: NSColor = .white) {
        let font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                              : NSFont.systemFont(ofSize: size, weight: weight)
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.withAlphaComponent(alpha),
            .paragraphStyle: style,
        ]
        if kern != 0 { attributes[.kern] = kern }
        let height = ceil(font.ascender - font.descender + font.leading) + 2
        let width = maxWidth == .greatestFiniteMagnitude ? bounds.width - x : maxWidth
        (string as NSString).draw(in: CGRect(x: x, y: y, width: width, height: height), withAttributes: attributes)
    }

    private func symbol(_ name: String, size: CGFloat, in rect: CGRect, multicolor: Bool = true, tint: NSColor = .white) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        var config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        config = config.applying(multicolor ? .preferringMulticolor() : NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let image = base.withSymbolConfiguration(config) else { return }
        let sz = image.size
        let target = CGRect(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2, width: sz.width, height: sz.height)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func hairline(y: CGFloat, x: CGFloat, width: CGFloat) {
        NSColor.white.withAlphaComponent(0.12).setFill()
        CGRect(x: x, y: y, width: width, height: 1).fill()
    }

    // MARK: Formatting

    private func formatTemp(_ celsius: Double?, _ o: WeatherCardView.Options) -> String {
        guard let c = celsius else { return "—" }
        let value = o.metric ? c : c * 9 / 5 + 32
        let rounded = Int(value.rounded())
        return "\(rounded == 0 ? 0 : rounded)°"
    }

    private func formatWind(_ snap: WeatherSnapshot, _ o: WeatherCardView.Options) -> String {
        let speed = o.metric ? String(format: "%.0f km/h", snap.windSpeed * 3.6)
                             : String(format: "%.0f mph", snap.windSpeed * 2.23694)
        guard let dir = snap.windDirection, snap.windSpeed >= 0.5 else { return speed }
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let idx = Int(((dir.truncatingRemainder(dividingBy: 360) + 22.5) / 45).rounded(.down)) % 8
        return "\(speed) \(names[idx])"
    }

    private func formatPrecip(_ mm: Double, _ o: WeatherCardView.Options) -> String {
        if o.metric {
            return mm <= 0 ? "0 mm" : String(format: "%.1f mm", mm)
        }
        return String(format: "%.2f in", mm / 25.4)
    }

    private func formatPressure(_ hPa: Double, _ o: WeatherCardView.Options) -> String {
        o.metric ? String(format: "%.0f hPa", hPa) : String(format: "%.2f inHg", hPa * 0.02953)
    }

    // MARK: Formatters

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        return f
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()
}
