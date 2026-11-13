import AppKit
import QuartzCore

// MARK: - Scene state

/// Everything the animated background needs to know about the weather.
struct SceneState: Equatable {
    var condition: SkyCondition
    var cloudCover: Double          // 0…1
    var precipitation: Double       // 0…1 intensity
    var windSpeed: Double           // m/s
    var windDirection: Double?      // degrees (meteorological, "from")
    var sunElevation: Double        // degrees
    var moonPhase: Double           // 0…1
    var cloudOpacity: Double        // user multiplier (0.5…2)
    var animationSpeed: Double      // user multiplier

    /// Horizontal wind component in m/s (positive = moving to the right).
    var windX: Double {
        guard let dir = windDirection else { return windSpeed * 0.7 }
        return -sin(dir * .pi / 180) * windSpeed
    }

    /// Lighting bucket – colours are baked into the cloud textures, so we only
    /// rebuild when the light changes noticeably.
    fileprivate var lightBucket: Int {
        if sunElevation > 12 { return 100 }
        if sunElevation < -12 { return -100 }
        return Int((sunElevation / 3).rounded())
    }

    /// The scene is rebuilt (with a cross-fade) whenever this key changes.
    fileprivate var rebuildKey: String {
        [
            condition.rawValue,
            "\(Int((cloudCover * 5).rounded()))",
            "\(Int((precipitation * 4).rounded()))",
            "\(Int((windX / 3).rounded()))",
            "\(lightBucket)",
            "\(Int((moonPhase * 16).rounded()))",
            String(format: "%.2f", cloudOpacity),
            String(format: "%.2f", animationSpeed),
        ].joined(separator: "|")
    }
}

// MARK: - Colours

struct RGB {
    var r: CGFloat, g: CGFloat, b: CGFloat
    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { self.r = r; self.g = g; self.b = b }
    func mix(_ o: RGB, _ t: CGFloat) -> RGB {
        let t = clamp01(t)
        return RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t)
    }
    func scaled(_ f: CGFloat) -> RGB { RGB(clamp01(r * f), clamp01(g * f), clamp01(b * f)) }
    func cg(_ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
}

struct ScenePalette {
    var skyTop: RGB, skyMid: RGB, skyBottom: RGB
    var cloudLit: RGB, cloudShade: RGB
    var fog: RGB
    var precipitation: RGB
    var daylight: CGFloat
    var twilight: CGFloat

    init(condition: SkyCondition, sunElevation: Double) {
        let day = CGFloat(smoothstep(-7.0, 6.0, sunElevation))
        let tw = CGFloat(max(0, 1 - abs(sunElevation + 1) / 9))
        let g = condition.greyness
        // Storm darkness reads strongest by day; at night the sky is already dark.
        let dark = 1 - condition.darkness * 0.55 * (0.4 + 0.6 * day)

        let clearDay = (RGB(0.09, 0.25, 0.52), RGB(0.20, 0.41, 0.68), RGB(0.43, 0.60, 0.78))
        let greyDay = (RGB(0.31, 0.34, 0.39), RGB(0.40, 0.43, 0.48), RGB(0.50, 0.53, 0.57))
        let clearNight = (RGB(0.010, 0.016, 0.045), RGB(0.025, 0.042, 0.095), RGB(0.055, 0.080, 0.155))
        let greyNight = (RGB(0.065, 0.066, 0.078), RGB(0.095, 0.094, 0.104), RGB(0.155, 0.138, 0.130))

        var top = clearNight.0.mix(greyNight.0, g).mix(clearDay.0.mix(greyDay.0, g), day)
        var mid = clearNight.1.mix(greyNight.1, g).mix(clearDay.1.mix(greyDay.1, g), day)
        var bottom = clearNight.2.mix(greyNight.2, g).mix(clearDay.2.mix(greyDay.2, g), day)

        let warm = tw * (1 - g * 0.8)
        bottom = bottom.mix(RGB(0.86, 0.50, 0.36), warm * 0.75)
        mid = mid.mix(RGB(0.42, 0.33, 0.50), warm * 0.55)
        top = top.mix(RGB(0.10, 0.14, 0.32), warm * 0.35)

        skyTop = top.scaled(dark)
        skyMid = mid.scaled(dark)
        skyBottom = bottom.scaled(dark)

        let litDay = RGB(0.97, 0.97, 0.98).mix(RGB(0.70, 0.72, 0.76), g)
        let shadeDay = RGB(0.58, 0.63, 0.72).mix(RGB(0.38, 0.41, 0.46), g)
        let litNight = RGB(0.27, 0.28, 0.33).mix(RGB(0.30, 0.28, 0.29), g)
        let shadeNight = RGB(0.10, 0.11, 0.14).mix(RGB(0.13, 0.125, 0.135), g)
        var lit = litNight.mix(litDay, day)
        var shade = shadeNight.mix(shadeDay, day)
        lit = lit.mix(RGB(1.0, 0.70, 0.55), warm * 0.6)
        shade = shade.mix(RGB(0.42, 0.33, 0.44), warm * 0.4)
        cloudLit = lit.scaled(dark)
        cloudShade = shade.scaled(dark)

        fog = RGB(0.30, 0.29, 0.29).mix(RGB(0.80, 0.82, 0.84), day) // night fog glows with city light
        precipitation = RGB(0.55, 0.60, 0.70).mix(RGB(0.84, 0.88, 0.95), day)
        daylight = day
        twilight = warm
    }
}

// MARK: - Procedural noise

/// Tileable fractal value noise (fBm), normalised to 0…1.
final class NoiseField {
    static let shared = NoiseField(size: 256, octaves: 6, seed: 4242)

    let size: Int
    private let values: [Float]

    init(size n: Int, octaves: Int, seed: UInt64) {
        var out = [Float](repeating: 0, count: n * n)
        var rng = SeededRandom(seed: seed)
        var amplitude: Float = 1
        var period = 4
        for _ in 0..<octaves {
            let p = period
            let lattice = (0..<(p * p)).map { _ in Float(rng.unit()) }
            let cell = Float(n) / Float(p)
            out.withUnsafeMutableBufferPointer { o in
                lattice.withUnsafeBufferPointer { l in
                    for y in 0..<n {
                        let fy = Float(y) / cell
                        let y0 = Int(fy) % p, y1 = (y0 + 1) % p
                        var ty = fy - Float(Int(fy)); ty = ty * ty * (3 - 2 * ty)
                        for x in 0..<n {
                            let fx = Float(x) / cell
                            let x0 = Int(fx) % p, x1 = (x0 + 1) % p
                            var tx = fx - Float(Int(fx)); tx = tx * tx * (3 - 2 * tx)
                            let a = l[y0 * p + x0], b = l[y0 * p + x1]
                            let c = l[y1 * p + x0], d = l[y1 * p + x1]
                            let top = a + (b - a) * tx
                            let bottom = c + (d - c) * tx
                            o[y * n + x] += amplitude * (top + (bottom - top) * ty)
                        }
                    }
                }
            }
            amplitude *= 0.52
            period *= 2
        }
        let lo = out.min() ?? 0, hi = out.max() ?? 1
        let k = 1 / max(0.0001, hi - lo)
        values = out.map { ($0 - lo) * k }
        size = n
    }

    /// Bilinear sample; coordinates are in field pixels and wrap around.
    @inline(__always) func sample(_ x: Float, _ y: Float) -> Float {
        let n = Float(size)
        var fx = x.truncatingRemainder(dividingBy: n); if fx < 0 { fx += n }
        var fy = y.truncatingRemainder(dividingBy: n); if fy < 0 { fy += n }
        let x0 = Int(fx) % size, y0 = Int(fy) % size
        let x1 = (x0 + 1) % size, y1 = (y0 + 1) % size
        let tx = fx - Float(Int(fx)), ty = fy - Float(Int(fy))
        let a = values[y0 * size + x0], b = values[y0 * size + x1]
        let c = values[y1 * size + x0], d = values[y1 * size + x1]
        let top = a + (b - a) * tx
        return top + ((c + (d - c) * tx) - top) * ty
    }
}

