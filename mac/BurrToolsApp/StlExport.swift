import AppKit
import BurrCore
import SceneKit
import SwiftUI

/// One setting of the C++ STL exporter (bevel, wall thickness, ...).
struct StlParameter: Identifiable {
    let id: Int
    let name: String
    let tooltip: String
    let isSwitch: Bool
    let isInteger: Bool
    let allowsNegative: Bool
}

struct StlPiece: Identifiable {
    let id: Int          // shape index
    let name: String
    let copies: Int
}

enum SizeAxis: String, CaseIterable, Identifiable {
    case largest = "Largest side", x = "X", y = "Y", z = "Z"
    var id: String { rawValue }
}

/// Settings and calculations for exporting a problem's pieces as STL files.
///
/// You enter the size of the assembled puzzle and the clearance between pieces;
/// the model works out the unit size (mm per grid unit) and the face offset.
/// Clearance between two pieces is 2 × offset, and the outside of the assembly
/// loses the offset (plus bevel trimming on pointed grids) on each side, which
/// is measured from a real piece mesh so the final size comes out exact.
final class StlExportModel: ObservableObject {
    let document: PuzzleDocument
    let problem: Int?
    let pieces: [StlPiece]
    let parameters: [StlParameter]   // exporter settings shown to the user
    let resultExtent: SIMD3<Float>?  // assembled size in grid units

    @Published var targetSize: Double = 60 { didSet { recalc() } }
    @Published var axis: SizeAxis = .largest { didSet { recalc() } }
    @Published var clearance: Double = 0.2 { didSet { recalc() } }
    @Published var manualUnit: Double = 10 { didSet { recalc() } }
    @Published var values: [Int: Double] = [:] { didSet { recalc() } }
    @Published var binary = true
    @Published var selected: Set<Int> = []
    @Published var previewPiece: Int?

    /// Results of the last calculation.
    @Published private(set) var unit: Double = 10
    @Published private(set) var assembledSize: SIMD3<Double>?
    @Published private(set) var previewMesh: SCNGeometry?
    @Published private(set) var previewSize: SIMD3<Float>?
    @Published private(set) var previewError: String?
    @Published private(set) var sizeNote: String?

    private let handle: OpaquePointer?
    private let isSpheres: Bool
    private let unitIndex: Int
    private let offsetIndex: Int

    init(document: PuzzleDocument, problem: Int?) {
        self.document = document
        self.problem = problem
        handle = bt_stl_create(document.puzzle)
        isSpheres = document.gridType == .spheres
        unitIndex = 0
        offsetIndex = isSpheres ? 3 : 2

        // pieces: the shapes the problem uses, or every shape if there is no problem
        var list: [StlPiece] = []
        let result = problem.flatMap { document.problemResult($0) }
        for shape in document.shapes where shape.voxels > 0 && shape.id != result {
            let copies = problem.map { document.problemShapeCount($0, shape.id).max } ?? 1
            if copies > 0 { list.append(StlPiece(id: shape.id, name: shape.displayName, copies: copies)) }
        }
        pieces = list

        if let result {
            var x: Float = 0, y: Float = 0, z: Float = 0
            bt_shape_extent(document.puzzle, Int32(result), &x, &y, &z)
            resultExtent = SIMD3(x, y, z)
        } else {
            resultExtent = nil
        }

        var params: [StlParameter] = []
        var vals: [Int: Double] = [:]
        if let handle {
            for i in 0..<Int(bt_stl_param_count(handle)) where i != unitIndex && i != offsetIndex {
                let type = Int(bt_stl_param_type(handle, Int32(i)))
                params.append(StlParameter(
                    id: i,
                    name: takeString(bt_stl_param_name(handle, Int32(i))) ?? "",
                    tooltip: (takeString(bt_stl_param_tooltip(handle, Int32(i))) ?? "").trimmingCharacters(in: .whitespaces),
                    isSwitch: type == BT_STL_SWITCH,
                    isInteger: type == BT_STL_POS_INTEGER,
                    allowsNegative: type == BT_STL_DOUBLE))
                vals[i] = bt_stl_param_get(handle, Int32(i))
            }
        }
        parameters = params
        values = vals
        selected = Set(list.map(\.id))
        previewPiece = list.first?.id

        // start with the size the puzzle would have at the exporter's default unit
        if let e = resultExtent {
            targetSize = (Double(e.max()) * 10 - clearance).rounded()
        }
        recalc()
    }

    deinit { bt_stl_free(handle) }

    var canExport: Bool { handle != nil && !pieces.isEmpty }
    var sizesFromResult: Bool { resultExtent != nil }

    /// The grid-unit extent along the axis the user chose.
    private var chosenAxis: Int {
        guard let e = resultExtent else { return 0 }
        switch axis {
        case .largest: return e.x >= e.y && e.x >= e.z ? 0 : (e.y >= e.z ? 1 : 2)
        case .x: return 0
        case .y: return 1
        case .z: return 2
        }
    }

