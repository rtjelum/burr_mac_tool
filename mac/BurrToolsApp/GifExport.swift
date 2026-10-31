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

    var size = 800                 // pixels, square
    var framesPerMove = 4          // 1 = one frame per move, like burr2gif
    var moveTime = 0.6             // seconds per move
    var startPause = 1.0           // seconds showing the assembled puzzle
    var endPause = 2.0             // seconds on the last frame
    var elevation = 30.0           // camera height in degrees
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

/// Renders a solution's disassembly with SceneKit and writes it as an animated GIF.
final class GifRenderer {
    private let model: SolutionScene
    private let options: GifOptions

    /// Must be created on the main thread (it reads the puzzle).
    init(document: PuzzleDocument, problem: Int, solution: Int, options: GifOptions) {
        self.options = options
        model = SolutionScene(document: document, problem: problem, solution: solution, colors: options.colors)
    }

    var steps: Int { model.steps }

    // MARK: frame plan

    /// Camera azimuths (degrees) that show each kind of move best, as in burr2gif:
    /// sideways moves are seen from the front, front/back moves from the side.
    private enum MoveAxis { case x, z, mixed, vertical }

    private func azimuth(for axis: MoveAxis) -> Double? {
        switch axis {
        case .x: return 75
        case .z: return 15
        case .mixed: return 45
        case .vertical: return nil   // any angle shows up/down moves; keep the current one
        }
    }

    private func moveAxis(from a: Int, to b: Int) -> MoveAxis? {
        let s0 = model.pieceStates(step: Double(a))
        let s1 = model.pieceStates(step: Double(b))
        var d = SIMD3<Float>(repeating: 0)
        for (p0, p1) in zip(s0, s1) {
            guard let p0, let p1, p0.alpha > 0.01 || p1.alpha > 0.01 else { continue }
            d += simd_abs(p1.position - p0.position)
        }
        if d.x + d.y + d.z < 0.001 { return nil }
        if d.x < 0.001 && d.z < 0.001 { return .vertical }
        if d.x > d.z * 1.5 { return .x }
        if d.z > d.x * 1.5 { return .z }
        return .mixed
    }

    private func planFrames() -> [GifFrame] {
        let k = max(1, options.framesPerMove)
        let frameDelay = options.moveTime / Double(k)
        let turnFrames = 4
        var frames: [GifFrame] = []
        var az = 45.0

        // pick the starting angle from the first move, so the GIF does not open with a turn
        if options.camera == .follow, steps > 0,
           let axis = moveAxis(from: 0, to: 1), let a = azimuth(for: axis) {
            az = a
        }
        frames.append(GifFrame(step: 0, azimuth: az, delay: max(frameDelay, options.startPause)))

        for move in 0..<steps {
            if options.camera == .follow, let axis = moveAxis(from: move, to: move + 1),
               let target = azimuth(for: axis), abs(target - az) > 1 {
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
                frames[i].azimuth = 45 + 360 * Double(i) / Double(frames.count)
            }
        }
        frames[frames.count - 1].delay = max(frames[frames.count - 1].delay, options.endPause)
        return frames
    }

    private func hasVisiblePieces(at step: Double) -> Bool {
        model.pieceStates(step: step).contains { ($0?.alpha ?? 0) > 0.99 }
    }

    // MARK: rendering

    /// Bounding sphere around everything visible during the animation,
    /// so the camera can show all of it from any angle.
    private func animationBounds(_ frames: [GifFrame]) -> (center: SIMD3<Float>, radius: Float) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        // only whole moves: between them, removed pieces fly far out while fading,
        // and following them would make the puzzle tiny
        let sampled = Set(frames.map { $0.step.rounded(.down) })
        for step in sampled {
            model.update(step: step)
            for node in model.nodes {
                guard let node, !node.isHidden, node.opacity > 0.99 else { continue }
                let (mn, mx) = node.boundingBox
                lo = simd_min(lo, node.simdPosition + SIMD3(Float(mn.x), Float(mn.y), Float(mn.z)))
                hi = simd_max(hi, node.simdPosition + SIMD3(Float(mx.x), Float(mx.y), Float(mx.z)))
            }
        }
        if lo.x > hi.x { return (.zero, 1) }
        return ((lo + hi) / 2, max(simd_length(hi - lo) / 2, 0.5))
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

    /// Renders all frames and writes the GIF. `progress` gets values 0...1 and
    /// returns false to cancel. Runs on the calling (background) thread.
    func write(to url: URL, progress: (Double) -> Bool) throws {
        let frames = planFrames()
        let (center, radius) = animationBounds(frames)

        let scene = model.scene
        scene.background.contents = backgroundImage(size: options.size)
        let camera = model.camera
        let fov = 30.0
        camera.camera?.fieldOfView = fov
        let distance = radius / Float(sin(fov / 2 * .pi / 180)) * 1.08
        camera.camera?.zNear = Double(max(0.01, distance - radius * 1.5))
        camera.camera?.zFar = Double(distance + radius * 1.5)

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw BurrError(message: "Could not create the GIF file.")
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        let elevation = options.elevation * .pi / 180
        let size = CGSize(width: options.size, height: options.size)
        for (i, frame) in frames.enumerated() {
            if !progress(Double(i) / Double(frames.count)) { throw CancellationError() }

            model.update(step: frame.step)
            let az = frame.azimuth * .pi / 180
            let dir = SIMD3<Float>(Float(cos(az) * cos(elevation)), Float(sin(elevation)), Float(sin(az) * cos(elevation)))
            camera.simdPosition = center + dir * distance
            camera.simdLook(at: center)

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
