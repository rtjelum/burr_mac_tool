import AppKit
import BurrCore
import SwiftUI

struct ShapeDetailView: View {
    @ObservedObject var document: PuzzleDocument
    let shape: Int
    @Environment(\.undoManager) private var undo
    @StateObject private var name = ViewState<String>("")
    @StateObject private var layer = ViewState<Int>(0)

    var body: some View {
        let _ = document.revision
        let info = document.shape(shape)

        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ColorSwatch(shape: shape)
                TextField("Name", text: $name.value)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit(saveName)
                sizeStepper("X", info.size.x) { resize(info, x: $0) }
                sizeStepper("Y", info.size.y) { resize(info, y: $0) }
                sizeStepper("Z", info.size.z) { resize(info, z: $0) }
                Spacer()
                ShapeFillMenu(document: document, shape: shape)
                Text("\(info.voxels) units").foregroundStyle(.secondary)
            }
            .padding(10)
            .disabled(document.isSolving)

            Divider()

            HSplitView {
                if document.gridType == .bricks {
                    LayerEditor(document: document, shape: shape, layer: $layer.value)
                        .frame(minWidth: 280)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "pencil.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Editing \(document.gridType.name.lowercased()) shapes is not supported yet.")
                        Text("You can view and solve these puzzles.").foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
                ShapeSceneView(document: document, shape: shape, revision: document.revision)
                    .frame(minWidth: 300)
            }
        }
        .onAppear { name.value = info.name }
        .onChange(of: shape) { _, _ in name.value = document.shape(shape).name; layer.value = 0 }
        .onDisappear(perform: saveName)
    }

    private func sizeStepper(_ label: String, _ value: Int, set: @escaping (Int) -> Void) -> some View {
        Stepper(value: Binding(get: { value }, set: set), in: 1...64) {
            Text("\(label) \(value)").monospacedDigit()
        }
        .fixedSize()
    }

    private func resize(_ info: ShapeInfo, x: Int? = nil, y: Int? = nil, z: Int? = nil) {
        let nx = x ?? info.size.x, ny = y ?? info.size.y, nz = z ?? info.size.z
        document.edit("Resize Shape", undo: undo) { p in
            bt_shape_resize(p, Int32(shape), Int32(nx), Int32(ny), Int32(nz))
        }
        layer.value = min(layer.value, nz - 1)
    }

    private func saveName() {
        guard shape < document.shapes.count, name.value != document.shape(shape).name else { return }
        let n = name.value
        document.edit("Rename Shape", undo: undo) { p in bt_shape_set_name(p, Int32(shape), n) }
    }
}

/// Edits one Z layer of a cube-grid shape.
/// Click or drag to paint with the chosen pen (filled, variable or empty).
struct LayerEditor: View {
    @ObservedObject var document: PuzzleDocument
    let shape: Int
    @Binding var layer: Int
    @Environment(\.undoManager) private var undo

    @StateObject private var paintValue = ViewState<Int?>(nil)
    @StateObject private var editStart = ViewState<Data?>(nil)
    @StateObject private var pen = ViewState<Int>(BT_VOXEL_FILLED)

