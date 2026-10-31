import BurrCore
import SwiftUI

@main
struct BurrToolsApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PuzzleDocument() }) { file in
            ContentView(document: file.document)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 800)
    }
}

enum SidebarItem: Hashable {
    case info
    case shape(Int)
    case problem(Int)
}

struct ContentView: View {
    @ObservedObject var document: PuzzleDocument
    @Environment(\.undoManager) private var undo
    @StateObject private var selection = ViewState<SidebarItem?>(.info)

    var body: some View {
        let _ = document.revision
        let shapes = document.shapes
        let problems = document.problems

        NavigationSplitView {
            List(selection: $selection.value) {
                Label("Puzzle", systemImage: "info.circle").tag(SidebarItem.info)

                Section("Shapes") {
                    ForEach(shapes) { shape in
                        HStack {
                            ColorSwatch(shape: shape.id)
                            Text(shape.displayName)
                            Spacer()
                            Text("\(shape.voxels)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(SidebarItem.shape(shape.id))
                        .contextMenu {
                            Button("Delete Shape", role: .destructive) { deleteShape(shape.id) }
                        }
                    }
                }

                Section("Problems") {
                    ForEach(problems) { problem in
                        Label(problem.displayName, systemImage: "puzzlepiece")
                            .tag(SidebarItem.problem(problem.id))
                            .contextMenu {
                                Button("Delete Problem", role: .destructive) { deleteProblem(problem.id) }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        Button("New Shape") { addShape() }
                        Button("New Problem") { addProblem() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add a shape or problem")

                    Button {
                        switch selection.value {
                        case .shape(let i): deleteShape(i)
                        case .problem(let i): deleteProblem(i)
                        default: break
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!isDeletable)
                    .help("Delete the selected shape or problem")
                    Spacer()
                }
                .padding(8)
                .disabled(document.isSolving)
            }
        } detail: {
            switch selection.value {
            case .shape(let i) where i < shapes.count:
                ShapeDetailView(document: document, shape: i)
            case .problem(let i) where i < problems.count:
                ProblemDetailView(document: document, problem: i)
            default:
                PuzzleInfoView(document: document)
            }
        }
        .alert("BurrTools", isPresented: Binding(get: { document.lastError != nil },
                                                  set: { if !$0 { document.lastError = nil } })) {
            Button("OK") { document.lastError = nil }
        } message: {
            Text(document.lastError ?? "")
        }
    }

    private var isDeletable: Bool {
        switch selection.value {
        case .shape, .problem: return true
        default: return false
        }
    }

    private func addShape() {
        let size = 3
        var newIndex = 0
        document.edit("New Shape", undo: undo) { p in
            newIndex = Int(bt_shape_add(p, Int32(size), Int32(size), Int32(size)))
        }
        selection.value = .shape(newIndex)
    }

    private func addProblem() {
        var newIndex = 0
        document.edit("New Problem", undo: undo) { p in
            newIndex = Int(bt_problem_add(p))
        }
        selection.value = .problem(newIndex)
    }

    private func deleteShape(_ i: Int) {
        document.edit("Delete Shape", undo: undo) { p in bt_shape_remove(p, Int32(i)) }
        selection.value = .info
    }

    private func deleteProblem(_ i: Int) {
        document.edit("Delete Problem", undo: undo) { p in bt_problem_remove(p, Int32(i)) }
        selection.value = .info
    }
}

struct ColorSwatch: View {
    let shape: Int
    var copy = 0

    var body: some View {
        let c = PieceColors.color(shape: shape, copy: copy)
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)))
            .frame(width: 12, height: 12)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.2)))
    }
}

struct PuzzleInfoView: View {
    @ObservedObject var document: PuzzleDocument
    @Environment(\.undoManager) private var undo
    @StateObject private var comment = ViewState<String>("")

    var body: some View {
        let _ = document.revision
        let isEmpty = document.shapes.isEmpty && document.problems.isEmpty

        Form {
            Section("Grid") {
                if isEmpty {
                    Picker("Grid type", selection: Binding(get: { document.gridType },
                                                           set: { document.changeGridType($0, undo: undo) })) {
                        ForEach(GridType.allCases) { Text($0.name).tag($0) }
                    }
                } else {
                    LabeledContent("Grid type", value: document.gridType.name)
                }
                LabeledContent("Shapes", value: "\(document.shapes.count)")
                LabeledContent("Problems", value: "\(document.problems.count)")
            }

            Section("Comment") {
                TextEditor(text: $comment.value)
                    .font(.body)
                    .frame(minHeight: 160)
                HStack {
                    Spacer()
                    Button("Save Comment") { saveComment() }
                        .disabled(comment.value == document.comment || document.isSolving)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { comment.value = document.comment }
        .onChange(of: document.revision) { _, _ in comment.value = document.comment }
        .onDisappear { saveComment() }
    }

    private func saveComment() {
        guard comment.value != document.comment else { return }
        let text = comment.value
        document.edit("Edit Comment", undo: undo) { p in bt_puzzle_set_comment(p, text) }
    }
}
