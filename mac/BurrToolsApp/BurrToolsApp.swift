import AppKit
import BurrCore
import SwiftUI

/// Shows the Open dialog at launch instead of an empty "Untitled" puzzle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // give macOS a moment to reopen windows or open files it was asked to
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.showOpenIfNoDocuments() }
    }

    /// Clicking the Dock icon with no windows open shows the Open dialog too.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.showOpenIfNoDocuments() }
        return false
    }

    private static func showOpenIfNoDocuments() {
        let controller = NSDocumentController.shared
        // SwiftUI opens an empty "Untitled" puzzle at launch on its own (even when
        // a file is being opened); close it if nothing has been done in it
        controller.documents
            .filter { $0.fileURL == nil && !$0.isDocumentEdited }
            .forEach { $0.close() }
        if controller.documents.isEmpty {
            controller.openDocument(nil)
        }
    }
}

@main
struct BurrToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--export-gif") {
            exit(CommandLineExport.run(CommandLine.arguments))
        }
    }

    var body: some Scene {
        DocumentGroup(newDocument: { PuzzleDocument() }) { file in
            ContentView(document: file.document)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .importExport) {
                ExportStlCommand()
            }
        }
    }
}

struct ExportStlActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var exportStl: (() -> Void)? {
        get { self[ExportStlActionKey.self] }
        set { self[ExportStlActionKey.self] = newValue }
    }
}

struct ExportStlCommand: View {
    @FocusedValue(\.exportStl) private var exportStl

    var body: some View {
        Button("Export STL…") { exportStl?() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(exportStl == nil)
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
    @StateObject private var showStlExport = ViewState<Bool>(false)

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
                ProblemDetailView(document: document, problem: i, onExportStl: { showStlExport.value = true })
            default:
                PuzzleInfoView(document: document)
            }
        }
        .focusedSceneValue(\.exportStl, canExportStl ? { showStlExport.value = true } : nil)
        .sheet(isPresented: $showStlExport.value) {
            StlExportView(document: document, problem: stlProblem)
        }
        .alert("BurrTools", isPresented: Binding(get: { document.lastError != nil },
                                                  set: { if !$0 { document.lastError = nil } })) {
            Button("OK") { document.lastError = nil }
        } message: {
            Text(document.lastError ?? "")
        }
    }

    private var canExportStl: Bool {
        !document.isSolving && bt_puzzle_can_export_stl(document.puzzle) != 0 && !document.shapes.isEmpty
    }

    /// The problem whose result shape sets the assembled size: the selected one,
    /// or else the first problem that has a result shape.
    private var stlProblem: Int? {
        if case .problem(let i) = selection.value, i < document.problems.count { return i }
        return document.problems.first { document.problemResult($0.id) != nil }?.id
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
