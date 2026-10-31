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
               unique: Bool, minSize: Int, holes: Int, fixed: [Int], startProblem: Int?, compact: Bool) {
        stop()
        bt_generator_free(handle)
        handle = nil
        preview = nil
        previewKey = ""
        error = nil
        let info = document.shape(shape)
        size = info.size
        var err: UnsafeMutablePointer<CChar>?
        let fixedIds = fixed.map { Int32($0) }
        guard let h = fixedIds.withUnsafeBufferPointer({ buf in
            bt_generator_start(document.puzzle, Int32(shape), Int32(pieces), Int32(target),
                               totalMoves ? 1 : 0, unique ? 1 : 0, Int32(minSize), Int32(holes),
                               buf.baseAddress, Int32(buf.count), Int32(startProblem ?? -1), compact ? 1 : 0, 0, &err)
        }) else {
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
            let key = "\(s.bestVersion)"
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
    @StateObject private var compact = ViewState<Bool>(true)
    @StateObject private var holes = ViewState<Int>(0)
    @StateObject private var fixed = ViewState<Set<Int>>([])
    @StateObject private var startProblem = ViewState<Int>(-1)

    var body: some View {
        let shapes = document.shapes.filter { $0.voxels > 0 }
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Generate Puzzle").font(.title2.bold())
                Text("Splits a shape into pieces and searches for a design with one solution that needs at least the number of moves you ask for.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Form {
                    Picker("Final shape", selection: Binding(get: { shape.value }, set: { shape.value = $0; applyDefaults() })) {
                        Text("Choose…").tag(-1)
                        ForEach(shapes) { Text("\($0.displayName) (\($0.voxels) cubes)").tag($0.id) }
                    }
                    if counts.variable > 0 && startProblem.value < 0 {
                        Stepper(value: $holes.value, in: 0...counts.variable) {
                            LabeledContent("Empty cubes", value: "\(holes.value) of \(counts.variable) variable")
                        }
                        .help("How many of the shape's variable cubes stay empty. Empty space inside lets pieces move, which allows higher levels.")
                        Text("The pieces fill \(counts.filled + counts.variable - holes.value) of the shape's \(counts.filled + counts.variable) cubes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !startDesigns.isEmpty {
                        Picker("Start from", selection: $startProblem.value) {
                            Text("A random split").tag(-1)
                            ForEach(startDesigns) { Text("The pieces of \($0.displayName)").tag($0.id) }
                        }
                        .help("Start from an existing design and reshape its pieces step by step. Works much better than random splits for tight designs such as boxes.")
                    }
                    Stepper(value: $pieces.value, in: (fixed.value.isEmpty ? 2 : 1)...16) {
                        LabeledContent(fixed.value.isEmpty ? "Pieces" : "New pieces", value: "\(pieces.value)")
                    }
                    .disabled(startProblem.value >= 0)
                    startingPieces(shapes)
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
                    Toggle("Compact pieces", isOn: $compact.value)
                        .help("After reaching the target, keep reshaping the pieces towards solid blocks, with fewer thin arms and gaps, without losing moves.")
                }
                .formStyle(.grouped)
                .disabled(model.running)

                if startProblem.value >= 0 {
                    Text("The number of pieces and empty cubes come from that design. Tick its cage or box under Starting pieces to keep it unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let warning = solidWarning, startProblem.value < 0 {
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
                applyDefaults()
            }
        }
    }

    /// Solved problems with the chosen final shape; their pieces can be the start.
    private var startDesigns: [ProblemInfo] {
        document.problems.filter {
            document.problemResult($0.id) == shape.value
                && bt_problem_saved_solution_count(document.puzzle, Int32($0.id)) > 0
        }
    }

    /// Shapes to keep as they are (e.g. a cage); the new pieces fill the rest.
    @ViewBuilder private func startingPieces(_ shapes: [ShapeInfo]) -> some View {
        let candidates = shapes.filter { $0.id != shape.value }
        if !candidates.isEmpty {
            DisclosureGroup("Starting pieces (\(fixed.value.count))") {
                ForEach(candidates) { s in
                    Toggle(isOn: Binding(get: { fixed.value.contains(s.id) },
                                         set: { on in
                                             if on { fixed.value.insert(s.id) } else { fixed.value.remove(s.id) }
                                             if !fixed.value.isEmpty { pieces.value = max(1, pieces.value) }
                                         })) {
                        HStack {
                            ColorSwatch(shape: s.id)
                            Text("\(s.displayName) (\(s.voxels) cubes)")
                        }
                    }
                }
                Text("Kept as they are, e.g. a cage or box; the new pieces fill the space that is left. Each is placed where it is drawn, or the nearest place it fits in the same orientation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var statusView: some View {
        let s = model.status
        if model.running || s.tried > 0 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if model.running { ProgressView().controlSize(.small) }
                    Text(model.running ? (s.polishing != 0 ? "Target reached; making the pieces more compact… \(formatTime(model.seconds))" : "Searching… \(formatTime(model.seconds))")
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

    /// Fixed and variable cubes of the chosen shape, and its bounding box volume.
    private var counts: (filled: Int, variable: Int, box: Int) {
        guard shape.value >= 0, shape.value < document.shapes.count else { return (0, 0, 0) }
        let info = document.shape(shape.value)
        var filled = 0, variable = 0
        for z in 0..<info.size.z { for y in 0..<info.size.y { for x in 0..<info.size.x {
            let v = document.voxel(shape.value, x, y, z)
            if v == BT_VOXEL_FILLED { filled += 1 } else if v == BT_VOXEL_VARIABLE { variable += 1 }
        } } }
        return (filled, variable, info.size.x * info.size.y * info.size.z)
    }

    /// When a problem already uses this shape as its result, start from its
    /// number of pieces and the empty space its pieces leave.
    private func applyDefaults() {
        fixed.value.remove(shape.value)
        startProblem.value = -1
        let c = counts
        holes.value = 0
        guard c.variable > 0 else { return }
        holes.value = min(c.variable, max(0, Int((Double(c.variable) * 0.15).rounded())))
        for problem in document.problems where document.problemResult(problem.id) == shape.value {
            var volume = 0, count = 0
            for s in document.shapes where s.id != shape.value {
                let n = document.problemShapeCount(problem.id, s.id).max
                volume += n * s.voxels
                count += n
            }
            if count >= 2 && volume > 0 && volume <= c.filled + c.variable {
                pieces.value = min(16, count)
                holes.value = min(c.variable, c.filled + c.variable - volume)
                return
            }
        }
    }

    /// A shape with no empty space inside its bounding box only gives level-1 puzzles.
    private var solidWarning: String? {
        guard shape.value >= 0, !totalMoves.value, target.value > 1, document.gridType == .bricks else { return nil }
        let c = counts
        // empty cubes inside the bounding box give pieces room to move
        if c.filled + c.variable == c.box && holes.value == 0 {
            return c.variable > 0
                ? "With no empty cubes the shape is a solid box, which only gives level-1 puzzles. Leave some variable cubes empty."
                : "A solid box can only give level-1 puzzles: there is no room inside for pieces to move. Make the inside variable (Fill → Make Inside Variable) or use a shape with gaps."
        }
        return nil
    }

    private func start() {
        model.start(document: document, shape: shape.value, pieces: pieces.value, target: target.value,
                    totalMoves: totalMoves.value, unique: unique.value, minSize: minSize.value, holes: holes.value,
                    fixed: fixed.value.sorted(), startProblem: startProblem.value >= 0 ? startProblem.value : nil,
                    compact: compact.value)
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
