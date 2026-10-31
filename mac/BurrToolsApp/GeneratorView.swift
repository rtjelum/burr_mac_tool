import AppKit
import BurrCore
import SceneKit
import SwiftUI

/// Runs the puzzle generator in the background and publishes its progress.
final class GeneratorModel: ObservableObject {
    @Published private(set) var status = BTGeneratorStatus()
    @Published private(set) var running = false
    @Published private(set) var seconds = 0
    @Published private(set) var preview: SCNScene?
    @Published var error: String?

    private var handle: OpaquePointer?
    private var timer: Timer?
    private var started = Date()
    private var previewKey = ""
    private var size = (x: 0, y: 0, z: 0)

    deinit {
        timer?.invalidate()
        bt_generator_free(handle)
    }

    func start(document: PuzzleDocument, shape: Int, pieces: Int, target: Int, totalMoves: Bool,
               unique: Bool, minSize: Int) {
        stop()
        bt_generator_free(handle)
        handle = nil
        preview = nil
        previewKey = ""
        error = nil
        let info = document.shape(shape)
        size = info.size
        var err: UnsafeMutablePointer<CChar>?
        guard let h = bt_generator_start(document.puzzle, Int32(shape), Int32(pieces), Int32(target),
                                         totalMoves ? 1 : 0, unique ? 1 : 0, Int32(minSize), 0, &err) else {
            error = takeString(err) ?? "Could not start the generator."
            return
        }
        handle = h
        running = true
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stop() {
        if let handle { bt_generator_stop(handle) }
    }

    private func poll() {
        guard let handle else { return }
        var s = BTGeneratorStatus()
        bt_generator_status(handle, &s)
        status = s
        seconds = Int(Date().timeIntervalSince(started))
        if let e = takeString(bt_generator_error(handle)) { error = e }
        if s.haveBest != 0 {
            let key = "\(s.bestLevel)-\(s.bestMoves)"
            if key != previewKey {
                previewKey = key
                updatePreview()
            }
        }
        if s.running == 0 {
            running = false
            timer?.invalidate()
            timer = nil
            updatePreview()
        }
    }

    /// The best design so far, as coloured cubes in their assembled places.
    private func updatePreview() {
        guard let handle else { return }
        let count = size.x * size.y * size.z
        var owner = [Int32](repeating: -1, count: count)
        guard bt_generator_best(handle, &owner, Int32(count)) != 0 else { return }

        let root = SCNNode()
        var materials: [Int32: SCNMaterial] = [:]
        let box = SCNBox(width: 0.96, height: 0.96, length: 0.96, chamferRadius: 0.08)
        for z in 0..<size.z {
            for y in 0..<size.y {
                for x in 0..<size.x {
                    let piece = owner[x + size.x * (y + size.y * z)]
                    guard piece >= 0 else { continue }
                    let mat = materials[piece] ?? {
                        let c = PieceColorStyle.toyPalette[Int(piece) % PieceColorStyle.toyPalette.count]
                        let m = SCNMaterial()
                        m.diffuse.contents = NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
                        m.lightingModel = .blinn
                        m.specular.contents = NSColor(white: 0.3, alpha: 1)
                        materials[piece] = m
                        return m
                    }()
                    let g = box.copy() as! SCNBox
                    g.materials = [mat]
                    let n = SCNNode(geometry: g)
                    n.position = SCNVector3(Float(x) - Float(size.x) / 2 + 0.5,
                                            Float(y) - Float(size.y) / 2 + 0.5,
                                            Float(z) - Float(size.z) / 2 + 0.5)
                    root.addChildNode(n)
                }
            }
        }
        preview = makeScene(content: root).0
    }

    /// Adds the best design to the document; returns the new problem's index.
    func addBest(to document: PuzzleDocument, resultShape: Int, undo: UndoManager?) -> Int? {
        guard let handle else { return nil }
        var problem = -1
        document.edit("Add Generated Puzzle", undo: undo) { p in
            problem = Int(bt_generator_add_best(handle, p, Int32(resultShape)))
        }
        return problem >= 0 ? problem : nil
    }

    /// Stops the search and waits for its thread to end.
    func shutdown() {
        timer?.invalidate()
        timer = nil
        bt_generator_free(handle)
        handle = nil
        running = false
    }
}

/// Dialog: give a result shape, number of pieces and minimum moves; it searches
/// for a puzzle with a unique solution that needs at least that many moves.
struct GeneratorView: View {
    @ObservedObject var document: PuzzleDocument
    var onAdded: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undo
    @StateObject private var model = GeneratorModel()
    @StateObject private var shape = ViewState<Int>(-1)
    @StateObject private var pieces = ViewState<Int>(5)
    @StateObject private var target = ViewState<Int>(3)
    @StateObject private var totalMoves = ViewState<Bool>(false)
    @StateObject private var unique = ViewState<Bool>(true)
    @StateObject private var minSize = ViewState<Int>(3)

