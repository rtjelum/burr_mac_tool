import AppKit
import ImageIO
import Metal
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings for exporting a disassembly animation as an animated GIF.
struct GifOptions {
    enum Camera: String, CaseIterable, Identifiable {
        case follow = "Turn to follow each move"
        case fixed = "Fixed"
        case orbit = "Slowly orbit"
        var id: String { rawValue }
    }

    enum Background: String, CaseIterable, Identifiable {
        case dark = "Dark gradient"
        case light = "Light"
        case white = "White"
        var id: String { rawValue }
    }

    // defaults match scripts/burr2gif.py
    var size = 1024                // pixels, square
    var framesPerMove = 1          // 1 = one frame per move, like burr2gif
    var moveTime = 0.2             // seconds per move
    var startPause = 0.2           // seconds showing the assembled puzzle
    var endPause = 0.2             // seconds on the last frame
    var elevation = 35.0           // camera height in degrees (matplotlib elev)
    var camera = Camera.follow
    var colors = PieceColorStyle.vibrant
    var background = Background.dark
}

/// One rendered frame: the animation step, the camera direction, and how long it shows.
private struct GifFrame {
    var step: Double
    var azimuth: Double
    var delay: Double
}

/// Renders a solution's disassembly and writes it as an animated GIF, in the
/// style of scripts/burr2gif.py (matplotlib voxels): flat colours shaded by a
/// fixed light, a thin dark line around every cube face, and no faces where
/// cubes touch.
///
/// Coordinates: burr2gif draws with matplotlib axes X = x, Y = z, up = -y of the
/// puzzle. The camera and the light below use the same mapping, so angles match.
final class GifRenderer {
    private let model: SolutionScene
    private let options: GifOptions
    private let cubeGrid: Bool
    private var voxels: [[SIMD3<Float>]] = []
    private var triangles: [[(a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>, normal: SIMD3<Float>)]] = []

    /// Must be created on the main thread (it reads the puzzle).
    init(document: PuzzleDocument, problem: Int, solution: Int, options: GifOptions) {
        self.options = options
        model = SolutionScene(document: document, problem: problem, solution: solution, colors: options.colors)
        cubeGrid = document.gridType == .bricks
        for i in model.nodes.indices {
            if cubeGrid {
                voxels.append(model.nodes[i] == nil ? [] : model.pieceVoxels(i))
            } else {
                triangles.append(model.nodes[i] == nil ? [] : model.pieceTriangles(i))
            }
        }
    }

    var steps: Int { model.steps }

    // MARK: matplotlib look

    /// matplotlib's default 3D light (LightSource azdeg=225, altdeg=19.47),
    /// converted from axes coordinates (X, Y, Z) to puzzle coordinates (x, -Z, Y).
    private static let light = SIMD3<Float>(-2.0 / 3, -1.0 / 3, -2.0 / 3)

    /// matplotlib's face shading: brightness 0.3 ... 1 depending on the light.
    private static func shade(_ normal: SIMD3<Float>) -> Float {
        let n = simd_normalize(normal)
        let d = simd_dot(n, light)
        return 0.3 + 0.7 * (d + 1) / 2
    }

    /// Camera direction for matplotlib's view_init(elev, azim), in puzzle coordinates.
    private func cameraDirection(azimuth: Double) -> SIMD3<Float> {
        let az = azimuth * .pi / 180, el = options.elevation * .pi / 180
        return SIMD3(Float(cos(el) * cos(az)), Float(-sin(el)), Float(cos(el) * sin(az)))
    }

    // MARK: frame plan (same rules as burr2gif)

    private func axisAzimuth(from a: Int, to b: Int) -> Double? {
        let s0 = model.pieceStates(step: Double(a))
        let s1 = model.pieceStates(step: Double(b))
        var d = SIMD3<Float>(repeating: 0)
        var moved = false
        for (p0, p1) in zip(s0, s1) {
            guard let p0, let p1, p0.alpha > 0.5, p1.alpha > 0.5 else { continue }
            let delta = p1.position - p0.position
            if simd_length(delta) > 0.001 { moved = true }
            d += delta
        }
        guard moved else { return nil }
        // burr2gif: sideways (x) moves from -75°, front/back (z) moves from -15°, otherwise -45°
        if abs(d.x) > abs(d.z) * 1.5 { return -75 }
        if abs(d.z) > abs(d.x) * 1.5 { return -15 }
        return -45
    }