    private func applyParameters(unit: Double) {
        guard let handle else { return }
        for (i, v) in values { bt_stl_param_set(handle, Int32(i), v) }
        bt_stl_param_set(handle, Int32(unitIndex), isSpheres ? unit / 2 : unit)
        bt_stl_param_set(handle, Int32(offsetIndex), clearance / 2)
        bt_stl_set_binary(handle, binary ? 1 : 0)
    }

    private func mesh(_ shape: Int) -> (UnsafeMutablePointer<BTMesh>?, String?) {
        var err: UnsafeMutablePointer<CChar>?
        let m = bt_stl_mesh(handle, document.puzzle, Int32(shape), &err)
        return (m, takeString(err))
    }

    private static func bounds(_ m: UnsafeMutablePointer<BTMesh>) -> SIMD3<Float> {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        let p = m.pointee.positions!
        for i in 0..<Int(m.pointee.triangleCount) * 3 {
            let v = SIMD3(p[i * 3], p[i * 3 + 1], p[i * 3 + 2])
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        return hi - lo
    }

    private func shapeExtent(_ shape: Int) -> SIMD3<Float> {
        var x: Float = 0, y: Float = 0, z: Float = 0
        bt_shape_extent(document.puzzle, Int32(shape), &x, &y, &z)
        return SIMD3(x, y, z)
    }

    /// How much the printed piece is smaller than (grid extent × unit) along each axis.
    /// This depends only on clearance and bevel (in mm), not on the unit size.
    private func measureLoss(unit: Double) -> SIMD3<Double> {
        var loss = SIMD3<Double>(repeating: clearance)
        for a in 0..<3 {
            // use the piece that reaches furthest along this axis
            guard let piece = pieces.max(by: { shapeExtent($0.id)[a] < shapeExtent($1.id)[a] }) else { continue }
            let (m, _) = mesh(piece.id)
            guard let m else { continue }
            let printed = Double(Self.bounds(m)[a])
            bt_mesh_free(m)
            loss[a] = Double(shapeExtent(piece.id)[a]) * unit - printed
        }
        return loss
    }

    func recalc() {
        guard handle != nil else { return }
        sizeNote = nil

        if let e = resultExtent {
            let a = chosenAxis
            let ext = Double(e[a])
            guard ext > 0, targetSize > 0 else { return }
            // first guess, exact for cube grids
            var u = (targetSize + clearance) / ext
            applyParameters(unit: u)
            let loss = measureLoss(unit: u)
            u = (targetSize + loss[a]) / ext
            applyParameters(unit: u)
            unit = u
            let ed = SIMD3<Double>(Double(e.x), Double(e.y), Double(e.z))
            assembledSize = ed * u - loss
            let pointed = document.gridType == .rhombic || document.gridType == .tetraOcta
            if pointed && abs(loss[a] - clearance) > 0.05 {
                sizeNote = "Pointed corners are trimmed by the bevel and clearance; the unit size makes up for it."
            }
        } else {
            unit = manualUnit
            applyParameters(unit: manualUnit)
            assembledSize = nil
        }
        updatePreview()
    }

    func updatePreview() {
        previewMesh = nil
        previewSize = nil
        previewError = nil
        guard let piece = previewPiece else { return }
        let (m, err) = mesh(piece)
        guard let m else {
            previewError = err ?? "Could not create the mesh."
            return
        }
        previewSize = Self.bounds(m)
        previewMesh = MeshBuilder.geometry(m, shape: piece, copy: 0)
        bt_mesh_free(m)
    }

    // MARK: export

    func fileName(for piece: StlPiece) -> String {
        var name = piece.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if piece.copies > 1 { name += " x\(piece.copies)" }
        return name + ".stl"
    }

    /// Writes the chosen pieces into `folder`. Returns a list of problems, empty on success.
    func export(_ chosen: [StlPiece], to folder: URL) -> [String] {
        applyParameters(unit: unit)
        var problems: [String] = []
        for piece in chosen {
            let url = folder.appendingPathComponent(fileName(for: piece))
            var err: UnsafeMutablePointer<CChar>?
            if bt_stl_write(handle, document.puzzle, Int32(piece.id), url.path, &err) == 0 {
                problems.append("\(piece.name): \(takeString(err) ?? "unknown error")")
            }
        }
        return problems
    }

    func export(_ piece: StlPiece, to url: URL) -> String? {
        applyParameters(unit: unit)
        var err: UnsafeMutablePointer<CChar>?
        if bt_stl_write(handle, document.puzzle, Int32(piece.id), url.path, &err) == 0 {
            return takeString(err) ?? "unknown error"
        }
        return nil
    }
}

struct StlExportView: View {
    @StateObject private var model: StlExportModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var message = ViewState<String?>(nil)

    init(document: PuzzleDocument, problem: Int?) {
        _model = StateObject(wrappedValue: StlExportModel(document: document, problem: problem))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        sizeBox
                        detailsBox
                        piecesBox
                    }
                    .padding(16)
                }
                .frame(width: 420)

                Divider()

