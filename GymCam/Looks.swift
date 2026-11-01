import CoreImage
import Foundation

/// Color grades applied live to the preview and baked into the recorded video.
enum Look: String, CaseIterable, Identifiable {
    case natural, moody, steel, warmFilm, noir, clean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .natural: return "Natural"
        case .moody: return "Moody"
        case .steel: return "Steel"
        case .warmFilm: return "Warm Film"
        case .noir: return "Noir"
        case .clean: return "Clean"
        }
    }

    /// Default film grain strength (scaled by the Film FX slider).
    var grain: Float {
        switch self {
        case .natural: return 0
        case .moody: return 0.25
        case .steel: return 0.3
        case .warmFilm: return 0.45
        case .noir: return 0.55
        case .clean: return 0
        }
    }

    /// Default vignette strength (scaled by the Film FX slider).
    var vignette: Float {
        switch self {
        case .natural: return 0
        case .moody: return 0.6
        case .steel: return 0.45
        case .warmFilm: return 0.5
        case .noir: return 0.8
        case .clean: return 0.15
        }
    }

    /// Per-pixel grade in sRGB (0...1). Baked into a 3D LUT once at launch.
    fileprivate func grade(_ c: RGB) -> RGB {
        switch self {
        case .natural:
            return c
        case .moody:
            // Muted colors, punchy contrast, teal shadows / warm highlights.
            var o = c.saturated(0.78).curved(0.55)
            let l = o.luma
            let sh = (1 - l) * (1 - l)
            let hi = l * l
            o.r += -0.030 * sh + 0.045 * hi
            o.g += 0.012 * sh + 0.015 * hi
            o.b += 0.045 * sh - 0.035 * hi
            return o.faded(black: 0.025, white: 0.97)
        case .steel:
            // Cold, desaturated, gritty — great under harsh gym LEDs.
            var o = c.saturated(0.55).curved(0.7)
            o.r *= 0.96
            o.b = o.b * 1.04 + 0.01
            return o.faded(black: 0.02, white: 0.98)
        case .warmFilm:
            // Faded blacks, golden tones, soft contrast.
            var o = c.saturated(0.9).curved(0.3)
            o.r = o.r * 1.05 + 0.01
            o.g *= 1.01
            o.b *= 0.88
            return o.faded(black: 0.06, white: 0.95)
        case .noir:
            let l = c.luma
            return RGB(r: l, g: l, b: l).curved(0.85).faded(black: 0.03, white: 0.97)
        case .clean:
            // Brighter mids, a touch more color — fixes dim, flat gyms.
            let o = RGB(r: pow(max(c.r, 0), 0.92), g: pow(max(c.g, 0), 0.92), b: pow(max(c.b, 0), 0.94))
            return o.saturated(1.06).curved(0.15)
        }
    }
}

fileprivate struct RGB {
    var r: Float
    var g: Float
    var b: Float

    var luma: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func saturated(_ s: Float) -> RGB {
        let l = luma
        return RGB(r: l + (r - l) * s, g: l + (g - l) * s, b: l + (b - l) * s)
    }

    func curved(_ amount: Float) -> RGB {
        RGB(r: RGB.sCurve(r, amount), g: RGB.sCurve(g, amount), b: RGB.sCurve(b, amount))
    }

    func faded(black: Float, white: Float) -> RGB {
        let range = white - black
        return RGB(r: black + r * range, g: black + g * range, b: black + b * range)
    }

    static func sCurve(_ value: Float, _ amount: Float) -> Float {
        let x = min(max(value, 0), 1)
        let smooth = x * x * (3 - 2 * x)
        return x + (smooth - x) * amount
    }
}

/// Builds the Core Image graph for a look: LUT → vignette → animated film grain.
final class FilterPipeline {
    static let cubeSize = 33

    private var cubes: [Look: Data] = [:]
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let noise: CIImage

    init() {
        for look in Look.allCases where look != .natural {
            cubes[look] = FilterPipeline.makeCube(look)
        }
        noise = CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
    }

    private static func makeCube(_ look: Look) -> Data {
        let n = cubeSize
        let d = Float(n - 1)
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let o = look.grade(RGB(r: Float(r) / d, g: Float(g) / d, b: Float(b) / d))
                    values.append(min(max(o.r, 0), 1))
                    values.append(min(max(o.g, 0), 1))
                    values.append(min(max(o.b, 0), 1))
                    values.append(1)
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func apply(_ look: Look, to input: CIImage, amount: Float, frame: Int) -> CIImage {
        let extent = input.extent
        var image = input

        if let cube = cubes[look] {
            image = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": FilterPipeline.cubeSize,
                "inputCubeData": cube,
                "inputColorSpace": srgb
            ])
        }

        let vignette = look.vignette * amount
        if vignette > 0.01 {
            image = image.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: vignette,
                kCIInputRadiusKey: 1.6
            ])
        }

        let grain = look.grain * amount
        if grain > 0.01 {
            let k = CGFloat(grain) * 0.16
            let bias = 0.5 - k / 2
            let scale = max(1, extent.width / 1080) * 1.4
            let ox = CGFloat((frame &* 7919) % 997)
            let oy = CGFloat((frame &* 6151) % 991)
            let grainLayer = noise
                .transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .cropped(to: extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: k, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: k, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1)
                ])
            image = grainLayer.applyingFilter("CISoftLightBlendMode", parameters: [
                kCIInputBackgroundImageKey: image
            ])
        }

        return image.cropped(to: extent)
    }
}
