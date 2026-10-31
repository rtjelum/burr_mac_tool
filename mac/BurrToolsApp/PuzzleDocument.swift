import BurrCore
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let xmpuzzle = UTType(importedAs: "net.sourceforge.burrtools.xmpuzzle")
}

struct SolveOptions {
    var disassemble = true
    var reduce = true
    var keepMirrors = false
    var keepRotations = false
    var completeRotations = false
    var justCount = false
    var dropDisassemblies = false
    var sort = 0
    var limit = 0

    var flags: Int32 {
        var f = 0
        if reduce { f |= BT_SOLVE_REDUCE }
        if disassemble { f |= BT_SOLVE_DISASSEMBLE }
        if keepMirrors { f |= BT_SOLVE_KEEP_MIRROR }
        if keepRotations { f |= BT_SOLVE_KEEP_ROTATIONS }
        if completeRotations { f |= BT_SOLVE_COMPLETE_ROTATIONS }
        if justCount { f |= BT_SOLVE_JUST_COUNT }
        if dropDisassemblies { f |= BT_SOLVE_DROP_DISASSEMBLIES }
        return Int32(f)
    }
}

struct SolverStatus {
    var problem: Int
    var action = 0
    var actionParameter = 0
    var assemblies = -1
    var solutions = -1
    var seconds = -1
    var progress = -1.0

    var actionText: String {
        switch action {
        case BT_ACT_PREPARATION: return "Preparing piece \(actionParameter + 1)"
        case BT_ACT_REDUCE: return "Optimising piece \(actionParameter + 1)"
        case BT_ACT_ASSEMBLING: return "Assembling"
        case BT_ACT_DISASSEMBLING: return "Disassembling"
        case BT_ACT_PAUSING: return "Paused"
        case BT_ACT_FINISHED: return "Finished"
        case BT_ACT_WAIT_TO_STOP: return "Stopping…"
        case BT_ACT_ERROR, BT_ACT_ASSERT: return "Error"
        default: return ""
        }
    }
}