    private func planFrames() -> [GifFrame] {
        let k = max(1, options.framesPerMove)
        let frameDelay = options.moveTime / Double(k)
        let turnFrames = 4
        var frames: [GifFrame] = []
        var az = -45.0

        frames.append(GifFrame(step: 0, azimuth: az, delay: max(frameDelay, options.startPause)))

        for move in 0..<steps {
            if options.camera == .follow, let target = axisAzimuth(from: move, to: move + 1), abs(target - az) > 0.5 {
                // turn the camera first while nothing moves
                for t in 1...turnFrames {
                    let a = az + (target - az) * Double(t) / Double(turnFrames)
                    frames.append(GifFrame(step: Double(move), azimuth: a, delay: frameDelay))
                }
                az = target
            }
            for t in 1...k {
                frames.append(GifFrame(step: Double(move) + Double(t) / Double(k), azimuth: az, delay: frameDelay))
            }
        }

        // the animation code fades out and hides everything during the last move;
        // end on the last frame that still shows solid pieces
        while frames.count > 1 && !hasVisiblePieces(at: frames[frames.count - 1].step) {
            frames.removeLast()
        }

        if options.camera == .orbit {
            for i in frames.indices {
                frames[i].azimuth = -45 + 360 * Double(i) / Double(frames.count)
            }
        }
        frames[frames.count - 1].delay = max(frames[frames.count - 1].delay, options.endPause)
        return frames
    }

    private func hasVisiblePieces(at step: Double) -> Bool {
        model.pieceStates(step: step).contains { ($0?.alpha ?? 0) > 0.99 }
    }

    // MARK: geometry

    private struct Scene {
        var faces: [SIMD3<Float>] = []       // 4 corners per quad, or 3 per triangle
        var faceColors: [SIMD4<Float>] = []
        var lines: [SIMD3<Float>] = []       // 2 points per segment
        var triangleFaces: [SIMD3<Float>] = []
        var triangleColors: [SIMD4<Float>] = []
    }

