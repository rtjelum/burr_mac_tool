import BurrCore
import SwiftUI

struct ProblemDetailView: View {
    @ObservedObject var document: PuzzleDocument
    let problem: Int
    var onExportStl: () -> Void = {}
    @Environment(\.undoManager) private var undo
    @StateObject private var name = ViewState<String>("")
    @StateObject private var options = ViewState<SolveOptions>(SolveOptions())
    @StateObject private var selectedSolution = ViewState<Int?>(nil)

    var body: some View {
        let _ = document.revision
        let shapes = document.shapes
        let solutions = document.solutions(problem)

        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Problem") {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                            GridRow {
                                Text("Name")
                                TextField("Name", text: $name.value, onEditingChanged: { if !$0 { saveName() } })
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(saveName)
                            }
                            GridRow {
                                Text("Result")
                                Picker("", selection: Binding(
                                    get: { document.problemResult(problem) ?? -1 },
                                    set: { r in document.edit("Set Result", undo: undo) { p in bt_problem_set_result(p, Int32(problem), Int32(r)) } })) {
                                    Text("None").tag(-1)
                                    ForEach(shapes) { Text($0.displayName).tag($0.id) }
                                }
                                .labelsHidden()
                            }
                        }
                        .padding(6)
                    }

                    GroupBox("Pieces") {
                        VStack(alignment: .leading, spacing: 8) {
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                                GridRow {
                                    Text("Shape")
                                    Text("Min").gridColumnAlignment(.trailing)
                                    Text("Max").gridColumnAlignment(.trailing)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                ForEach(shapes) { shape in
                                    pieceRow(shape)
                                }
                            }
                            HStack(alignment: .firstTextBaseline) {
                                Text("How many copies of each shape the solver may use.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Export STL…", action: onExportStl)
                                    .disabled(document.isSolving || bt_puzzle_can_export_stl(document.puzzle) == 0)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    solveSection
                }
                .padding(14)
            }
            .frame(minWidth: 380, idealWidth: 420, maxWidth: 520)
            .disabled(document.isSolving && !isSolvingThis)

            solutionPane(solutions)
                .frame(minWidth: 360)
        }
        .onAppear { name.value = document.problems[safe: problem]?.name ?? ""; options.value.disassemble = document.canDisassemble }
        .onChange(of: problem) { _, _ in
            name.value = document.problems[safe: problem]?.name ?? ""
            selectedSolution.value = nil
        }
        .onDisappear(perform: saveName)
    }

    private var isSolvingThis: Bool { document.solver?.problem == problem }

    private func pieceRow(_ shape: ShapeInfo) -> some View {
        let count = document.problemShapeCount(problem, shape.id)
        let isResult = document.problemResult(problem) == shape.id
        return GridRow {
            HStack(spacing: 6) {
                ColorSwatch(shape: shape.id)
                Text(shape.displayName).lineLimit(1)
                if isResult { Text("(result)").foregroundStyle(.secondary) }
            }
            countStepper(count.min) { setCount(shape.id, min: $0, max: max($0, count.max)) }
            countStepper(count.max) { setCount(shape.id, min: min(count.min, $0), max: $0) }
        }
        .disabled(document.isSolving)
    }

    private func countStepper(_ value: Int, set: @escaping (Int) -> Void) -> some View {
        Stepper(value: Binding(get: { value }, set: set), in: 0...99) {
            Text("\(value)").monospacedDigit().frame(minWidth: 18, alignment: .trailing)
        }
        .fixedSize()
    }

    private func setCount(_ shape: Int, min mn: Int, max mx: Int) {
        document.edit("Change Piece Count", undo: undo) { p in
            bt_problem_set_shape_count(p, Int32(problem), Int32(shape), Int32(mn), Int32(mx))
        }
    }

    @ViewBuilder private var solveSection: some View {
        let state = document.problemSolveState(problem)
        let stats = document.problemStats(problem)

        GroupBox("Solve") {
          VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Find disassemblies", isOn: $options.value.disassemble)
                    .disabled(!document.canDisassemble)
                Toggle("Reduce placements first", isOn: $options.value.reduce)
                Toggle("Keep mirror solutions", isOn: $options.value.keepMirrors)
                Toggle("Keep rotated solutions", isOn: $options.value.keepRotations)
                Toggle("Thorough rotation check", isOn: $options.value.completeRotations)
                Toggle("Only count solutions", isOn: $options.value.justCount)
                Toggle("Drop disassembly steps after analysis", isOn: $options.value.dropDisassemblies)
                Picker("Sort solutions", selection: $options.value.sort) {
                    Text("Unsorted").tag(BT_SORT_NONE)
                    Text("By number of moves").tag(BT_SORT_MOVES)
                    Text("By level").tag(BT_SORT_LEVEL)
                }
                .fixedSize()
                HStack {
                    Text("Keep at most")
                    TextField("", value: $options.value.limit, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Text("solutions (0 = all)").foregroundStyle(.secondary)
                }
            }
            .disabled(document.isSolving)

            if let s = document.solver, isSolvingThis {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(s.actionText)
                        Spacer()
                        Text(formatTime(s.seconds)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if s.progress >= 0 {
                        ProgressView(value: min(1, s.progress))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text("\(plural(max(0, s.assemblies), "assembly", "assemblies")), \(plural(max(0, s.solutions), "solution", "solutions"))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else if stats.assemblies >= 0 {
                Text("Found \(plural(stats.assemblies, "assembly", "assemblies")) and \(plural(stats.solutions, "solution", "solutions")) in \(formatTime(stats.seconds)).")
                    .foregroundStyle(.secondary)
            }

            HStack {
                if isSolvingThis {
                    Button("Stop") { document.stopSolving() }
                } else {
                    if state == BT_SOLVE_SOLVING {
                        // a paused run: carry on, or throw it away and start again
                        Button("Continue") { solve(fromStart: false) }
                            .keyboardShortcut("r", modifiers: .command)
                            .disabled(document.isSolving || !document.canSolve)
                        Button("Solve from Start") { solve(fromStart: true) }
                            .disabled(document.isSolving || !document.canSolve)
                    } else {
                        Button("Solve") { solve(fromStart: true) }
                            .keyboardShortcut("r", modifiers: .command)
                            .disabled(document.isSolving || !document.canSolve)
                    }
                }
                Spacer()
                Button("Clear Solutions", role: .destructive) {
                    selectedSolution.value = nil
                    document.edit("Clear Solutions", undo: undo) { p in bt_problem_clear_solutions(p, Int32(problem)) }
                }
                .disabled(document.isSolving || state == BT_SOLVE_UNSOLVED)
            }
            if !document.canSolve {
                Text("This grid type has no solver.").foregroundStyle(.secondary)
            }
          }
          .padding(6)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func solutionPane(_ solutions: [SolutionInfo]) -> some View {
        if document.isSolving {
            placeholder("Solving…", "Solutions appear here when the solver stops.")
        } else if solutions.isEmpty {
            placeholder("No solutions", "Press Solve to search for solutions.")
        } else {
            VSplitView {
                List(solutions, selection: $selectedSolution.value) { s in
                    Text(s.title).tag(s.id)
                }
                .frame(minHeight: 90, idealHeight: 140)

                if let sel = selectedSolution.value, sel < solutions.count {
                    SolutionSceneView(document: document, problem: problem, solution: sel)
                        .id("\(problem)-\(sel)-\(document.revision)")
                        .frame(minHeight: 300)
                } else {
                    placeholder("Select a solution", "Pick a solution to see it in 3D.")
                        .frame(minHeight: 300)
                }
            }
            .onAppear { if selectedSolution.value == nil { selectedSolution.value = 0 } }
        }
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.title3)
            Text(detail).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveName() {
        guard let current = document.problems[safe: problem], name.value != current.name else { return }
        let n = name.value
        document.edit("Rename Problem", undo: undo) { p in bt_problem_set_name(p, Int32(problem), n) }
    }

    private func solve(fromStart: Bool) {
        selectedSolution.value = nil
        document.startSolving(problem: problem, options: options.value, fromStart: fromStart, undo: undo)
    }

    private func plural(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    private func formatTime(_ seconds: Int) -> String {
        guard seconds >= 0 else { return "–" }
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
