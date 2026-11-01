import AppKit
import BurrCore
import SwiftUI

/// Shows the Open dialog at launch instead of an empty "Untitled" puzzle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.turnOffAutosave()
    }

    /// SwiftUI documents save every change straight into the file. Turn that
    /// off so a puzzle is only written when the user saves, and closing or
    /// quitting with unsaved changes asks first. SwiftUI's document class is
    /// private (and made at runtime), so each document's class is changed as
    /// the document is added.
    private static func turnOffAutosave() {
        guard let original = class_getInstanceMethod(NSDocumentController.self, #selector(NSDocumentController.addDocument(_:))),
              let replacement = class_getInstanceMethod(NSDocumentController.self, #selector(NSDocumentController.bt_addDocument(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    private static var patched = Set<ObjectIdentifier>()

    static func turnOffAutosave(for cls: AnyClass) {
        guard patched.insert(ObjectIdentifier(cls)).inserted, let meta = object_getClass(cls) else { return }
        let no: @convention(block) (AnyObject) -> Bool = { _ in false }
        let imp = imp_implementationWithBlock(no)
        for sel in [#selector(getter: NSDocument.autosavesInPlace), #selector(getter: NSDocument.autosavesDrafts),
                    #selector(getter: NSDocument.preservesVersions)] {
            class_replaceMethod(meta, sel, imp, "c@:")
        }
    }

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

extension NSDocumentController {
    /// Swapped with addDocument(_:) at launch (see AppDelegate.turnOffAutosave).
    @objc func bt_addDocument(_ document: NSDocument) {
        AppDelegate.turnOffAutosave(for: Swift.type(of: document))
        bt_addDocument(document)   // the original addDocument(_:)
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
    /// Several shapes and problems can be selected (Command- or Shift-click) to delete them together.
    @StateObject private var selection = ViewState<Set<SidebarItem>>([.info])
    @StateObject private var showStlExport = ViewState<Bool>(false)
    @StateObject private var showNewBox = ViewState<Bool>(false)
    @StateObject private var showGenerator = ViewState<Bool>(false)

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
                            Button(deleteTitle(for: .shape(shape.id)), role: .destructive) { delete(clicked: .shape(shape.id)) }
                        }
                    }
                }

                Section("Problems") {
                    ForEach(problems) { problem in
                        Label(problem.displayName, systemImage: "puzzlepiece")
                            .tag(SidebarItem.problem(problem.id))
                            .contextMenu {
                                Button(deleteTitle(for: .problem(problem.id)), role: .destructive) { delete(clicked: .problem(problem.id)) }
                            }
                    }
                }
            }
            .onDeleteCommand { if !document.isSolving { deleteSelected() } }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        Button("New Shape") { addShape() }
                        Button("New Box…") { showNewBox.value = true }
                        Divider()
                        Button("Generate Puzzle…") { showGenerator.value = true }
                            .disabled(document.shapes.isEmpty)
                        Button("New Problem") { addProblem() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add a shape or problem")

                    Button {
                        deleteSelected()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!isDeletable)
                    .help("Delete the selected shapes and problems (Command- or Shift-click to select several)")
                    Spacer()
                }
                .padding(8)
                .disabled(document.isSolving)
            }
        } detail: {
            switch single {
            case .shape(let i) where i < shapes.count:
                ShapeDetailView(document: document, shape: i)
            case .problem(let i) where i < problems.count:
                ProblemDetailView(document: document, problem: i, onExportStl: { showStlExport.value = true })
            default:
                if deletable.count > 1 {
                    MultipleSelectionView(count: deletable.count, solving: document.isSolving) { deleteSelected() }
                } else {
                    PuzzleInfoView(document: document)
                }
            }
        }
        .focusedSceneValue(\.exportStl, canExportStl ? { showStlExport.value = true } : nil)
        .sheet(isPresented: $showGenerator.value) {
            GeneratorView(document: document) { selection.value = [.problem($0)] }
        }
        .sheet(isPresented: $showNewBox.value) {
            NewBoxView(document: document) { selection.value = [.shape($0)] }
        }
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
        if case .problem(let i) = single, i < document.problems.count { return i }
        return document.problems.first { document.problemResult($0.id) != nil }?.id
    }

    /// The selected item when exactly one is selected.
    private var single: SidebarItem? {
        selection.value.count == 1 ? selection.value.first : nil
    }

    /// The selected shapes and problems (the Puzzle item can't be deleted).
    private var deletable: Set<SidebarItem> {
        selection.value.filter { $0 != .info }
    }

    private var isDeletable: Bool { !deletable.isEmpty }

    /// A right-click on a selected item acts on the whole selection, otherwise on that item.
    private func targets(for clicked: SidebarItem) -> Set<SidebarItem> {
        deletable.contains(clicked) ? deletable : [clicked]
    }

    private func deleteTitle(for clicked: SidebarItem) -> String {
        let items = targets(for: clicked)
        if items.count == 1 {
            if case .shape = clicked { return "Delete Shape" }
            return "Delete Problem"
        }
        return "Delete \(items.count) Items"
    }

    private func delete(clicked: SidebarItem) { delete(targets(for: clicked)) }

    private func deleteSelected() { delete(deletable) }

    private func addShape() {
        let size = 3
        var newIndex = 0
        document.edit("New Shape", undo: undo) { p in
            newIndex = Int(bt_shape_add(p, Int32(size), Int32(size), Int32(size)))
        }
        selection.value = [.shape(newIndex)]
    }

    private func addProblem() {
        var newIndex = 0
        document.edit("New Problem", undo: undo) { p in
            newIndex = Int(bt_problem_add(p))
        }
        selection.value = [.problem(newIndex)]
    }

    /// Deletes the shapes and problems in one step, so one Undo brings them all back.
    /// Highest numbers go first so the others keep their numbers until removed.
    private func delete(_ items: Set<SidebarItem>) {
        var shapes: [Int] = [], problems: [Int] = []
        for item in items {
            switch item {
            case .shape(let i): shapes.append(i)
            case .problem(let i): problems.append(i)
            case .info: break
            }
        }
        guard !shapes.isEmpty || !problems.isEmpty else { return }
        let name = items.count == 1 ? (shapes.isEmpty ? "Delete Problem" : "Delete Shape") : "Delete \(items.count) Items"
        document.edit(name, undo: undo) { p in
            for i in problems.sorted(by: >) { bt_problem_remove(p, Int32(i)) }
            for i in shapes.sorted(by: >) { bt_shape_remove(p, Int32(i)) }
        }
        selection.value = [.info]
    }
}

/// Shown when several shapes and problems are selected.
struct MultipleSelectionView: View {
    let count: Int
    let solving: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("\(count) items selected").font(.title2)
            Button("Delete \(count) Items", role: .destructive, action: onDelete)
                .disabled(solving)
            Text("Undo brings them back.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