/// A BurrTools puzzle file (.xmpuzzle), backed by the C++ puzzle object.
///
/// Every change goes through `edit`, which saves a copy of the puzzle first so
/// the change can be undone. While the solver runs, the puzzle is read-only.
final class PuzzleDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    static var readableContentTypes: [UTType] { [.xmpuzzle] }

    /// Changes whenever the puzzle changes; views use it to refresh.
    @Published private(set) var revision = 0
    @Published private(set) var solver: SolverStatus?
    @Published var lastError: String?

    private(set) var puzzle: OpaquePointer
    private var solverHandle: OpaquePointer?
    private var solverTimer: Timer?
    private var solveUndo: (data: Data, undo: UndoManager?)?

    init(gridType: GridType = .bricks) {
        puzzle = bt_puzzle_new(Int32(gridType.rawValue))
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        puzzle = try Self.load(data)
    }

    deinit {
        solverTimer?.invalidate()
        bt_solver_free(solverHandle)
        bt_puzzle_free(puzzle)
    }

    // MARK: file I/O

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("burrtools-\(UUID().uuidString).xmpuzzle")
    }

    private static func load(_ data: Data) throws -> OpaquePointer {
        let url = tempURL()
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var err: UnsafeMutablePointer<CChar>?
        guard let p = bt_puzzle_load(url.path, &err) else {
            throw BurrError(message: "Could not open puzzle: " + (takeString(err) ?? "unknown error"))
        }
        return p
    }

    private func serialize() throws -> Data {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var err: UnsafeMutablePointer<CChar>?
        guard bt_puzzle_save(puzzle, url.path, &err) != 0 else {
            throw BurrError(message: "Could not save puzzle: " + (takeString(err) ?? "unknown error"))
        }
        return try Data(contentsOf: url)
    }

    func snapshot(contentType: UTType) throws -> Data {
        // Saving pauses the solver; the saved file keeps its state so it can continue later.
        stopSolverAndWait()
        return try serialize()
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }

    // MARK: editing with undo

    var isSolving: Bool { solver != nil }

    /// Applies `change` to the puzzle and registers an undo step.
    func edit(_ name: String, undo: UndoManager?, _ change: (OpaquePointer) -> Void) {
        guard !isSolving else { return }
        guard let before = try? serialize() else {
            change(puzzle)
            revision += 1
            return
        }
        change(puzzle)
        registerUndo(name, before: before, undo: undo)
        revision += 1
    }

    /// For changes made in many small steps (like painting voxels): call
    /// `beginEdit` first, change the puzzle with `liveChange`, then `commitEdit`.
    func beginEdit() -> Data? { isSolving ? nil : try? serialize() }

    func liveChange(_ change: (OpaquePointer) -> Void) {
        guard !isSolving else { return }
        change(puzzle)
        revision += 1
    }

    func commitEdit(_ name: String, before: Data?, undo: UndoManager?) {
        guard let before else { return }
        registerUndo(name, before: before, undo: undo)
    }

    private func registerUndo(_ name: String, before: Data, undo: UndoManager?) {
        guard let undo else { return }
        undo.registerUndo(withTarget: self) { doc in
            doc.restore(before, name: name, undo: undo)
        }
        undo.setActionName(name)
    }

    private func restore(_ data: Data, name: String, undo: UndoManager) {
        stopSolverAndWait()
        guard let current = try? serialize(), let restored = try? Self.load(data) else { return }
        let old = puzzle
        puzzle = restored
        bt_puzzle_free(old)
        // register the opposite step, so undo becomes redo and vice versa
        undo.registerUndo(withTarget: self) { doc in
            doc.restore(current, name: name, undo: undo)
        }
        undo.setActionName(name)
        revision += 1
    }

    /// Replaces the whole puzzle with an empty one of another grid type.
    func changeGridType(_ type: GridType, undo: UndoManager?) {
        guard !isSolving, let before = try? serialize() else { return }
        let old = puzzle
        puzzle = bt_puzzle_new(Int32(type.rawValue))
        bt_puzzle_free(old)
        registerUndo("Change Grid Type", before: before, undo: undo)
        revision += 1
    }

    // MARK: reading

    var gridType: GridType { GridType(rawValue: Int(bt_puzzle_grid_type(puzzle))) ?? .bricks }
    var canSolve: Bool { bt_puzzle_can_assemble(puzzle) != 0 }
    var canDisassemble: Bool { bt_puzzle_can_disassemble(puzzle) != 0 }
    var comment: String { takeString(bt_puzzle_comment(puzzle)) ?? "" }

    var shapes: [ShapeInfo] {
        (0..<Int(bt_shape_count(puzzle))).map { shape($0) }
    }

    func shape(_ i: Int) -> ShapeInfo {
        var x: Int32 = 0, y: Int32 = 0, z: Int32 = 0
        bt_shape_size(puzzle, Int32(i), &x, &y, &z)
        return ShapeInfo(id: i,
                         name: takeString(bt_shape_name(puzzle, Int32(i))) ?? "",
                         size: (Int(x), Int(y), Int(z)),
                         voxels: Int(bt_shape_voxel_count(puzzle, Int32(i))))
    }

    func voxel(_ shape: Int, _ x: Int, _ y: Int, _ z: Int) -> Int {
        Int(bt_shape_get(puzzle, Int32(shape), Int32(x), Int32(y), Int32(z)))
    }

    var problems: [ProblemInfo] {
        (0..<Int(bt_problem_count(puzzle))).map {
            ProblemInfo(id: $0, name: takeString(bt_problem_name(puzzle, Int32($0))) ?? "")
        }
    }

    func problemResult(_ p: Int) -> Int? {
        let r = Int(bt_problem_result(puzzle, Int32(p)))
        return r >= 0 ? r : nil
    }

    func problemShapeCount(_ p: Int, _ shape: Int) -> (min: Int, max: Int) {
        var mn: Int32 = 0, mx: Int32 = 0
        bt_problem_shape_count(puzzle, Int32(p), Int32(shape), &mn, &mx)
        return (Int(mn), Int(mx))
    }

    func problemStats(_ p: Int) -> (assemblies: Int, solutions: Int, seconds: Int) {
        var a = 0, s = 0, t = 0
        bt_problem_stats(puzzle, Int32(p), &a, &s, &t)
        return (a, s, t)
    }

    func problemSolveState(_ p: Int) -> Int { Int(bt_problem_solve_state(puzzle, Int32(p))) }

    func solutions(_ p: Int) -> [SolutionInfo] {
        guard !isSolving else { return [] }
        return (0..<Int(bt_problem_saved_solution_count(puzzle, Int32(p)))).map { i in
            let s = Int32(i), pr = Int32(p)
            return SolutionInfo(id: i,
                                number: Int(bt_solution_number(puzzle, pr, s)),
                                assemblyNumber: Int(bt_solution_assembly_number(puzzle, pr, s)),
                                moves: Int(bt_solution_moves(puzzle, pr, s)),
                                movesText: takeString(bt_solution_moves_text(puzzle, pr, s)))
        }
    }

    // MARK: solving

    /// Starts the solver. With `fromStart`, existing solutions are removed first
    /// (the solver can only add to an unsolved or paused problem); otherwise a
    /// paused run continues where it stopped.
    func startSolving(problem: Int, options: SolveOptions, fromStart: Bool, undo: UndoManager?) {
        guard !isSolving else { return }
        let before = try? serialize()
        let cleared = fromStart && problemSolveState(problem) != BT_SOLVE_UNSOLVED
        if cleared { bt_problem_clear_solutions(puzzle, Int32(problem)) }
        var err: UnsafeMutablePointer<CChar>?
        guard let handle = bt_solver_start(puzzle, Int32(problem), options.flags, Int32(options.sort),
                                           Int32(clamping: options.limit), &err) else {
            lastError = takeString(err) ?? "Could not start the solver."
            if cleared, let before {
                registerUndo("Clear Solutions", before: before, undo: undo)
                revision += 1
            }
            return
        }
        lastError = nil
        solverHandle = handle
        if let before { solveUndo = (before, undo) }
        solver = SolverStatus(problem: problem)
        solverTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollSolver()
        }
        pollSolver()
    }

    func stopSolving() {
        if let solverHandle { bt_solver_stop(solverHandle) }
    }

    private func pollSolver() {
        guard let handle = solverHandle, var status = solver else { return }
        var st = BTSolverStatus()
        bt_solver_status(handle, &st)
        status.action = Int(st.action)
        status.actionParameter = Int(st.actionParameter)
        status.assemblies = st.assemblies
        status.solutions = st.solutions
        status.seconds = st.seconds
        status.progress = st.progress
        solver = status
        if st.stopped != 0 { finishSolver() }
    }

    private func finishSolver() {
        guard let handle = solverHandle else { return }
        solverTimer?.invalidate()
        solverTimer = nil
        if let message = takeString(bt_solver_error(handle)) { lastError = message }
        bt_solver_free(handle)
        solverHandle = nil
        solver = nil
        if let (before, undo) = solveUndo {
            registerUndo("Solve", before: before, undo: undo)
        }
        solveUndo = nil
        revision += 1
    }

    /// Stops the solver (if running) and waits until its thread has ended.
    func stopSolverAndWait() {
        guard solverHandle != nil else { return }
        stopSolving()
        finishSolver()   // bt_solver_free waits for the thread
    }
}