    var body: some View {
        let shapes = document.shapes.filter { $0.voxels > 0 }
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Generate Puzzle").font(.title2.bold())
                Text("Splits a shape into pieces and searches for a design with one solution that needs at least the number of moves you ask for.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Form {
                    Picker("Final shape", selection: $shape.value) {
                        Text("Choose…").tag(-1)
                        ForEach(shapes) { Text("\($0.displayName) (\($0.voxels) cubes)").tag($0.id) }
                    }
                    Stepper(value: $pieces.value, in: 2...16) {
                        LabeledContent("Pieces", value: "\(pieces.value)")
                    }
                    Stepper(value: $target.value, in: 1...200) {
                        LabeledContent("At least", value: "\(target.value) moves")
                    }
                    Picker("Count moves", selection: $totalMoves.value) {
                        Text("until the first piece comes out (level)").tag(false)
                        Text("to take it completely apart").tag(true)
                    }
                    Toggle("Only one solution", isOn: $unique.value)
                    Stepper(value: $minSize.value, in: 1...20) {
                        LabeledContent("Smallest piece", value: "\(minSize.value) cubes")
                    }
                }
                .formStyle(.grouped)
                .disabled(model.running)

                if let warning = solidWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                statusView

                if let e = model.error {
                    Text(e).foregroundStyle(.red).font(.callout)
                }

                Spacer(minLength: 0)
                HStack {
                    Button("Close") {
                        model.stop()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    if model.running {
                        Button("Stop") { model.stop() }
                    } else {
                        Button(model.status.haveBest != 0 ? "Search Again" : "Start") { start() }
                            .disabled(shape.value < 0 || document.isSolving)
                    }
                    Button("Add to Puzzle") { add() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.status.haveBest == 0)
                }
            }
            .padding(20)
            .frame(width: 440)

            Divider()

            ZStack {
                if let scene = model.preview {
                    SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                } else {
                    Text(model.running ? "Searching…" : "The best design found shows here.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 380)
        }
        .frame(height: 620)
        .onAppear {
            if shape.value < 0 {
                // default: the result shape of the first problem, else the largest shape
                shape.value = document.problems.compactMap { document.problemResult($0.id) }.first
                    ?? shapes.max(by: { $0.voxels < $1.voxels })?.id ?? -1
            }
        }
    }

    @ViewBuilder private var statusView: some View {
        let s = model.status
        if model.running || s.tried > 0 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if model.running { ProgressView().controlSize(.small) }
                    Text(model.running ? "Searching… \(formatTime(model.seconds))"
                         : (s.found != 0 ? "Found a design that reaches the target." : "Stopped after \(formatTime(model.seconds))."))
                }
                Text("\(s.tried) designs checked, \(s.valid) with \(unique.value ? "one solution" : "a solution")")
                    .foregroundStyle(.secondary)
                if s.haveBest != 0 {
                    Text("Best: level \(s.bestLevel), \(s.bestMoves) moves in total")
                        .fontWeight(.medium)
                }
            }
            .font(.callout)
            .monospacedDigit()
        }
    }

    /// A shape with no empty space inside its bounding box only gives level-1 puzzles.
    private var solidWarning: String? {
        guard shape.value >= 0, !totalMoves.value, target.value > 1, document.gridType == .bricks else { return nil }
        let info = document.shape(shape.value)
        var filled = 0, variable = 0
        for z in 0..<info.size.z { for y in 0..<info.size.y { for x in 0..<info.size.x {
            let v = document.voxel(shape.value, x, y, z)
            if v == BT_VOXEL_FILLED { filled += 1 } else if v == BT_VOXEL_VARIABLE { variable += 1 }
        } } }
        // empty cells inside the bounding box give pieces room to move
        let box = info.size.x * info.size.y * info.size.z
        if variable == 0 && filled == box {
            return "A solid box can only give level-1 puzzles: there is no room inside for pieces to move. Make the inside variable (Fill → Make Inside Variable) or use a shape with gaps."
        }
        return nil
    }

    private func start() {
        model.start(document: document, shape: shape.value, pieces: pieces.value, target: target.value,
                    totalMoves: totalMoves.value, unique: unique.value, minSize: minSize.value)
    }

    private func add() {
        model.stop()
        guard let problem = model.addBest(to: document, resultShape: shape.value, undo: undo) else { return }
        model.shutdown()
        onAdded(problem)
        // solve it straight away so the solution and its animation are ready
        var options = SolveOptions()
        options.disassemble = document.canDisassemble
        document.startSolving(problem: problem, options: options, fromStart: true, undo: undo)
        dismiss()
    }

    private func formatTime(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
