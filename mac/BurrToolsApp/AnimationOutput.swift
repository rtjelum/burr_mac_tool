import AppKit
import AVFoundation
import BurrCore
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SceneKit
import UniformTypeIdentifiers

// MARK: - output files

/// Receives rendered frames, each with how long it should show.
protocol FrameSink {
    func add(_ image: CGImage, delay: Double) throws
    func finish() throws
}

/// Animated GIF via ImageIO (256 colours per frame).
final class GifSink: FrameSink {
    private let dest: CGImageDestination

    init(url: URL, frameCount: Int) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw BurrError(message: "Could not create the GIF file.")
        }
        dest = d
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
    }

    func add(_ image: CGImage, delay: Double) throws {
        let d = (delay * 100).rounded() / 100   // GIF delays are in 1/100 s
        CGImageDestinationAddImage(dest, image, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: d,
                kCGImagePropertyGIFUnclampedDelayTime: d,
            ],
        ] as CFDictionary)
    }

    func finish() throws {
        guard CGImageDestinationFinalize(dest) else { throw BurrError(message: "Could not write the GIF file.") }
    }
}

/// A single PNG image (the first frame it gets).
final class PngSink: FrameSink {
    private let url: URL
    private var written = false
    init(url: URL) { self.url = url }

    func add(_ image: CGImage, delay: Double) throws {
        guard !written else { return }
        written = true
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BurrError(message: "Could not create the PNG file.")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw BurrError(message: "Could not write the PNG file.") }
    }

    func finish() throws {}
}

/// H.264 MP4 video at 30 frames per second; long frames are repeated.
final class MovieSink: FrameSink {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let size: Int
    private let fps: Int32 = 30
    private var frameIndex: Int64 = 0

    init(url: URL, size: Int) throws {
        try? FileManager.default.removeItem(at: url)
        self.size = size
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: size * size * 12],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw BurrError(message: "Could not create the video: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
    }

    func add(_ image: CGImage, delay: Double) throws {
        guard let pool = adaptor.pixelBufferPool else { throw BurrError(message: "Could not write the video.") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw BurrError(message: "Could not write the video.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let repeats = max(1, Int((delay * Double(fps)).rounded()))
        for _ in 0..<repeats {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: frameIndex, timescale: fps)) {
                throw BurrError(message: "Could not write the video: \(writer.error?.localizedDescription ?? "unknown error")")
            }
            frameIndex += 1
        }
    }