                preview
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Toggle("Binary STL (smaller files)", isOn: $model.binary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export Selected…") { exportSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selected.isEmpty || !model.canExport)
            }
            .padding(12)
        }
        .frame(width: 900, height: 640)
        .alert("Export STL", isPresented: Binding(get: { message.value != nil }, set: { if !$0 { message.value = nil } })) {
            Button("OK") { message.value = nil }
        } message: {
            Text(message.value ?? "")
        }
    }

    // MARK: sections

    private var sizeBox: some View {
        GroupBox("Size") {
            VStack(alignment: .leading, spacing: 10) {
                if model.sizesFromResult {
                    HStack {
                        Text("Assembled puzzle")
                        mmField($model.targetSize)
                        Picker("", selection: $model.axis) {
                            ForEach(SizeAxis.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                } else {
                    HStack {
                        Text("Unit size")
                        mmField($model.manualUnit)
                    }
                    Text("Set a result shape on the problem to enter the assembled size instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Clearance between pieces")
                    mmField($model.clearance)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    if let s = model.assembledSize {
                        Text("Assembled: \(mm(s.x)) × \(mm(s.y)) × \(mm(s.z))")
                    }
                    Text("Unit size: \(mm(model.unit)) per \(model.document.gridType == .spheres ? "sphere" : "unit")")
                    Text("Each piece face is set back \(mm(model.clearance / 2)), leaving \(mm(model.clearance)) between pieces.")
                    if let note = model.sizeNote { Text(note) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detailsBox: some View {
        GroupBox("Shape details") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(model.parameters) { p in
                    GridRow {
                        Text(p.name).help(p.tooltip)
                        if p.isSwitch {
                            Toggle("", isOn: Binding(get: { (model.values[p.id] ?? 0) != 0 },
                                                     set: { model.values[p.id] = $0 ? 1 : 0 }))
                                .labelsHidden()
                                .help(p.tooltip)
                        } else {
                            TextField("", value: Binding(get: { model.values[p.id] ?? 0 },
                                                         set: { model.values[p.id] = p.allowsNegative ? $0 : max(0, $0) }),
                                      format: .number.precision(.fractionLength(0...3)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .help(p.tooltip)
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var piecesBox: some View {
        GroupBox("Pieces") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.pieces) { piece in
                    HStack {
                        Toggle("", isOn: Binding(get: { model.selected.contains(piece.id) },
                                                 set: { on in
                                                     if on { model.selected.insert(piece.id) } else { model.selected.remove(piece.id) }
                                                 }))
                            .labelsHidden()
                        ColorSwatch(shape: piece.id)
                        Text(piece.name)
                        if piece.copies > 1 {
                            Text("× \(piece.copies)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.previewPiece == piece.id {
                            Image(systemName: "eye").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.previewPiece = piece.id
                        model.updatePreview()
                    }
                }
                if model.pieces.isEmpty {
                    Text("This problem has no pieces to export.").foregroundStyle(.secondary)
                }
                Text("Click a piece to preview it. Pieces used more than once are exported once; print them that many times.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var preview: some View {
        VStack(spacing: 0) {
            if let geo = model.previewMesh {
                let (scene, camera) = Self.scene(geo)
                SceneView(scene: scene, pointOfView: camera, options: [.allowsCameraControl])
            } else {
                VStack(spacing: 6) {
                    Text(model.previewError ?? "No piece selected").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let s = model.previewSize {
                Divider()
                Text("Printed piece: \(mm(Double(s.x))) × \(mm(Double(s.y))) × \(mm(Double(s.z)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    private static func scene(_ geo: SCNGeometry) -> (SCNScene, SCNNode) {
        // centre the piece on the origin so the camera frames it
        let node = SCNNode(geometry: geo)
        let (mn, mx) = node.boundingBox
        node.position = SCNVector3(-(mn.x + mx.x) / 2, -(mn.y + mx.y) / 2, -(mn.z + mx.z) / 2)
        let holder = SCNNode()
        holder.addChildNode(node)
        return makeScene(content: holder)
    }

    // MARK: helpers

    private func mmField(_ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
            Text("mm").foregroundStyle(.secondary)
        }
    }

    private func mm(_ v: Double) -> String {
        String(format: v >= 100 ? "%.1f mm" : "%.2f mm", v)
    }

    private func exportSelected() {
        let chosen = model.pieces.filter { model.selected.contains($0.id) }
        guard !chosen.isEmpty else { return }

        if chosen.count == 1 {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.init(filenameExtension: "stl") ?? .data]
            panel.nameFieldStringValue = model.fileName(for: chosen[0])
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if let err = model.export(chosen[0], to: url) {
                message.value = "Could not export \(chosen[0].name): \(err)"
            } else {
                dismiss()
            }
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the \(chosen.count) STL files."
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let existing = chosen.filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(model.fileName(for: $0)).path)
        }
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace \(existing.count) existing file\(existing.count == 1 ? "" : "s")?"
            alert.informativeText = existing.map { model.fileName(for: $0) }.joined(separator: "\n")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let errors = model.export(chosen, to: folder)
        if errors.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            dismiss()
        } else {
            message.value = "Some pieces could not be exported:\n" + errors.joined(separator: "\n")
        }
    }
}