// MARK: - Textures

enum SkyTextures {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Builds a premultiplied RGBA image; the closure returns straight (non-premultiplied) colour.
    /// Row 0 is the top of the image.
    static func image(width: Int, height: Int, seed: UInt64 = 1,
                      _ pixel: (Int, Int) -> (r: Float, g: Float, b: Float, a: Float)) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var dither = SeededRandom(seed: seed &* 7919)
        bytes.withUnsafeMutableBufferPointer { buf in
            for y in 0..<height {
                for x in 0..<width {
                    let p = pixel(x, y)
                    let a = clamp01(p.a)
                    let n = Float(dither.unit()) - 0.5 // dithering against banding
                    let i = (y * width + x) * 4
                    buf[i] = UInt8(clamp01(p.r * a + n / 255) * 255)
                    buf[i + 1] = UInt8(clamp01(p.g * a + n / 255) * 255)
                    buf[i + 2] = UInt8(clamp01(p.b * a + n / 255) * 255)
                    buf[i + 3] = UInt8(clamp01(a + n / 255) * 255)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A single cumulus cloud built from many spherical puffs. Each puff is shaded like a
    /// lit sphere (bright tops, shaded undersides), which gives the typical cauliflower look.
    /// `ragged` produces flatter, torn low clouds (fractus) for rainy / snowy skies.
    static func cumulus(seed: UInt64, lit: RGB, shade: RGB, ragged: Bool = false) -> CGImage? {
        let w = 512, h = 256
        let fw = Float(w), fh = Float(h)
        var rng = SeededRandom(seed: seed)

        // Envelope of the cloud (pixels, y pointing down).
        let base = fh * (ragged ? Float(rng.range(0.58, 0.66)) : Float(rng.range(0.74, 0.8)))
        let cx = fw * Float(rng.range(0.44, 0.56))
        let a = fw * (ragged ? Float(rng.range(0.36, 0.42)) : Float(rng.range(0.30, 0.38)))
        let b = fh * (ragged ? Float(rng.range(0.22, 0.3)) : Float(rng.range(0.5, 0.64)))
        let skew = Float(rng.range(-0.25, 0.25))

        var puffs: [(x: Float, y: Float, r: Float)] = []
        // Interior: big puffs filling the dome
        let interiorCount = ragged ? 14 : 16
        for _ in 0..<interiorCount {
            let t = Float(rng.range(-0.85, 0.85))
            let top = sqrtf(max(0, 1 - t * t)) * (1 + skew * t)
            let lift = Float(rng.range(0.1, 0.75)) * top
            let r = fh * (ragged ? 0.12 : 0.2) * (0.6 + 0.5 * (1 - abs(t))) * Float(rng.range(0.85, 1.15))
            let y = max(base - b * lift, r * 0.8 + 3)
            puffs.append((cx + t * a, y, r))
        }
        // Body along the base
        let bodyCount = ragged ? 10 : 8
        for i in 0..<bodyCount {
            let t = (Float(i) + Float(rng.range(0.2, 0.8))) / Float(bodyCount) * 2 - 1
            let r = fh * (ragged ? 0.12 : 0.19) * (1 - abs(t) * 0.4) * Float(rng.range(0.85, 1.2))
            puffs.append((cx + t * a * 0.95, base - r * Float(rng.range(0.45, 0.7)), r))
        }
        // Billows on the upper contour, smaller towards the sides
        let billowCount = ragged ? 30 : 40
        for _ in 0..<billowCount {
            let theta = Float(rng.range(0.06, 0.94)) * .pi
            let reach = Float(rng.range(0.75, 1.0))
            var x = cx + cos(theta) * a * reach
            let lift = sin(theta) * (1 + skew * cos(theta))
            var y = base - b * lift * reach
            let r = fh * (ragged ? 0.08 : 0.11) * (0.55 + 0.6 * sin(theta)) * Float(rng.range(0.75, 1.3))
            x += Float(rng.range(-5, 5)); y += Float(rng.range(-3, 3))
            y = max(y, r + 3) // keep inside the texture
            puffs.append((x, y, r))
        }

        // Accumulate density and sphere lighting.
        var density = [Float](repeating: 0, count: w * h)
        var lighting = [Float](repeating: 0, count: w * h)
        let lx: Float = -0.25, ly: Float = -0.72, lz: Float = 0.64 // light from upper left / front
        density.withUnsafeMutableBufferPointer { dens in
            lighting.withUnsafeMutableBufferPointer { light in
                for p in puffs {
                    let x0 = max(0, Int(p.x - p.r)), x1 = min(w - 1, Int(p.x + p.r) + 1)
                    let y0 = max(0, Int(p.y - p.r)), y1 = min(h - 1, Int(p.y + p.r) + 1)
                    guard x0 <= x1, y0 <= y1 else { continue }
                    let inv = 1 / p.r
                    for y in y0...y1 {
                        let dy = (Float(y) + 0.5 - p.y) * inv
                        for x in x0...x1 {
                            let dx = (Float(x) + 0.5 - p.x) * inv
                            let d2 = dx * dx + dy * dy
                            if d2 >= 1 { continue }
                            let f = 1 - d2
                            let weight = f * f
                            let nz = sqrtf(f)
                            let lambert = max(0, dx * lx + dy * ly + nz * lz)
                            let i = y * w + x
                            dens[i] += weight
                            light[i] += weight * lambert
                        }
                    }
                }
            }
        }

        let field = NoiseField.shared
        let ox = Float(rng.range(0, 256)), oy = Float(rng.range(0, 256))
        let litF = (Float(lit.r), Float(lit.g), Float(lit.b))
        let shadeF = (Float(shade.r), Float(shade.g), Float(shade.b))

        // Bilinear lookup so the density can be sampled at warped positions.
        func lookup(_ buf: [Float], _ x: Float, _ y: Float) -> Float {
            let fx = min(max(x, 0), fw - 1.001), fy = min(max(y, 0), fh - 1.001)
            let x0 = Int(fx), y0 = Int(fy)
            let tx = fx - Float(x0), ty = fy - Float(y0)
            let i = y0 * w + x0
            let top = buf[i] + (buf[i + 1] - buf[i]) * tx
            let bottom = buf[i + w] + (buf[i + w + 1] - buf[i + w]) * tx
            return top + (bottom - top) * ty
        }

        return image(width: w, height: h, seed: seed) { x, y in
            let u = Float(x), v = Float(y)
            // Domain warp: frays the round puff outlines into wisps.
            let wx = (field.sample(u * 1.3 + ox, v * 1.3 + oy) - 0.5) * 21
            let wy = (field.sample(u * 1.3 + oy + 50, v * 1.3 + ox) - 0.5) * 13
            let d = lookup(density, u + wx, v + wy)
            if d <= 0.0001 { return (0, 0, 0, 0) }
            let n = field.sample(u * 0.7 + ox, v * 0.7 + oy)
            let fine = field.sample(u * 2 + oy, v * 2 + ox)
            // Noise-modulated base instead of a ruler-straight line.
            let localBase = base + (field.sample(u * 0.26 + ox, 7) - 0.5) * fh * 0.12
            let baseFade = smoothstep(localBase + fh * (ragged ? 0.14 : 0.06), localBase - fh * 0.05, v)
            // Erode mostly the thin outer parts; the dense core stays closed.
            let edge = 1 - smoothstep(0.4, 1.4, d)
            let eroded = d * baseFade - ((1 - n) * 0.3 + (1 - fine) * 0.15) * (0.35 + 0.65 * edge) + 0.12
            var alpha = smoothstep(0.03, ragged ? 0.7 : 0.5, eroded)
            if ragged { alpha *= 0.85 }

            var l = lookup(lighting, u + wx, v + wy) / d
            let heightInCloud = clamp01((localBase - v) / (b * 1.1))
            l = l * (0.45 + 0.55 * heightInCloud) + 0.15 * heightInCloud
            l += (n - 0.5) * 0.25 + (fine - 0.5) * 0.12
            l = powf(clamp01(l), 1.25)
            l += (1 - alpha) * 0.2 // thin edges glow
            if ragged { l = 0.35 + l * 0.5 }
            l = clamp01(l)
            return (shadeF.0 + (litF.0 - shadeF.0) * l,
                    shadeF.1 + (litF.1 - shadeF.1) * l,
                    shadeF.2 + (litF.2 - shadeF.2) * l,
                    alpha)
        }
    }

    /// Torn low cloud (fractus / scud) drifting below the deck on rainy days.
    static func fractus(seed: UInt64, lit: RGB, shade: RGB) -> CGImage? {
        let w = 512, h = 192
        let field = NoiseField.shared
        var rng = SeededRandom(seed: seed)
        let ox = Float(rng.range(0, 256)), oy = Float(rng.range(0, 256))
        let cy = Float(rng.range(0.45, 0.6)), tilt = Float(rng.range(-0.12, 0.12))
        let litF = (Float(lit.r), Float(lit.g), Float(lit.b))
        let shadeF = (Float(shade.r), Float(shade.g), Float(shade.b))
        return image(width: w, height: h, seed: seed) { x, y in
            let u = Float(x) / Float(w), v = Float(y) / Float(h)
            let fx = u * 380 + ox, fy = v * 150 + oy
            let warp = field.sample(fx * 0.5 + 23, fy * 0.5) - 0.5
            let n = field.sample(fx + warp * 120, fy * 1.3 + warp * 40)
            let fine = field.sample(fx * 2.5 + 7, fy * 3 + 11)
            let broad = field.sample(fx * 0.4 + 51, fy * 0.4 + 3)
            let du = (u - 0.5) / 0.38, dv = (v - cy - (u - 0.5) * tilt) / 0.24
            let envelope = expf(-du * du * 1.3 - dv * dv * 1.5) * (0.55 + 0.9 * broad)
            let density = envelope * 1.35 - (1 - n) * 1.1 - (1 - fine) * 0.3
            let alpha = smoothstep(0.0, 0.5, density) * 0.8
            var light = 0.35 + 0.5 * (1 - v) + (n - 0.5) * 0.45 + (1 - alpha) * 0.15
            light = clamp01(light)
            return (shadeF.0 + (litF.0 - shadeF.0) * light,
                    shadeF.1 + (litF.1 - shadeF.1) * light,
                    shadeF.2 + (litF.2 - shadeF.2) * light,
                    alpha)
        }
    }

    /// Horizontally tileable cloud deck (stratus / nimbostratus), densest at the top.
    /// x always maps onto whole periods of the noise field so the texture tiles seamlessly.
    static func deck(seed: UInt64, lit: RGB, shade: RGB, coverage: Float) -> CGImage? {
        let w = 512, h = 256
        let field = NoiseField.shared
        var rng = SeededRandom(seed: seed)
        let oy = Float(rng.range(0, 256))
        let litF = (Float(lit.r), Float(lit.g), Float(lit.b))
        let shadeF = (Float(shade.r), Float(shade.g), Float(shade.b))
        return image(width: w, height: h, seed: seed) { x, y in
            let u = Float(x) / Float(w), v = Float(y) / Float(h)
            let fx = u * 256, fy = v * 170 + oy
            let warp = field.sample(fx * 2 + 17, fy * 0.6 + 5) - 0.5
            let n = field.sample(fx + warp * 50, fy + warp * 25)
            let broad = field.sample(fx + 100, fy * 0.3 + 50)
            let detail = field.sample(fx * 2 + 40, fy * 2 + 9)
            let edge = coverage - v * 1.15 + (broad - 0.5) * 0.6
            let density = edge + (n - 0.5) * 0.8 + (detail - 0.5) * 0.25
            let alpha = smoothstep(-0.05, 0.4, density) * smoothstep(1.0, 0.8, v)
            var light = 0.5 + (n - 0.5) * 0.9 + (detail - 0.5) * 0.3 - v * 0.3 + (1 - alpha) * 0.2
            light = clamp01(light)
            return (shadeF.0 + (litF.0 - shadeF.0) * light,
                    shadeF.1 + (litF.1 - shadeF.1) * light,
                    shadeF.2 + (litF.2 - shadeF.2) * light,
                    alpha)
        }
    }

    /// Horizontally tileable fog bank – a soft, streaky band.
    static func fogBank(seed: UInt64, color: RGB, groundHugging: Bool) -> CGImage? {
        let w = 512, h = 160
        let field = NoiseField.shared
        var rng = SeededRandom(seed: seed)
        let oy = Float(rng.range(0, 256))
        let c = (Float(color.r), Float(color.g), Float(color.b))
        return image(width: w, height: h, seed: seed) { x, y in
            let u = Float(x) / Float(w), v = Float(y) / Float(h)
            let fx = u * 256, fy = v * 100 + oy
            let warp = field.sample(fx * 2 + 31, fy * 0.8 + 77) - 0.5
            let n = field.sample(fx + warp * 70, fy + warp * 25)
            let broad = field.sample(fx + 140, fy * 0.4 + 9)
            // Vertical profile with a noisy upper edge
            let topEdge: Float = 0.18 + (broad - 0.5) * 0.35
            let profile: Float
            if groundHugging {
                profile = smoothstep(topEdge, topEdge + 0.55, v)
            } else {
                profile = smoothstep(topEdge, topEdge + 0.35, v) * smoothstep(1.0, 0.6, v)
            }
            let density = profile * (0.35 + 0.9 * powf(n, 1.6))
            let light = 0.92 + (n - 0.5) * 0.18
            return (c.0 * light, c.1 * light, c.2 * light, clamp01(density))
        }
    }

    /// Thin, fibrous high-altitude streaks ("mares' tails") for otherwise clear skies.
    /// Built from a few long, gently waving strands; tileable horizontally.
    static func cirrus(seed: UInt64, color: RGB) -> CGImage? {
        let w = 1024, h = 160
        let field = NoiseField.shared
        var rng = SeededRandom(seed: seed)
        let c = (Float(color.r), Float(color.g), Float(color.b))
        struct Strand { var y: Float; var amp: Float; var waves: Float; var phase: Float; var thick: Float; var offset: Float }
        let strands = (0..<7).map { _ in
            Strand(y: Float(rng.range(0.25, 0.75)), amp: Float(rng.range(0.03, 0.12)),
                   waves: Float(Int(rng.range(1, 3.99))), phase: Float(rng.range(0, 1)),
                   thick: Float(rng.range(0.04, 0.09)), offset: Float(rng.range(0, 256)))
        }
        return image(width: w, height: h, seed: seed) { x, y in
            let u = Float(x) / Float(w), v = Float(y) / Float(h)
            var a: Float = 0
            for s in strands {
                let center = s.y + s.amp * sinf(2 * .pi * (u * s.waves + s.phase))
                // Strand presence varies along its length (periodic in u).
                let presence = smoothstep(0.42, 0.72, field.sample(u * 256 + s.offset, s.offset))
                let thickness = s.thick * (0.5 + field.sample(u * 512 + s.offset, s.offset + 40))
                let d = (v - center) / thickness
                a += expf(-d * d) * presence
            }
            // Fine fibres along the strands
            let fibre = field.sample(u * 512, v * 120 + 13)
            a *= smoothstep(0.25, 0.75, fibre) * 0.9 + 0.1
            a *= smoothstep(0, 0.2, v) * smoothstep(1, 0.8, v)
            return (c.0, c.1, c.2, clamp01(a) * 0.6)
        }
    }

    /// A motion-blurred drop; `slant` (radians) tilts it in the direction of travel.
    static func rainStreak(slant: CGFloat) -> CGImage? {
        let h = 96
        let dx = Float(tan(slant)) * Float(h)
        let w = 6 + Int(abs(dx).rounded(.up))
        let x0: Float = dx >= 0 ? 3 : Float(w) - 3
        return image(width: w, height: h) { x, y in
            let v = Float(y) / Float(h - 1)
            let cx = x0 + dx * v
            let across = max(0, 1 - abs(Float(x) + 0.5 - cx) / 2.6)
            let along = smoothstep(0, 0.85, v) * smoothstep(1.0, 0.92, v)
            return (1, 1, 1, along * across * across)
        }
    }

    static func softDot(size: Int = 16, hardness: Float = 0.3) -> CGImage? {
        let r = Float(size) / 2
        return image(width: size, height: size) { x, y in
            let d = hypotf(Float(x) + 0.5 - r, Float(y) + 0.5 - r) / r
            return (1, 1, 1, smoothstep(1, hardness, d))
        }
    }

    /// A snow flake drawn off-centre so that spinning the particle produces a gentle sway.
    static func swayingFlake(blurred: Bool) -> CGImage? {
        let size = 64
        let flakeR: Float = blurred ? 11 : 6
        let cx: Float = blurred ? 40 : 46, cy: Float = 32
        return image(width: size, height: size) { x, y in
            let d = hypotf(Float(x) + 0.5 - cx, Float(y) + 0.5 - cy) / flakeR
            let a = blurred ? smoothstep(1, 0, d) * 0.8 : smoothstep(1, 0.45, d)
            return (1, 1, 1, a)
        }
    }
}

// MARK: - Scene

final class WeatherScene {
    let rootLayer = CALayer()

    private let skyLayer = CAGradientLayer()
    private let vignetteLayer = CAGradientLayer()
    private let flashLayer = CALayer()
    private var contentLayer: CALayer?
    private weak var lightningLayer: CALayer?

    private(set) var state: SceneState?
    private var currentKey = ""
    private var size: CGSize = .zero
    private var textureCache: [String: CGImage] = [:]
    private var textureCacheKey = ""
    private var recording: [(key: String, make: () -> CGImage?)]?
    private var buildGeneration = 0
    private var rng = SeededRandom(seed: UInt64(Date().timeIntervalSince1970))
    private var nextStrike: CFTimeInterval = 0
    var contentsScale: CGFloat = 2 {
        didSet { rootLayer.contentsScale = contentsScale }
    }

    init() {
        rootLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        rootLayer.masksToBounds = true

        skyLayer.startPoint = CGPoint(x: 0.5, y: 1) // top (layers are y-up on macOS)
        skyLayer.endPoint = CGPoint(x: 0.5, y: 0)
        skyLayer.locations = [0, 0.55, 1]
        rootLayer.addSublayer(skyLayer)

        vignetteLayer.type = .radial
        vignetteLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignetteLayer.endPoint = CGPoint(x: 1.15, y: 1.25)
        vignetteLayer.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.42)]
        vignetteLayer.locations = [0, 0.45, 1]
        rootLayer.addSublayer(vignetteLayer)

        flashLayer.backgroundColor = CGColor(srgbRed: 0.82, green: 0.86, blue: 1, alpha: 1)
        flashLayer.opacity = 0
        rootLayer.addSublayer(flashLayer)
    }

    func resize(to newSize: CGSize) {
        guard newSize.width > 1, newSize.height > 1, newSize != size else { return }
        size = newSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.bounds = CGRect(origin: .zero, size: newSize)
        for layer in [skyLayer, vignetteLayer, flashLayer] as [CALayer] {
            layer.frame = rootLayer.bounds
        }
        CATransaction.commit()
        if let state = state {
            currentKey = ""
            apply(state, animated: false)
        }
    }

    func apply(_ newState: SceneState, animated: Bool) {
        state = newState
        let palette = ScenePalette(condition: newState.condition, sunElevation: newState.sunElevation)

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 3 : 0)
        CATransaction.setDisableActions(!animated)
        skyLayer.colors = [palette.skyTop.cg(), palette.skyMid.cg(), palette.skyBottom.cg()]
        CATransaction.commit()

        guard size.width > 1 else { return }
        let key = newState.rebuildKey + "@\(Int(size.width))x\(Int(size.height))"
        guard key != currentKey else { return }
        currentKey = key

        let textureKey = "\(newState.condition.rawValue)|\(newState.lightBucket)|\(Int((newState.cloudCover * 5).rounded()))"
        if textureKey != textureCacheKey {
            textureCache.removeAll()
            textureCacheKey = textureKey
        }

        // Dry run: collect the textures this scene needs without building anything visible.
        recording = []
        build(into: CALayer(), state: newState, palette: palette)
        let missing = recording ?? []
        recording = nil

        buildGeneration += 1
        let generation = buildGeneration
        if missing.isEmpty {
            show(newState, palette: palette, animated: animated)
            return
        }
        // Procedural textures are expensive (especially in debug builds) – create them in
        // the background and fade the finished scene in afterwards.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let images = missing.map { ($0.key, $0.make()) }
            DispatchQueue.main.async {
                guard let self = self, generation == self.buildGeneration, textureKey == self.textureCacheKey else { return }
                for (key, image) in images { self.textureCache[key] = image }
                self.show(newState, palette: palette, animated: true)
            }
        }
    }

    private func show(_ newState: SceneState, palette: ScenePalette, animated: Bool) {
        let content = CALayer()
        content.frame = rootLayer.bounds
        content.speed = Float(max(0.1, newState.animationSpeed))
        content.opacity = animated ? 0 : 1
        rootLayer.insertSublayer(content, above: skyLayer)
        build(into: content, state: newState, palette: palette)

        let old = contentLayer
        contentLayer = content
        nextStrike = CACurrentMediaTime() + rng.range(1.5, 4)

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(animated ? 2.5 : 0)
        CATransaction.setCompletionBlock { old?.removeFromSuperlayer() }
        content.opacity = 1
        old?.opacity = 0
        CATransaction.commit()
    }

    /// Called every frame: schedules lightning strikes.
    func tick() {
        guard let state = state, state.condition == .thunderstorm else { return }
        let now = CACurrentMediaTime()
        guard now >= nextStrike else { return }
        strikeLightning()
        let speed = max(0.25, state.animationSpeed)
        // Occasionally a quick double strike, otherwise a few seconds of calm.
        let pause = rng.unit() < 0.2 ? rng.range(0.6, 1.4) : rng.range(4, 13)
        nextStrike = now + pause / speed
    }

    // MARK: Building

    private func cached(_ key: String, _ make: @escaping () -> CGImage?) -> CGImage? {
        if let image = textureCache[key] { return image }
        if recording != nil {
            if !(recording?.contains { $0.key == key } ?? false) { recording?.append((key, make)) }
            return nil
        }
        let image = make()
        textureCache[key] = image
        return image
    }

    private func build(into content: CALayer, state: SceneState, palette: ScenePalette) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let c = state.condition
        let W = size.width, H = size.height
        let unit = W / 1440 // speeds are tuned for a 1440pt wide screen
        var rng = SeededRandom(seed: c.rawValue.utf8.reduce(UInt64(1000)) { $0 &* 31 &+ UInt64($1) })
        let windSign: CGFloat = state.windX >= 0 ? 1 : -1
        let windMagnitude = CGFloat(max(1, abs(state.windX)))
        let cloudAlpha = CGFloat(state.cloudOpacity)

        // --- Sky bodies --------------------------------------------------
        let night = 1 - palette.daylight
        let starVisibility = night * night * (1 - c.greyness) * CGFloat(1 - state.cloudCover * 0.6)
        // Clouds only get an occluding silhouette when there is something behind them to hide.
        var occlusion: ScenePalette?
        if starVisibility > 0.05 {
            addStars(to: content, visibility: starVisibility)
            occlusion = palette
        }
        if palette.daylight > 0.05 && state.sunElevation > -4 {
            addSun(to: content, state: state, palette: palette)
            occlusion = palette
        }
        if night > 0.5 && c.greyness < 0.7 {
            addMoon(to: content, phase: state.moonPhase, visibility: (night - 0.5) * 2 * (1 - c.greyness))
            occlusion = palette
        }

        // --- High cirrus on clear days -------------------------------------
        if c == .clear || c == .partlyCloudy {
            let color = palette.cloudLit
            if let img = cached("cirrus", { SkyTextures.cirrus(seed: 5, color: color) }) {
                let strip = scrollingStrip(image: img, tileSize: CGSize(width: W * 1.4, height: H * 0.28),
                                           centerY: H * 0.80, speed: 2.5 * unit * windMagnitude,
                                           direction: windSign, phase: 0.3)
                strip.opacity = Float(0.35 * min(1, cloudAlpha))
                content.addSublayer(strip)
            }
        }

        // --- Cloud deck ------------------------------------------------------
        if (c.hasDeck || c == .cloudy) && c != .fog {
            let coverage: Float = c == .cloudy ? 0.55 : (c == .fog ? 0.7 : 1.0)
            let height = H * (c == .cloudy ? 0.62 : 0.78)
            let lit = palette.cloudLit, shade = palette.cloudShade
            if let upper = cached("deck-upper", { SkyTextures.deck(seed: 11, lit: lit.mix(palette.skyMid, 0.25), shade: shade, coverage: coverage) }) {
                let strip = scrollingStrip(image: upper, tileSize: CGSize(width: W * 1.6, height: height),
                                           centerY: H - height / 2, speed: (3 + windMagnitude * 0.8) * unit,
                                           direction: windSign, phase: 0,
                                           opacity: Float(min(1, 0.95 * cloudAlpha)), occludingWith: occlusion)
                content.addSublayer(strip)
            }
            if c != .fog {
                let lowerHeight = H * (c == .cloudy ? 0.45 : 0.6)
                if let lower = cached("deck-lower", { SkyTextures.deck(seed: 23, lit: lit.scaled(0.92), shade: shade.scaled(0.85), coverage: coverage * 0.75) }) {
                    let strip = scrollingStrip(image: lower, tileSize: CGSize(width: W * 1.3, height: lowerHeight),
                                               centerY: H - lowerHeight * 0.42, speed: (5 + windMagnitude * 1.4) * unit,
                                               direction: windSign, phase: 0.5,
                                               opacity: Float(min(1, 0.85 * cloudAlpha)), occludingWith: occlusion)
                    content.addSublayer(strip)
                }
            }
        }

        // --- Lightning sits between the deck and the low clouds -------------
        if c == .thunderstorm {
            let container = CALayer()
            container.frame = content.bounds
            content.addSublayer(container)
            lightningLayer = container
        } else {
            lightningLayer = nil
        }

        // --- Individual clouds ---------------------------------------------
        let cumulusCount: Int
        var ragged = false
        switch c {
        case .clear: cumulusCount = state.cloudCover > 0.08 ? 2 : 0
        case .partlyCloudy: cumulusCount = 3 + Int(state.cloudCover * 8)
        case .cloudy: cumulusCount = 8
        case .fog: cumulusCount = 0
        case .snow, .heavySnow:
            cumulusCount = 0
        default:
            cumulusCount = 6
            ragged = true
        }
        if cumulusCount > 0 {
            var depths = (0..<cumulusCount).map { _ in rng.cg(0, 1) }
            depths.sort()
            for (i, depth) in depths.enumerated() {
                let variant = i % 8
                let lit = ragged ? palette.cloudLit.scaled(0.8) : palette.cloudLit
                let shade = ragged ? palette.cloudShade.scaled(0.75) : palette.cloudShade
                guard let img = cached("cu-\(variant)-\(ragged)", {
                    ragged ? SkyTextures.fractus(seed: UInt64(31 + variant * 17), lit: lit, shade: shade)
                           : SkyTextures.cumulus(seed: UInt64(31 + variant * 17), lit: lit, shade: shade)
                }) else { continue }
                let width = W * (ragged ? rng.cg(0.35, 0.6) : (0.16 + 0.30 * depth) * rng.cg(0.8, 1.25))
                let height = width * (ragged ? 0.38 : 0.5)
                let y = ragged ? H * rng.cg(0.6, 0.92) : H * (0.48 + 0.40 * depth + rng.cg(-0.04, 0.04))
                // Container carries position and animations; the cloud (and its occluder) live inside.
                let layer = CALayer()
                layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
                layer.position = CGPoint(x: W / 2, y: y)
                addCloudImage(img, to: layer, frame: layer.bounds,
                              opacity: Float(min(1, (ragged ? 0.75 : 0.5 + 0.5 * depth) * cloudAlpha)),
                              sceneMinY: y - height / 2, occludingWith: occlusion)
                if windSign < 0 { layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1)) }

                let speed = (ragged ? 1.6 : 1) * (5 + windMagnitude * 2.2) * (0.35 + 0.9 * depth) * unit
                let travelStart = -width / 2 - 20, travelEnd = W + width / 2 + 20
                let anim = CABasicAnimation(keyPath: "position.x")
                anim.fromValue = windSign > 0 ? travelStart : travelEnd
                anim.toValue = windSign > 0 ? travelEnd : travelStart
                anim.duration = Double((travelEnd - travelStart) / max(1, speed))
                anim.repeatCount = .infinity
                anim.timeOffset = anim.duration * ((Double(i) + rng.range(0, 0.7)) / Double(cumulusCount))
                layer.add(anim, forKey: "drift")

                // Clouds slowly change shape – a gentle breathing in scale.
                let breathe = CABasicAnimation(keyPath: "transform.scale.y")
                breathe.fromValue = 0.96
                breathe.toValue = 1.04
                breathe.duration = rng.range(25, 45)
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timeOffset = rng.range(0, 40)
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(breathe, forKey: "breathe")

                content.addSublayer(layer)
            }
        }

        // --- Fog --------------------------------------------------------------
        if c == .fog {
            addFog(to: content, palette: palette, windSign: windSign, unit: unit)
        } else if c == .heavyRain || c == .thunderstorm || c.isSnow {
            // Distant precipitation veils the horizon.
            let haze = CAGradientLayer()
            haze.frame = content.bounds
            haze.startPoint = CGPoint(x: 0.5, y: 0)
            haze.endPoint = CGPoint(x: 0.5, y: 1)
            haze.colors = [palette.fog.cg(c.isSnow ? 0.30 : 0.22), palette.fog.cg(0.06), palette.fog.cg(0)]
            haze.locations = [0, 0.35, 0.7]
            content.addSublayer(haze)
        }

        // --- Precipitation ----------------------------------------------------
        if c.isRain {
            addRain(to: content, state: state, palette: palette, sleet: c == .sleet)
        }
        if c.isSnow {
            addSnow(to: content, state: state, palette: palette)
        }
    }

    // MARK: Components

    /// Two side-by-side copies of a horizontally tileable texture, scrolled seamlessly.
    /// With `occludingWith`, the tiles are cloud images that hide the sky bodies behind them.
    private func scrollingStrip(image: CGImage, tileSize: CGSize, centerY: CGFloat,
                                speed: CGFloat, direction: CGFloat, phase: Double,
                                opacity: Float = 1, occludingWith occlusion: ScenePalette? = nil) -> CALayer {
        let tileW = max(tileSize.width, size.width)
        let strip = CALayer()
        strip.anchorPoint = CGPoint(x: 0, y: 0.5)
        strip.bounds = CGRect(x: 0, y: 0, width: tileW * 2, height: tileSize.height)
        strip.position = CGPoint(x: 0, y: centerY)
        for i in 0..<2 {
            let frame = CGRect(x: CGFloat(i) * tileW, y: 0, width: tileW, height: tileSize.height)
            if occlusion != nil {
                addCloudImage(image, to: strip, frame: frame, opacity: opacity,
                              sceneMinY: centerY - tileSize.height / 2, occludingWith: occlusion)
            } else {
                let tile = CALayer()
                tile.contents = image
                tile.frame = frame
                strip.addSublayer(tile)
            }
        }
        if occlusion == nil { strip.opacity = opacity }
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = direction > 0 ? -tileW : 0
        anim.toValue = direction > 0 ? 0 : -tileW
        anim.duration = Double(tileW / max(0.5, speed))
        anim.repeatCount = .infinity
        anim.timeOffset = anim.duration * phase
        strip.add(anim, forKey: "scroll")
        return strip
    }

    /// Sky colour at height `y` (layer coordinates, y-up) – matches the gradient of `skyLayer`.
    private func skyColor(atY y: CGFloat, palette: ScenePalette) -> RGB {
        let t = clamp01(1 - y / max(1, size.height)) // 0 = top, 1 = bottom
        return t < 0.55 ? palette.skyTop.mix(palette.skyMid, t / 0.55)
                        : palette.skyMid.mix(palette.skyBottom, (t - 0.55) / 0.45)
    }

    /// Adds a cloud image to `parent`. The cloud keeps its (depth-dependent) translucency
    /// against the sky, but when `occlusion` is given an opaque sky-coloured silhouette is
    /// placed right behind it. Over open sky the silhouette is invisible; over the sun, the
    /// moon or stars it blocks them, so clouds really pass in front of them.
    private func addCloudImage(_ image: CGImage, to parent: CALayer, frame: CGRect, opacity: Float,
                               sceneMinY: CGFloat, occludingWith occlusion: ScenePalette?) {
        if let palette = occlusion {
            let occluder = CAGradientLayer()
            occluder.frame = frame
            occluder.startPoint = CGPoint(x: 0.5, y: 1) // top
            occluder.endPoint = CGPoint(x: 0.5, y: 0)
            occluder.colors = [skyColor(atY: sceneMinY + frame.height, palette: palette).cg(),
                               skyColor(atY: sceneMinY + frame.height / 2, palette: palette).cg(),
                               skyColor(atY: sceneMinY, palette: palette).cg()]
            let mask = CALayer()
            mask.frame = occluder.bounds
            mask.contents = image
            occluder.mask = mask
            parent.addSublayer(occluder)
        }
        let cloud = CALayer()
        cloud.contents = image
        cloud.frame = frame
        cloud.opacity = opacity
        parent.addSublayer(cloud)
    }

    private func addSun(to content: CALayer, state: SceneState, palette: ScenePalette) {
        let W = size.width, H = size.height
        let elevation = CGFloat(clamp01(state.sunElevation / 50))
        let center = CGPoint(x: W * 0.82, y: H * (0.14 + 0.62 * elevation))
        let grey = state.condition.greyness
        let warmth = palette.twilight
        let glowColor = RGB(1, 0.97, 0.90).mix(RGB(1, 0.62, 0.38), warmth)
        let strength = palette.daylight * (1 - grey * 0.75)

        let glow = CAGradientLayer()
        glow.type = .radial
        let glowSize = H * (1.5 + warmth * 0.6)
        glow.bounds = CGRect(x: 0, y: 0, width: glowSize, height: glowSize)
        glow.position = center
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.colors = [glowColor.cg(0.42 * strength), glowColor.cg(0.14 * strength), glowColor.cg(0.04 * strength), glowColor.cg(0)]
        glow.locations = [0, 0.12, 0.4, 1]
        content.addSublayer(glow)

        // The disc itself only shows when the sky is not overcast.
        guard grey < 0.5 else { return }
        // Bright core blooming into the glow – no hard disc edge.
        let disc = CAGradientLayer()
        disc.type = .radial
        let r = H * 0.16
        disc.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        disc.position = center
        disc.startPoint = CGPoint(x: 0.5, y: 0.5)
        disc.endPoint = CGPoint(x: 1, y: 1)
        let a = Float(strength) * Float(1 - grey * 1.6)
        disc.colors = [RGB(1, 1, 0.98).cg(1), RGB(1, 1, 0.97).cg(0.95), glowColor.cg(0.55), glowColor.cg(0.16), glowColor.cg(0)]
        disc.locations = [0, 0.13, 0.19, 0.42, 1]
        disc.opacity = a
        content.addSublayer(disc)

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = a * 0.9
        pulse.toValue = a
        pulse.duration = 6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        disc.add(pulse, forKey: "pulse")
    }

    private func addMoon(to content: CALayer, phase: Double, visibility: CGFloat) {
        let W = size.width, H = size.height
        let r = H * 0.032
        let center = CGPoint(x: W * 0.80, y: H * 0.80)
        let illumination = 0.5 - 0.5 * cos(2 * .pi * phase)

        let glow = CAGradientLayer()
        glow.type = .radial
        glow.bounds = CGRect(x: 0, y: 0, width: r * 16, height: r * 16)
        glow.position = center
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        let ga = 0.20 * visibility * CGFloat(0.25 + 0.75 * illumination)
        glow.colors = [RGB(0.85, 0.88, 0.95).cg(ga), RGB(0.6, 0.68, 0.85).cg(ga * 0.3), RGB(0.6, 0.68, 0.85).cg(0)]
        glow.locations = [0, 0.25, 1]
        content.addSublayer(glow)

        // Earthshine – the dark part of the disc is faintly visible.
        let dark = CAShapeLayer()
        dark.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), transform: nil)
        dark.fillColor = RGB(0.6, 0.65, 0.75).cg(0.07 * visibility)
        content.addSublayer(dark)

        guard illumination > 0.02 else { return }
        let path = CGMutablePath()
        let waxing = phase < 0.5
        let k = CGFloat(cos(2 * .pi * phase))
        let steps = 48
        // Bright limb (semicircle) from top to bottom
        for i in 0...steps {
            let theta = CGFloat.pi / 2 - CGFloat.pi * CGFloat(i) / CGFloat(steps)
            let x = center.x + (waxing ? 1 : -1) * r * cos(theta)
            let pt = CGPoint(x: x, y: center.y + r * sin(theta))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        // Terminator (half ellipse) back to the top
        for i in 0...steps {
            let theta = -CGFloat.pi / 2 + CGFloat.pi * CGFloat(i) / CGFloat(steps)
            let x = center.x + (waxing ? k : -k) * r * cos(theta)
            path.addLine(to: CGPoint(x: x, y: center.y + r * sin(theta)))
        }
        path.closeSubpath()
        let moon = CAShapeLayer()
        moon.path = path
        moon.fillColor = RGB(0.93, 0.93, 0.90).cg(0.92 * visibility)
        moon.shadowColor = RGB(0.8, 0.85, 1).cg()
        moon.shadowRadius = r * 0.35
        moon.shadowOpacity = 0.6
        moon.shadowOffset = .zero
        moon.contentsScale = contentsScale
        content.addSublayer(moon)
    }

    private func addStars(to content: CALayer, visibility: CGFloat) {
        let W = size.width, H = size.height
        var rng = SeededRandom(seed: 777)
        let groups = 6
        let total = min(520, Int(W * H / 4500))
        let paths = (0..<groups).map { _ in CGMutablePath() }
        for i in 0..<total {
            // More stars high up, fewer towards the hazy horizon.
            let y = H * CGFloat(1 - pow(rng.unit(), 1.6) * 0.82)
            let x = W * CGFloat(rng.unit())
            let magnitude = pow(rng.unit(), 3)
            let r = 0.35 + CGFloat(magnitude) * 1.1
            paths[i % groups].addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        for (i, path) in paths.enumerated() {
            let layer = CAShapeLayer()
            layer.path = path
            let tint = i % 3 == 0 ? RGB(0.85, 0.9, 1) : (i % 3 == 1 ? RGB(1, 0.96, 0.9) : RGB(1, 1, 1))
            layer.fillColor = tint.cg(1)
            layer.contentsScale = contentsScale
            let base = Float(visibility) * Float(0.55 + 0.45 * Double(i) / Double(groups))
            layer.opacity = base
            let twinkle = CABasicAnimation(keyPath: "opacity")
            twinkle.fromValue = base * 0.35
            twinkle.toValue = base
            twinkle.duration = rng.range(1.6, 4.5)
            twinkle.autoreverses = true
            twinkle.repeatCount = .infinity
            twinkle.timeOffset = rng.range(0, 4)
            twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(twinkle, forKey: "twinkle")
            content.addSublayer(layer)
        }
    }

    private func addFog(to content: CALayer, palette: ScenePalette, windSign: CGFloat, unit: CGFloat) {
        let W = size.width, H = size.height
        var rng = SeededRandom(seed: 99)

        // Overall haze: fog flattens contrast, densest close to the ground.
        let haze = CAGradientLayer()
        haze.frame = content.bounds
        haze.startPoint = CGPoint(x: 0.5, y: 0)
        haze.endPoint = CGPoint(x: 0.5, y: 1)
        haze.colors = [palette.fog.cg(0.62), palette.fog.cg(0.38), palette.fog.cg(0.16), palette.fog.cg(0.08)]
        haze.locations = [0, 0.3, 0.65, 1]
        content.addSublayer(haze)

        // Drifting banks at different heights and speeds (parallax).
        let banks: [(y: CGFloat, h: CGFloat, alpha: Float, speed: CGFloat, ground: Bool)] = [
            (0.62, 0.45, 0.35, 2.0, false),
            (0.44, 0.45, 0.45, 3.0, false),
            (0.28, 0.42, 0.55, 4.5, false),
            (0.14, 0.36, 0.70, 6.5, true),
            (0.06, 0.24, 0.85, 9.0, true),
        ]
        for (i, bank) in banks.enumerated() {
            let fog = palette.fog
            guard let img = cached("fog-\(i % 3)-\(bank.ground)", {
                SkyTextures.fogBank(seed: UInt64(200 + i % 3), color: fog, groundHugging: bank.ground)
            }) else { continue }
            let strip = scrollingStrip(image: img, tileSize: CGSize(width: W * rng.cg(1.3, 1.9), height: H * bank.h),
                                       centerY: H * bank.y, speed: bank.speed * unit, direction: windSign,
                                       phase: rng.range(0, 1))
            strip.opacity = bank.alpha
            content.addSublayer(strip)

            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = bank.alpha * 0.55
            breathe.toValue = bank.alpha
            breathe.duration = rng.range(14, 30)
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timeOffset = rng.range(0, 30)
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            strip.add(breathe, forKey: "breathe")

            let bob = CABasicAnimation(keyPath: "position.y")
            bob.fromValue = H * bank.y - H * 0.015
            bob.toValue = H * bank.y + H * 0.015
            bob.duration = rng.range(20, 40)
            bob.autoreverses = true
            bob.repeatCount = .infinity
            bob.timeOffset = rng.range(0, 40)
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            strip.add(bob, forKey: "bob")
        }
    }

    private func addRain(to content: CALayer, state: SceneState, palette: ScenePalette, sleet: Bool) {
        let W = size.width, H = size.height
        let intensity = CGFloat(max(0.15, state.precipitation)) * (sleet ? 0.6 : 1)
        let k = intensity * W / 1440
        let hs = H / 900
        // Rotating the emitter layer does not work reliably on macOS, so the wind slant is
        // applied to the emission direction and baked into the streak texture instead.
        let angle = CGFloat(max(-0.45, min(0.45, state.windX * 0.04)))
        let angleKey = Int((angle * 40).rounded())
        let bakedAngle = CGFloat(angleKey) / 40
        guard let streak = cached("rain-\(angleKey)", { SkyTextures.rainStreak(slant: bakedAngle) }) else { return }

        let emitter = CAEmitterLayer()
        let margin = W * 0.4
        emitter.frame = CGRect(x: -margin, y: 0, width: W + margin * 2, height: H)
        emitter.emitterPosition = CGPoint(x: emitter.bounds.midX - tan(bakedAngle) * H * 0.5, y: H + 60)
        emitter.emitterSize = CGSize(width: emitter.bounds.width, height: 1)
        emitter.emitterShape = .line
        emitter.emitterMode = .outline

        func cell(rate: CGFloat, velocity: CGFloat, scale: CGFloat, alpha: CGFloat) -> CAEmitterCell {
            let cell = CAEmitterCell()
            cell.contents = streak
            cell.birthRate = Float(rate * k)
            cell.velocity = velocity * hs
            cell.velocityRange = velocity * hs * 0.12
            cell.emissionLongitude = bakedAngle // line emitter: 0 = straight down
            cell.lifetime = Float((H + 120) / (velocity * hs * 0.88 * cos(bakedAngle)))
            cell.scale = scale * hs
            cell.scaleRange = scale * hs * 0.25
            cell.color = palette.precipitation.cg(alpha)
            cell.alphaRange = Float(alpha * 0.4)
            return cell
        }
        emitter.emitterCells = [
            cell(rate: 420, velocity: 950, scale: 0.28, alpha: 0.24),   // far
            cell(rate: 200, velocity: 1300, scale: 0.42, alpha: 0.34),  // middle
            cell(rate: 55, velocity: 1700, scale: 0.65, alpha: 0.45),   // near
        ]
        content.addSublayer(emitter)

        // Small splashes where the drops hit the ground.
        if let dot = cached("dot", { SkyTextures.softDot() }) {
            let splash = CAEmitterLayer()
            splash.frame = content.bounds
            splash.emitterPosition = CGPoint(x: W / 2, y: 2)
            splash.emitterSize = CGSize(width: W * 1.05, height: 1)
            splash.emitterShape = .line
            let s = CAEmitterCell()
            s.contents = dot
            s.birthRate = Float(140 * k)
            s.lifetime = 0.45
            s.velocity = 70 * hs
            s.velocityRange = 40 * hs
            s.emissionLongitude = .pi // line emitter: π = straight up
            s.emissionRange = 0.9
            s.yAcceleration = -420 * hs
            s.scale = 0.18 * hs
            s.scaleRange = 0.08 * hs
            s.color = palette.precipitation.cg(0.35)
            s.alphaSpeed = -0.8
            splash.emitterCells = [s]
            content.addSublayer(splash)
        }
    }

    private func addSnow(to content: CALayer, state: SceneState, palette: ScenePalette) {
        let W = size.width, H = size.height
        let intensity = CGFloat(max(0.2, state.precipitation)) * (state.condition == .sleet ? 0.5 : 1)
        let k = intensity * W / 1440
        let hs = H / 900
        guard let flake = cached("flake", { SkyTextures.swayingFlake(blurred: false) }),
              let bokeh = cached("flake-blur", { SkyTextures.swayingFlake(blurred: true) }) else { return }

        let emitter = CAEmitterLayer()
        let margin = W * 0.35
        emitter.frame = CGRect(x: -margin, y: 0, width: W + margin * 2, height: H)
        emitter.emitterPosition = CGPoint(x: emitter.bounds.midX, y: H + 30)
        emitter.emitterSize = CGSize(width: emitter.bounds.width, height: 1)
        emitter.emitterShape = .line
        emitter.emitterMode = .outline
        let wind = CGFloat(state.windX)
        let tilt = max(-0.5, min(0.5, wind * 0.05))
        let white = RGB(1, 1, 1).mix(palette.precipitation, 0.25)

        func cell(_ image: CGImage, rate: CGFloat, velocity: CGFloat, scale: CGFloat, alpha: CGFloat, spin: CGFloat) -> CAEmitterCell {
            let cell = CAEmitterCell()
            cell.contents = image
            cell.birthRate = Float(rate * k)
            cell.velocity = velocity * hs
            cell.velocityRange = velocity * hs * 0.3
            cell.emissionLongitude = tilt // line emitter: 0 = straight down
            cell.emissionRange = 0.25
            cell.xAcceleration = wind * 2.5 * hs
            cell.lifetime = Float(H * 1.25 / (velocity * hs * 0.7))
            cell.scale = scale * hs
            cell.scaleRange = scale * hs * 0.35
            cell.spin = 0
            cell.spinRange = spin
            cell.color = white.cg(alpha)
            cell.alphaRange = Float(alpha * 0.35)
            return cell
        }
        let layers: [(CGImage, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (flake, 10, 30, 0.26, 0.5, 1.6),    // far
            (flake, 5, 52, 0.5, 0.8, 1.3),      // middle
            (bokeh, 1.3, 95, 1.0, 0.4, 1.0),    // near, out of focus
        ]
        emitter.emitterCells = layers.map { cell($0.0, rate: $0.1, velocity: $0.2, scale: $0.3, alpha: $0.4, spin: $0.5) }
        content.addSublayer(emitter)

        // CAEmitterLayer cannot be pre-warmed on macOS, so a short burst over the whole
        // screen fills the sky with flakes that then fall naturally.
        let burst: CGFloat = 0.4
        let fill = CAEmitterLayer()
        fill.frame = emitter.frame
        fill.emitterPosition = CGPoint(x: fill.bounds.midX, y: H * 0.5)
        fill.emitterSize = CGSize(width: fill.bounds.width, height: H)
        fill.emitterShape = .rectangle
        fill.emitterMode = .surface
        fill.emitterCells = layers.map { l -> CAEmitterCell in
            let c = cell(l.0, rate: l.1, velocity: l.2, scale: l.3, alpha: l.4, spin: l.5)
            // Rectangle emitters use the plain math convention (0 = right), line emitters
            // measure relative to the line (0 = straight down).
            c.emissionLongitude -= .pi / 2
            let secondsOnScreen = H / (l.2 * hs * 0.85)
            c.birthRate = Float(l.1 * k * secondsOnScreen / burst)
            return c
        }
        // The burst is ended by an animation so that it runs on the render server in sync
        // with the emitter, regardless of how busy the main thread is at start-up.
        fill.birthRate = 0
        let stop = CAKeyframeAnimation(keyPath: "birthRate")
        stop.values = [1, 1, 0]
        stop.keyTimes = [0, 0.95, 1]
        stop.duration = Double(burst)
        stop.beginTime = 0
        fill.add(stop, forKey: "burst")
        content.addSublayer(fill)
    }

    // MARK: Lightning

    private func strikeLightning() {
        guard let container = lightningLayer else { return }
        let W = size.width, H = size.height
        let x = W * rng.cg(0.12, 0.88)
        let duration = rng.range(0.7, 1.1)
        let flicker = CAKeyframeAnimation(keyPath: "opacity")
        flicker.values = [0, 1, 0.2, 0.85, 0.1, 0.45, 0]
        flicker.keyTimes = [0, 0.04, 0.12, 0.2, 0.32, 0.42, 1]
        flicker.duration = duration
        flicker.isRemovedOnCompletion = true

        var created: [CALayer] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Cloud illumination
        let glow = CAGradientLayer()
        glow.type = .radial
        let gs = H * rng.cg(0.9, 1.4)
        glow.bounds = CGRect(x: 0, y: 0, width: gs * 1.4, height: gs)
        glow.position = CGPoint(x: x, y: H * rng.cg(0.7, 0.9))
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.colors = [RGB(0.85, 0.88, 1).cg(0.55), RGB(0.7, 0.75, 1).cg(0.18), RGB(0.7, 0.75, 1).cg(0)]
        glow.locations = [0, 0.35, 1]
        glow.opacity = 0
        container.addSublayer(glow)
        created.append(glow)

        // A visible bolt in about half of the strikes; the rest are cloud flashes.
        if rng.unit() < 0.55 {
            let start = CGPoint(x: x, y: H * 0.86)
            let end = CGPoint(x: x + W * rng.cg(-0.12, 0.12), y: H * rng.cg(0.0, 0.35))
            let path = CGMutablePath()
            let main = boltPoints(from: start, to: end, displacement: H * 0.12)
            path.addLines(between: main)
            let branches = CGMutablePath()
            for _ in 0..<Int(rng.range(2, 5)) {
                let idx = Int(rng.range(Double(main.count) * 0.1, Double(main.count) * 0.7))
                let p = main[max(0, min(main.count - 1, idx))]
                let tip = CGPoint(x: p.x + W * rng.cg(-0.1, 0.1), y: p.y - H * rng.cg(0.06, 0.18))
                branches.addLines(between: boltPoints(from: p, to: tip, displacement: H * 0.05))
            }
            for (p, width, alpha) in [(path, CGFloat(2.2), CGFloat(1)), (branches, CGFloat(1.1), CGFloat(0.6))] {
                let bolt = CAShapeLayer()
                bolt.path = p
                bolt.strokeColor = RGB(0.95, 0.96, 1).cg(alpha)
                bolt.fillColor = nil
                bolt.lineWidth = width
                bolt.lineJoin = .round
                bolt.shadowColor = RGB(0.65, 0.72, 1).cg()
                bolt.shadowRadius = 10
                bolt.shadowOpacity = 1
                bolt.shadowOffset = .zero
                bolt.contentsScale = contentsScale
                bolt.opacity = 0
                container.addSublayer(bolt)
                created.append(bolt)
            }
        }
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { created.forEach { $0.removeFromSuperlayer() } }
        for layer in created {
            layer.add(flicker, forKey: "flash")
        }
        let screenFlash = CAKeyframeAnimation(keyPath: "opacity")
        screenFlash.values = [0, 0.16, 0.03, 0.12, 0, 0.05, 0]
        screenFlash.keyTimes = flicker.keyTimes
        screenFlash.duration = duration
        flashLayer.add(screenFlash, forKey: "flash")
        CATransaction.commit()
    }

    private func boltPoints(from a: CGPoint, to b: CGPoint, displacement: CGFloat) -> [CGPoint] {
        if displacement < 4 { return [a, b] }
        let mid = CGPoint(x: (a.x + b.x) / 2 + rng.cg(-displacement, displacement) * 0.5,
                          y: (a.y + b.y) / 2 + rng.cg(-displacement, displacement) * 0.12)
        let left = boltPoints(from: a, to: mid, displacement: displacement / 2)
        let right = boltPoints(from: mid, to: b, displacement: displacement / 2)
        return left + right.dropFirst()
    }
}