    /// Unit cube faces: outward normal and the 4 corners (offsets from the low corner).
    private static let cubeFaces: [(normal: SIMD3<Float>, corners: [SIMD3<Float>])] = [
        (SIMD3(-1, 0, 0), [SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 1), SIMD3(0, 1, 0)]),
        (SIMD3(1, 0, 0), [SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(1, 1, 1), SIMD3(1, 0, 1)]),
        (SIMD3(0, -1, 0), [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 1), SIMD3(0, 0, 1)]),
        (SIMD3(0, 1, 0), [SIMD3(0, 1, 0), SIMD3(0, 1, 1), SIMD3(1, 1, 1), SIMD3(1, 1, 0)]),
        (SIMD3(0, 0, -1), [SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(1, 0, 0)]),
        (SIMD3(0, 0, 1), [SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)]),
    ]

    private static func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3(Int32((p.x * 64).rounded()), Int32((p.y * 64).rounded()), Int32((p.z * 64).rounded()))
    }

    private func buildScene(step: Double) -> Scene {
        let states = model.pieceStates(step: step)
        var scene = Scene()

        if cubeGrid {
            // all visible cubes in world coordinates; faces between touching cubes are hidden
            var occupied = Set<SIMD3<Int32>>()
            var cubes: [(corner: SIMD3<Float>, color: (r: Float, g: Float, b: Float))] = []
            for (i, state) in states.enumerated() {
                guard let state, state.alpha > 0.5, let color = model.pieceColors[i] else { continue }
                for v in voxels[i] {
                    let corner = state.position + v
                    occupied.insert(Self.key(corner))
                    cubes.append((corner, color))
                }
            }
            let edgeLift: Float = 0.004   // keeps lines just in front of their face
            for cube in cubes {
                for face in Self.cubeFaces where !occupied.contains(Self.key(cube.corner + face.normal)) {
                    let b = Self.shade(face.normal)
                    let color = SIMD4(cube.color.r * b, cube.color.g * b, cube.color.b * b, 1)
                    let pts = face.corners.map { cube.corner + $0 }
                    scene.faces.append(contentsOf: pts)
                    scene.faceColors.append(contentsOf: Array(repeating: color, count: 4))
                    let lifted = pts.map { $0 + face.normal * edgeLift }
                    for e in 0..<4 {
                        scene.lines.append(lifted[e])
                        scene.lines.append(lifted[(e + 1) % 4])
                    }
                }
            }
        } else {
            for (i, state) in states.enumerated() {
                guard let state, state.alpha > 0.5, let color = model.pieceColors[i] else { continue }
                for t in triangles[i] {
                    let b = Self.shade(t.normal)
                    let c = SIMD4(color.r * b, color.g * b, color.b * b, 1)
                    scene.triangleFaces.append(contentsOf: [t.a + state.position, t.b + state.position, t.c + state.position])
                    scene.triangleColors.append(contentsOf: [c, c, c])
                }
            }
        }
        return scene
    }

    /// SceneKit treats vertex colours as linear; the palette is sRGB.
    private static func linear(_ c: SIMD4<Float>) -> SIMD4<Float> {
        func f(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return SIMD4(f(c.x), f(c.y), f(c.z), c.w)
    }

    private static func geometry(points: [SIMD3<Float>], colors: [SIMD4<Float>]?, indices: [Int32],
                                 primitive: SCNGeometryPrimitiveType) -> SCNGeometry {
        let vdata = points.withUnsafeBufferPointer { buf in
            Data(buffer: UnsafeBufferPointer(start: UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: Float.self),
                                             count: points.count * 4))
        }
        var sources = [SCNGeometrySource(data: vdata, semantic: .vertex, vectorCount: points.count,
                                         usesFloatComponents: true, componentsPerVector: 3,
                                         bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)]
        if let colors {
            let lin = colors.map(linear)
            let cdata = lin.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: cdata, semantic: .color, vectorCount: lin.count,
                                             usesFloatComponents: true, componentsPerVector: 4,
                                             bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride))
        }
        return SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: indices, primitiveType: primitive)])
    }

    private func node(for scene: Scene) -> SCNNode {
        let root = SCNNode()

        let flat = SCNMaterial()
        flat.lightingModel = .constant
        flat.diffuse.contents = NSColor.white
        flat.isDoubleSided = true

        if !scene.faces.isEmpty {
            var idx: [Int32] = []
            idx.reserveCapacity(scene.faces.count / 4 * 6)
            for q in stride(from: 0, to: scene.faces.count, by: 4) {
                let i = Int32(q)
                idx.append(contentsOf: [i, i + 1, i + 2, i, i + 2, i + 3])
            }
            let g = Self.geometry(points: scene.faces, colors: scene.faceColors, indices: idx, primitive: .triangles)
            g.materials = [flat]
            root.addChildNode(SCNNode(geometry: g))
        }
        if !scene.triangleFaces.isEmpty {
            let g = Self.geometry(points: scene.triangleFaces, colors: scene.triangleColors,
                                  indices: (0..<Int32(scene.triangleFaces.count)).map { $0 }, primitive: .triangles)
            g.materials = [flat]
            root.addChildNode(SCNNode(geometry: g))
        }
        if !scene.lines.isEmpty {
            // matplotlib edgecolors=(0.1, 0.1, 0.1, 0.8)
            let g = Self.geometry(points: scene.lines, colors: nil,
                                  indices: (0..<Int32(scene.lines.count)).map { $0 }, primitive: .line)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            m.transparency = 0.8
            m.blendMode = .alpha
            g.materials = [m]
            root.addChildNode(SCNNode(geometry: g))
        }
        return root
    }

    // MARK: rendering

    /// Box around everything shown at whole moves (burr2gif uses one fixed box too).
    private func animationBounds(_ frames: [GifFrame]) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for step in Set(frames.map { $0.step.rounded(.down) }) {
            let s = buildScene(step: step)
            for p in s.faces + s.triangleFaces {
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
        }
        if lo.x > hi.x { return (SIMD3(repeating: -1), SIMD3(repeating: 1)) }
        return (lo, hi)
    }

    private func backgroundImage(size: Int) -> Any {
        switch options.background {
        case .white: return NSColor.white
        case .light: return NSColor(calibratedWhite: 0.93, alpha: 1)
        case .dark:
            // vertical gradient like burr2gif: deep charcoal to near black
            let image = NSImage(size: NSSize(width: size, height: size))
            image.lockFocus()
            NSGradient(starting: NSColor(srgbRed: 15 / 255, green: 16 / 255, blue: 18 / 255, alpha: 1),
                       ending: NSColor(srgbRed: 40 / 255, green: 42 / 255, blue: 48 / 255, alpha: 1))?
                .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: 90)
            image.unlockFocus()
            return image
        }
    }

    /// Camera distance so the whole box fits for every frame's view direction.
    private func fitDistance(lo: SIMD3<Float>, hi: SIMD3<Float>, center: SIMD3<Float>, frames: [GifFrame], fov: Double) -> Float {
        let t = Float(tan(fov / 2 * .pi / 180))
        var corners: [SIMD3<Float>] = []
        for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z, hi.z] { corners.append(SIMD3(x, y, z) - center) } } }
        var d: Float = 0
        for az in Set(frames.map(\.azimuth)) {
            let back = cameraDirection(azimuth: az)               // from centre towards camera
            let right = simd_normalize(simd_cross(SIMD3<Float>(0, -1, 0), back))
            let up = simd_cross(back, right)
            for c in corners {
                let depth = simd_dot(c, back)
                d = max(d, depth + abs(simd_dot(c, right)) / t, depth + abs(simd_dot(c, up)) / t)
            }
        }
        return d * 1.06
    }

    /// Renders all frames and writes the GIF. `progress` gets values 0...1 and
    /// returns false to cancel. Runs on the calling (background) thread.
    func write(to url: URL, progress: (Double) -> Bool) throws {
        let frames = planFrames()
        let (lo, hi) = animationBounds(frames)
        let center = (lo + hi) / 2
        let fov = 20.0
        let distance = fitDistance(lo: lo, hi: hi, center: center, frames: frames, fov: fov)

        let scene = SCNScene()
        scene.background.contents = backgroundImage(size: options.size)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera!.fieldOfView = fov
        camera.camera!.zNear = Double(max(0.01, distance - simd_length(hi - lo)))
        camera.camera!.zFar = Double(distance + simd_length(hi - lo))
        scene.rootNode.addChildNode(camera)

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw BurrError(message: "Could not create the GIF file.")
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        let size = CGSize(width: options.size, height: options.size)
        var content: SCNNode?
        for (i, frame) in frames.enumerated() {
            if !progress(Double(i) / Double(frames.count)) { throw CancellationError() }

            content?.removeFromParentNode()
            let n = node(for: buildScene(step: frame.step))
            scene.rootNode.addChildNode(n)
            content = n

            camera.simdPosition = center + cameraDirection(azimuth: frame.azimuth) * distance
            camera.simdLook(at: center, up: SIMD3(0, -1, 0), localFront: SIMD3(0, 0, -1))

            let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            // GIF delays are in 1/100 s
            let delay = (frame.delay * 100).rounded() / 100
            CGImageDestinationAddImage(dest, cg, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        _ = progress(1)
        guard CGImageDestinationFinalize(dest) else {
            throw BurrError(message: "Could not write the GIF file.")
        }
    }

    /// Number of frames the current options produce (for the dialog).
    var frameCount: Int { planFrames().count }
}

/// Dialog for exporting a GIF of the disassembly.
struct GifExportView: View {
    let document: PuzzleDocument
    let problem: Int
    let solution: Int
    let steps: Int

    @Environment(\.dismiss) private var dismiss
    @StateObject private var options = ViewState(GifOptions())
    @StateObject private var progress = ViewState<Double?>(nil)
    @StateObject private var cancelled = CancelFlag()
    @StateObject private var message = ViewState<String?>(nil)

    final class CancelFlag: ObservableObject {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export GIF").font(.title2.bold())
            Text("Saves the disassembly of this solution (\(steps) moves) as an animated GIF.")
                .foregroundStyle(.secondary)

            Form {
                Picker("Size", selection: $options.value.size) {
                    Text("512 × 512").tag(512)
                    Text("800 × 800").tag(800)
                    Text("1024 × 1024").tag(1024)
                }
                Picker("Camera", selection: $options.value.camera) {
                    ForEach(GifOptions.Camera.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Colours", selection: $options.value.colors) {
                    ForEach(PieceColorStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Background", selection: $options.value.background) {
                    ForEach(GifOptions.Background.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Smoothness", selection: $options.value.framesPerMove) {
                    Text("1 frame per move (like burr2gif)").tag(1)
                    Text("4 frames per move").tag(4)
                    Text("8 frames per move (smooth, larger file)").tag(8)
                }
                LabeledContent("Time per move") {
                    secondsField($options.value.moveTime)
                }
                LabeledContent("Pause at start / end") {
                    HStack {
                        secondsField($options.value.startPause)
                        secondsField($options.value.endPause)
                    }
                }
                LabeledContent("Camera height") {
                    HStack {
                        Slider(value: $options.value.elevation, in: 5...80)
                        Text("\(Int(options.value.elevation))°").monospacedDigit().frame(width: 36)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(progress.value != nil)

            if let p = progress.value {
                ProgressView(value: p) { Text("Rendering… \(Int(p * 100)) %") }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    if progress.value != nil { cancelled.set(true) } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Save GIF…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(progress.value != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .alert("Export GIF", isPresented: Binding(get: { message.value != nil }, set: { if !$0 { message.value = nil } })) {
            Button("OK") { message.value = nil }
        } message: {
            Text(message.value ?? "")
        }
    }

    private func secondsField(_ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
            Text("s").foregroundStyle(.secondary)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "solution \(solution + 1).gif"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var opts = options.value
        opts.moveTime = max(0.02, opts.moveTime)
        opts.startPause = max(0, opts.startPause)
        opts.endPause = max(0, opts.endPause)
        let renderer = GifRenderer(document: document, problem: problem, solution: solution, options: opts)
        cancelled.set(false)
        progress.value = 0
        let flag = cancelled

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try renderer.write(to: url) { p in
                    DispatchQueue.main.async { if progress.value != nil { progress.value = p } }
                    return !flag.isSet
                }
                DispatchQueue.main.async {
                    progress.value = nil
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    dismiss()
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async { progress.value = nil }
            } catch {
                DispatchQueue.main.async {
                    progress.value = nil
                    message.value = error.localizedDescription
                }
            }
        }
    }
}