    func finish() throws {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw BurrError(message: "Could not write the video: \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }
}

// MARK: - studio look

/// A glossy "product shot" look: rounded plastic pieces, soft studio lights with
/// reflections and shadows, and a dark smoky background.
enum StudioLook {
    /// Dark smoky backdrop with a soft glow behind the puzzle, a vignette and a few dust specks.
    /// `shadow`: centre and radii of a soft contact shadow, as fractions of the
    /// image (origin bottom left), or nil for none.
    static func background(size: Int, shadow: (center: CGPoint, radii: CGSize)? = nil) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let s = CGFloat(size)

        // soft clouds: blurred noise, kept faint
        let noise = CIFilter.randomGenerator().outputImage!
            .transformed(by: CGAffineTransform(scaleX: 6, y: 6))
            .applyingGaussianBlur(sigma: Double(s) * 0.035)
            .cropped(to: rect)
        let clouds = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.09, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0.09, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0.10, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -0.02, y: -0.018, z: -0.015, w: 0),
        ])

        // lighter glow behind the object, dark edges
        let glow = CIFilter.radialGradient()
        glow.center = CGPoint(x: s * 0.5, y: s * 0.52)
        glow.radius0 = Float(s * 0.05)
        glow.radius1 = Float(s * 0.75)
        glow.color0 = CIColor(red: 0.13, green: 0.14, blue: 0.155)
        glow.color1 = CIColor(red: 0.015, green: 0.016, blue: 0.02)
        let base = glow.outputImage!.cropped(to: rect)
        var image = clouds.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: base])

        // a few warm dust specks
        var specks = CIImage.empty().cropped(to: rect)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<70 {
            let r = CGFloat.random(in: 0.6...1.8, using: &rng) * s / 1024
            let c = CGPoint(x: CGFloat.random(in: 0.25...0.75, using: &rng) * s, y: CGFloat.random(in: 0.25...0.8, using: &rng) * s)
            let dot = CIFilter.radialGradient()
            dot.center = c
            dot.radius0 = 0
            dot.radius1 = Float(r * 2)
            dot.color0 = CIColor(red: 0.9, green: 0.75, blue: 0.5, alpha: CGFloat.random(in: 0.15...0.5, using: &rng))
            dot.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            specks = dot.outputImage!.cropped(to: rect).composited(over: specks)
        }
        image = specks.composited(over: image).cropped(to: rect)

        if let shadow {
            // a round dark gradient squashed into an ellipse
            let disc = CIFilter.radialGradient()
            disc.center = .zero
            disc.radius0 = 0
            disc.radius1 = 100
            disc.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.85)
            disc.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            let ellipse = disc.outputImage!
                .transformed(by: CGAffineTransform(scaleX: shadow.radii.width * s / 100, y: shadow.radii.height * s / 100))
                .transformed(by: CGAffineTransform(translationX: shadow.center.x * s, y: shadow.center.y * s))
                .cropped(to: rect)
            image = ellipse.composited(over: image).cropped(to: rect)
        }

        return CIContext().createCGImage(image, from: rect)
    }

    /// Environment for reflections: a dark studio with big soft boxes.
    /// Drawn upside down, because the puzzle scene uses -y as "up" while
    /// SceneKit expects +y up in the environment image.
    static func environment() -> NSImage {
        let w = 1024, h = 512
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        // NSImage y runs bottom to top; with the flip, the bottom rows are the sky
        NSGradient(starting: NSColor(calibratedWhite: 0.07, alpha: 1), ending: NSColor(calibratedWhite: 0.0, alpha: 1))?
            .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 90)
        // soft boxes with a bright core and a soft falloff: on glossy plastic they
        // show up as smooth highlight gradients sweeping across the faces
        func softbox(_ r: NSRect, _ white: CGFloat) {
            for i in 0..<12 {
                let t = CGFloat(i) / 11
                let inset = -t * 40
                NSColor(calibratedWhite: white, alpha: 0.12 + 0.88 * (1 - t) * (1 - t)).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: inset, dy: inset), xRadius: 40, yRadius: 40).fill()
            }
            NSColor(calibratedWhite: white, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 30, yRadius: 30).fill()
        }
        softbox(NSRect(x: 80, y: 50, width: 380, height: 170), 1.0)     // big key box, high front left
        softbox(NSRect(x: 600, y: 80, width: 260, height: 120), 0.75)   // second box
        softbox(NSRect(x: 300, y: 0, width: 420, height: 24), 0.8)     // overhead strip
        softbox(NSRect(x: 470, y: 230, width: 110, height: 40), 0.6)    // low accent for edge glints
        // a narrow bright strip about 30° below the horizon: side faces, seen from
        // above, reflect it as a glossy streak across part of the face
        for i in 0..<8 {
            let t = CGFloat(i) / 7
            NSColor(calibratedWhite: 1, alpha: 0.5 * (1 - t) * (1 - t)).setFill()
            NSRect(x: 0, y: 342 - t * 18, width: CGFloat(w), height: 8 + t * 36).fill()
        }
        NSColor(calibratedWhite: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 344, width: CGFloat(w), height: 5).fill()
        img.unlockFocus()
        return img
    }

    static func material(_ c: (r: Float, g: Float, b: Float)) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
        m.roughness.contents = 0.14
        m.metalness.contents = 0.0
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.02
        m.isDoubleSided = true
        return m
    }

    /// Geometry from a library mesh with rounded-looking edges: on the narrow
    /// bevel faces, normals are averaged (weighted by area) with the faces next
    /// to them, so a bevel shades smoothly from one side of the piece to the other.
    /// `smoothBevels`: for cube grids, where the flat faces are the axis-aligned ones.
    static func geometry(_ mesh: UnsafeMutablePointer<BTMesh>, color: (r: Float, g: Float, b: Float),
                         smoothBevels: Bool) -> SCNGeometry {
        let m = mesh.pointee
        let triCount = Int(m.triangleCount)
        var pos = [SIMD3<Float>](), faceN = [SIMD3<Float>](), area = [Float]()
        pos.reserveCapacity(triCount * 3)
        for t in 0..<triCount {
            let v = (0..<3).map { k in SIMD3(m.positions[(t * 3 + k) * 3], m.positions[(t * 3 + k) * 3 + 1], m.positions[(t * 3 + k) * 3 + 2]) }
            pos.append(contentsOf: v)
            let c = simd_cross(v[1] - v[0], v[2] - v[0])
            let len = simd_length(c)
            area.append(len / 2)
            faceN.append(len > 0 ? c / len : SIMD3(m.normals[t * 9], m.normals[t * 9 + 1], m.normals[t * 9 + 2]))
        }
        // make face normals point the same way as the library's (outward) normals
        for t in 0..<triCount {
            let lib = SIMD3(m.normals[t * 9], m.normals[t * 9 + 1], m.normals[t * 9 + 2])
            if simd_dot(lib, faceN[t]) < 0 { faceN[t] = -faceN[t] }
        }

        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3(Int32((p.x * 4096).rounded()), Int32((p.y * 4096).rounded()), Int32((p.z * 4096).rounded()))
        }
        var corners: [SIMD3<Int32>: [Int]] = [:]
        for i in 0..<pos.count { corners[key(pos[i]), default: []].append(i / 3) }

        let crease: Float = cos(60 * .pi / 180)
        var normals = [SIMD3<Float>](repeating: .zero, count: pos.count)
        for i in 0..<pos.count {
            let t = i / 3
            // flat cube faces keep their exact normal; only the bevels are smoothed
            let f = simd_abs(faceN[t])
            if !smoothBevels || max(f.x, f.y, f.z) > 0.999 {
                normals[i] = faceN[t]
                continue
            }
            var n = SIMD3<Float>(repeating: 0)
            for u in corners[key(pos[i])] ?? [] where simd_dot(faceN[u], faceN[t]) > crease {
                n += faceN[u] * area[u]
            }
            normals[i] = simd_length(n) > 0 ? simd_normalize(n) : faceN[t]
        }

        let stride = MemoryLayout<SIMD3<Float>>.stride
        let vsrc = SCNGeometrySource(data: pos.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex,
                                     vectorCount: pos.count, usesFloatComponents: true, componentsPerVector: 3,
                                     bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let nsrc = SCNGeometrySource(data: normals.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .normal,
                                     vectorCount: normals.count, usesFloatComponents: true, componentsPerVector: 3,
                                     bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let element = SCNGeometryElement(indices: (0..<Int32(pos.count)).map { $0 }, primitiveType: .triangles)
        let g = SCNGeometry(sources: [vsrc, nsrc], elements: [element])
        g.materials = [material(color)]
        return g
    }

    /// Background, lights and camera effects for a scene whose "up" is -y.
    static func setUp(scene: SCNScene, camera: SCNCamera, center: SIMD3<Float>, radius: Float, bottom: Float, size: Int,
                      shadow: (center: CGPoint, radii: CGSize)?) {
        scene.background.contents = background(size: size, shadow: shadow)
        scene.lightingEnvironment.contents = environment()
        scene.lightingEnvironment.intensity = 2.6

        let up = SIMD3<Float>(0, -1, 0)

        func light(_ type: SCNLight.LightType, intensity: CGFloat, color: NSColor, from dir: SIMD3<Float>, shadows: Bool) {
            let node = SCNNode()
            let l = SCNLight()
            l.type = type
            l.intensity = intensity
            l.color = color
            if shadows {
                l.castsShadow = true
                l.shadowMode = .deferred
                l.shadowRadius = 18
                l.shadowSampleCount = 24
                l.shadowMapSize = CGSize(width: 4096, height: 4096)
                l.shadowColor = NSColor(white: 0, alpha: 0.45)
                l.orthographicScale = CGFloat(radius * 5)
                l.zNear = 0.1
                l.zFar = CGFloat(radius * 12)
                l.automaticallyAdjustsShadowProjection = false
            }
            node.light = l
            node.simdPosition = center + simd_normalize(dir) * radius * 5
            node.simdLook(at: center, up: up, localFront: SIMD3(0, 0, -1))
            scene.rootNode.addChildNode(node)
        }
        // key light from upper left front, a cooler fill from the right, a warm rim from behind
        light(.directional, intensity: 1300, color: NSColor(srgbRed: 1, green: 0.97, blue: 0.92, alpha: 1),
              from: SIMD3(0.5, 0, -1) + up * 1.6, shadows: true)
        light(.directional, intensity: 250, color: NSColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: 1),
              from: SIMD3(-1, 0, -0.1) + up * 0.3, shadows: false)
        light(.directional, intensity: 900, color: NSColor(srgbRed: 1, green: 0.82, blue: 0.6, alpha: 1),
              from: SIMD3(-0.6, 0, 1) + up * 1.0, shadows: false)
        // small bright light high above the front, for crisp highlights on the rounded edges
        light(.directional, intensity: 600, color: NSColor(calibratedWhite: 1, alpha: 1),
              from: SIMD3(1, 0, 0.6) + up * 2.2, shadows: false)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 40
        scene.rootNode.addChildNode(ambient)

        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.2
        camera.bloomIntensity = 0.08
        camera.bloomThreshold = 1.0
        camera.bloomBlurRadius = 10
        camera.vignettingIntensity = 0.9
        camera.vignettingPower = 1.2
        camera.screenSpaceAmbientOcclusionIntensity = 0.8
        camera.screenSpaceAmbientOcclusionRadius = CGFloat(radius * 0.08)
        camera.saturation = 1.08
        camera.contrast = 0.15
    }
}