    var body: some View {
        let _ = document.revision
        let info = document.shape(shape)
        let sx = info.size.x, sy = info.size.y, sz = info.size.z

        VStack(spacing: 8) {
            HStack {
                Stepper(value: Binding(get: { min(layer, sz - 1) }, set: { layer = $0 }), in: 0...max(0, sz - 1)) {
                    Text("Layer \(min(layer, sz - 1) + 1) of \(sz)").monospacedDigit()
                }
                Spacer()
                Picker("Pen", selection: $pen.value) {
                    Label("Filled", systemImage: "square.fill").tag(BT_VOXEL_FILLED)
                    Label("Variable", systemImage: "square.dashed.inset.filled").tag(BT_VOXEL_VARIABLE)
                    Label("Empty", systemImage: "eraser").tag(BT_VOXEL_EMPTY)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("What clicking and dragging paints. Variable cubes may be filled or left empty by the solver.")
            }
            .disabled(document.isSolving)

            HStack {
                Spacer()
                Button(pen.value == BT_VOXEL_VARIABLE ? "Layer Variable" : "Fill Layer") {
                    fillLayer(pen.value == BT_VOXEL_EMPTY ? BT_VOXEL_FILLED : pen.value, sx, sy)
                }
                Button("Clear Layer") { fillLayer(BT_VOXEL_EMPTY, sx, sy) }
            }
            .controlSize(.small)
            .disabled(document.isSolving)

            GeometryReader { geo in
                let cell = max(8, min((geo.size.width - 2) / CGFloat(sx), (geo.size.height - 2) / CGFloat(sy)))
                let width = cell * CGFloat(sx), height = cell * CGFloat(sy)
                let z = min(layer, sz - 1)

                Canvas { ctx, _ in
                    let base = PieceColors.color(shape: shape)
                    let light = PieceColors.light(base), dark = PieceColors.dark(base)
                    for x in 0..<sx {
                        for y in 0..<sy {
                            // y = 0 is drawn at the bottom
                            let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(sy - 1 - y) * cell, width: cell, height: cell)
                            let state = document.voxel(shape, x, y, z)
                            let c = (x + y + z) % 2 == 0 ? light : dark
                            let fill = Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b))
                            if state == BT_VOXEL_FILLED {
                                ctx.fill(Path(rect), with: .color(fill))
                            } else if state == BT_VOXEL_VARIABLE {
                                ctx.fill(Path(rect), with: .color(fill.opacity(0.45)))
                                ctx.fill(Path(ellipseIn: rect.insetBy(dx: cell * 0.35, dy: cell * 0.35)), with: .color(.black.opacity(0.7)))
                            } else if z > 0 && document.voxel(shape, x, y, z - 1) != BT_VOXEL_EMPTY {
                                ctx.fill(Path(rect), with: .color(fill.opacity(0.15)))
                            }
                            ctx.stroke(Path(rect), with: .color(.secondary.opacity(0.5)), lineWidth: 0.5)
                        }
                    }
                }
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in paint(at: g.location, cell: cell, sx: sx, sy: sy, z: z) }
                        .onEnded { _ in
                            document.commitEdit("Edit Shape", before: editStart.value, undo: undo)
                            editStart.value = nil
                            paintValue.value = nil
                        }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text("Click or drag to paint with the pen; clicking a cube that already has that state clears it. Hold ⌥ Option to paint variable cubes. Variable cubes show a dot.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func paint(at p: CGPoint, cell: CGFloat, sx: Int, sy: Int, z: Int) {
        guard !document.isSolving else { return }
        let x = Int(p.x / cell), y = sy - 1 - Int(p.y / cell)
        guard x >= 0, y >= 0, x < sx, y < sy, p.x >= 0, p.y >= 0 else { return }

        if paintValue.value == nil {
            // first touch decides whether this stroke paints the pen or clears
            let target = NSEvent.modifierFlags.contains(.option) ? BT_VOXEL_VARIABLE : pen.value
            paintValue.value = (target != BT_VOXEL_EMPTY && document.voxel(shape, x, y, z) == target) ? BT_VOXEL_EMPTY : target
            editStart.value = document.beginEdit()
        }
        guard let value = paintValue.value, document.voxel(shape, x, y, z) != value else { return }
        document.liveChange { p in bt_shape_set(p, Int32(shape), Int32(x), Int32(y), Int32(z), Int32(value)) }
    }

    private func fillLayer(_ value: Int, _ sx: Int, _ sy: Int) {
        let z = layer
        document.edit(value == BT_VOXEL_EMPTY ? "Clear Layer" : (value == BT_VOXEL_VARIABLE ? "Make Layer Variable" : "Fill Layer"), undo: undo) { p in
            for x in 0..<sx {
                for y in 0..<sy {
                    bt_shape_set(p, Int32(shape), Int32(x), Int32(y), Int32(z), Int32(value))
                }
            }
        }
    }
}

/// The whole-shape fill tools of the original BurrTools, plus a few more.
struct ShapeFillMenu: View {
    @ObservedObject var document: PuzzleDocument
    let shape: Int
    @Environment(\.undoManager) private var undo

    var body: some View {
        Menu("Fill") {
            Section("Whole shape") {
                tool("Fill Everything", BT_TOOL_FILL_ALL)
                tool("Clear Everything", BT_TOOL_CLEAR_ALL)
                tool("Fill Enclosed Holes", BT_TOOL_FILL_HOLES)
            }
            Section("Inside (cubes not on the surface)") {
                tool("Make Inside Variable", BT_TOOL_INSIDE_VARIABLE)
                tool("Make Inside Filled", BT_TOOL_INSIDE_FILLED)
                tool("Hollow Out (Make Inside Empty)", BT_TOOL_INSIDE_EMPTY)
            }
            Section("Outside (cubes on the surface)") {
                tool("Make Outside Variable", BT_TOOL_OUTSIDE_VARIABLE)
                tool("Make Outside Filled", BT_TOOL_OUTSIDE_FILLED)
            }
            Section("All cubes") {
                tool("Make All Variable", BT_TOOL_ALL_VARIABLE)
                tool("Make All Filled", BT_TOOL_ALL_FILLED)
            }
        }
        .fixedSize()
        .disabled(document.isSolving)
        .help("Fill tools for the whole shape. \"Make Inside Variable\" turns a solid box into a result shape whose centre may stay empty.")
    }

    private func tool(_ title: String, _ id: Int) -> some View {
        Button(title) {
            document.edit(title, undo: undo) { p in bt_shape_tool(p, Int32(shape), Int32(id)) }
        }
    }
}

/// Creates a box-shaped shape with a chosen fill, e.g. a result shape with a variable centre.
struct NewBoxView: View {
    @ObservedObject var document: PuzzleDocument
    var onCreated: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undo
    @StateObject private var size = ViewState(SIMD3<Int>(5, 5, 5))
    @StateObject private var fill = ViewState<Int>(BT_TOOL_INSIDE_VARIABLE)
    @StateObject private var name = ViewState<String>("")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Box").font(.title2.bold())
            Form {
                TextField("Name", text: $name.value, prompt: Text("optional"))
                LabeledContent("Size") {
                    HStack {
                        dim("X", \.x)
                        dim("Y", \.y)
                        dim("Z", \.z)
                    }
                }
                Picker("Fill", selection: $fill.value) {
                    Text("Solid").tag(BT_TOOL_FILL_ALL)
                    Text("Variable inside (like Borneo)").tag(BT_TOOL_INSIDE_VARIABLE)
                    Text("Hollow (empty inside)").tag(BT_TOOL_INSIDE_EMPTY)
                    Text("All variable").tag(BT_TOOL_ALL_VARIABLE)
                }
                .pickerStyle(.radioGroup)
            }
            .formStyle(.grouped)
            Text(description).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var description: String {
        switch fill.value {
        case BT_TOOL_INSIDE_VARIABLE:
            return "The surface must be filled; cubes inside may be filled or left empty. Use it as the result shape when the pieces don't fill the box completely. Limit the empty cubes with Max holes on the problem."
        case BT_TOOL_INSIDE_EMPTY:
            return "Only the surface is filled; the inside is empty."
        case BT_TOOL_ALL_VARIABLE:
            return "Every cube may be filled or left empty."
        default:
            return "Every cube is filled."
        }
    }

    private func dim(_ label: String, _ key: WritableKeyPath<SIMD3<Int>, Int>) -> some View {
        Stepper(value: Binding(get: { size.value[keyPath: key] }, set: { size.value[keyPath: key] = $0 }), in: 1...40) {
            Text("\(label) \(size.value[keyPath: key])").monospacedDigit()
        }
        .fixedSize()
    }

    private func create() {
        let s = size.value, f = fill.value, n = name.value
        var index = 0
        document.edit("New Box", undo: undo) { p in
            index = Int(bt_shape_add(p, Int32(s.x), Int32(s.y), Int32(s.z)))
            bt_shape_tool(p, Int32(index), Int32(BT_TOOL_FILL_ALL))
            if f != BT_TOOL_FILL_ALL { bt_shape_tool(p, Int32(index), Int32(f)) }
            if !n.isEmpty { bt_shape_set_name(p, Int32(index), n) }
        }
        onCreated(index)
        dismiss()
    }
}
