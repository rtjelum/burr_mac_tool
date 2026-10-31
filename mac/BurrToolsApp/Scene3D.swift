import AppKit
import Combine
import BurrCore
import SceneKit
import SwiftUI

/// Builds SceneKit geometry from meshes created by the C++ library.
enum MeshBuilder {
    static func geometry(_ mesh: UnsafeMutablePointer<BTMesh>, shape: Int, copy: Int) -> SCNGeometry {
        let m = mesh.pointee
        let vertexCount = Int(m.triangleCount) * 3
        let floatCount = vertexCount * 3

        let positions = Data(bytes: m.positions, count: floatCount * MemoryLayout<Float>.size)
        let normals = Data(bytes: m.normals, count: floatCount * MemoryLayout<Float>.size)
        let stride = 3 * MemoryLayout<Float>.size

        let vertexSource = SCNGeometrySource(data: positions, semantic: .vertex, vectorCount: vertexCount,
                                             usesFloatComponents: true, componentsPerVector: 3,
                                             bytesPerComponent: MemoryLayout<Float>.size,
                                             dataOffset: 0, dataStride: stride)
        let normalSource = SCNGeometrySource(data: normals, semantic: .normal, vectorCount: vertexCount,
                                             usesFloatComponents: true, componentsPerVector: 3,
                                             bytesPerComponent: MemoryLayout<Float>.size,
                                             dataOffset: 0, dataStride: stride)

        // group triangles by how they are coloured: light, dark, or "variable" marker
        var groups: [[Int32]] = [[], [], []]
        for t in 0..<Int(m.triangleCount) {
            let g = m.variable[t] != 0 ? 2 : (m.light[t] != 0 ? 0 : 1)
            let i = Int32(t * 3)
            groups[g].append(contentsOf: [i, i + 1, i + 2])
        }

        let base = PieceColors.color(shape: shape, copy: copy)
        let colors = [PieceColors.light(base), PieceColors.dark(base), (r: Float(0.15), g: Float(0.15), b: Float(0.15))]

        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        for (g, indices) in groups.enumerated() where !indices.isEmpty {
            elements.append(SCNGeometryElement(indices: indices, primitiveType: .triangles))
            let mat = SCNMaterial()
            let c = colors[g]
            mat.diffuse.contents = NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
            mat.specular.contents = NSColor(white: 0.25, alpha: 1)
            mat.lightingModel = .blinn
            mat.isDoubleSided = true
            materials.append(mat)
        }

        let geo = SCNGeometry(sources: [vertexSource, normalSource], elements: elements)
        geo.materials = materials
        return geo
    }
}

/// Creates a scene with lights and a camera that frames `content`.
func makeScene(content: SCNNode) -> (SCNScene, SCNNode) {
    let scene = SCNScene()
    scene.background.contents = NSColor.underPageBackgroundColor
    scene.rootNode.addChildNode(content)

    let ambient = SCNNode()
    ambient.light = SCNLight()
    ambient.light!.type = .ambient
    ambient.light!.color = NSColor(white: 0.45, alpha: 1)
    scene.rootNode.addChildNode(ambient)

    let (center, radius) = content.boundingSphere
    let r = max(Float(radius), 1)

    let camera = SCNNode()
    camera.camera = SCNCamera()
    camera.camera!.zNear = 0.1
    camera.camera!.zFar = Double(r) * 40
    camera.camera!.fieldOfView = 35
    let dir = simd_normalize(SIMD3<Float>(1.0, 0.9, 1.5))
    let c = SIMD3<Float>(Float(center.x), Float(center.y), Float(center.z))
    camera.simdPosition = c + dir * r * 3.4
    camera.simdLook(at: c)

    // a light attached to the camera, so the lit side always faces the viewer
    let key = SCNNode()
    key.light = SCNLight()
    key.light!.type = .directional
    key.light!.color = NSColor(white: 0.75, alpha: 1)
    key.simdEulerAngles = SIMD3<Float>(-0.35, 0.35, 0)
    camera.addChildNode(key)

    scene.rootNode.addChildNode(camera)
    return (scene, camera)
}

/// 3D view of a single shape.
struct ShapeSceneView: View {
    let document: PuzzleDocument
    let shape: Int
    let revision: Int

    var body: some View {
        let (scene, camera) = Self.build(document, shape)
        SceneView(scene: scene, pointOfView: camera, options: [.allowsCameraControl])
            .id("\(shape)-\(revision)")
            .overlay {
                if document.shape(shape).voxels == 0 {
                    Text("Empty shape").foregroundStyle(.secondary)
                }
            }
    }

    private static func build(_ doc: PuzzleDocument, _ shape: Int) -> (SCNScene, SCNNode) {
        let node = SCNNode()
        if let mesh = bt_shape_mesh(doc.puzzle, Int32(shape)) {
            node.geometry = MeshBuilder.geometry(mesh, shape: shape, copy: 0)
            bt_mesh_free(mesh)
        }
        return makeScene(content: node)
    }
}

/// Owns a C++ scene of one solution and moves the SceneKit nodes as the animation runs.
final class SolutionScene: ObservableObject {
    let scene: SCNScene
    let camera: SCNNode
    let steps: Int
    private let handle: OpaquePointer?
    private var nodes: [SCNNode?] = []

    init(document: PuzzleDocument, problem: Int, solution: Int) {
        handle = bt_scene_create(document.puzzle, Int32(problem), Int32(solution))
        let root = SCNNode()
        if let handle {
            steps = Int(bt_scene_steps(handle))
            for i in 0..<bt_scene_piece_count(handle) {
                guard let mesh = bt_scene_piece_mesh(handle, i) else {
                    nodes.append(nil)
                    continue
                }
                var shape: Int32 = 0, copy: Int32 = 0
                bt_scene_piece_info(handle, i, &shape, &copy)
                let node = SCNNode(geometry: MeshBuilder.geometry(mesh, shape: Int(shape), copy: Int(copy)))
                bt_mesh_free(mesh)
                root.addChildNode(node)
                nodes.append(node)
            }
        } else {
            steps = 0
        }
        // place the pieces in the assembled state first, so the camera frames the whole puzzle
        Self.place(handle, nodes, step: 0)
        (scene, camera) = makeScene(content: root)
        camera.camera?.zFar *= 2
    }

    deinit { bt_scene_free(handle) }

    func update(step: Double) {
        Self.place(handle, nodes, step: step)
    }

    private static func place(_ handle: OpaquePointer?, _ nodes: [SCNNode?], step: Double) {
        guard let handle else { return }
        bt_scene_set_step(handle, Float(step))
        for (i, node) in nodes.enumerated() {
            guard let node else { continue }
            var x: Float = 0, y: Float = 0, z: Float = 0, a: Float = 0
            bt_scene_piece_position(handle, Int32(i), &x, &y, &z, &a)
            node.simdPosition = SIMD3<Float>(x, y, z)
            node.opacity = CGFloat(a)
            node.isHidden = a <= 0.001
        }
    }
}

/// 3D view of a solution with the disassembly animation.
struct SolutionSceneView: View {
    @StateObject private var model: SolutionScene
    @StateObject private var step = ViewState<Double>(0.0)
    @StateObject private var playing = ViewState<Bool>(false)
    private let timer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    init(document: PuzzleDocument, problem: Int, solution: Int) {
        _model = StateObject(wrappedValue: SolutionScene(document: document, problem: problem, solution: solution))
    }

    var body: some View {
        VStack(spacing: 0) {
            SceneView(scene: model.scene, pointOfView: model.camera, options: [.allowsCameraControl])
            if model.steps > 0 {
                Divider()
                HStack(spacing: 12) {
                    Button {
                        if step.value >= Double(model.steps) { step.value = 0 }
                        playing.value.toggle()
                    } label: {
                        Image(systemName: playing.value ? "pause.fill" : "play.fill").frame(width: 16)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .help(playing.value ? "Pause" : "Play the disassembly")

                    Button {
                        playing.value = false
                        step.value = max(0, step.value == floor(step.value) ? step.value - 1 : floor(step.value))
                    } label: {
                        Image(systemName: "backward.frame.fill")
                    }
                    .help("Previous move")
                    Button { playing.value = false; step.value = min(Double(model.steps), floor(step.value) + 1) } label: {
                        Image(systemName: "forward.frame.fill")
                    }
                    .help("Next move")

                    Slider(value: $step.value, in: 0...Double(model.steps))
                    Text("Move \(Int(step.value.rounded(.down))) of \(model.steps)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 110, alignment: .trailing)
                }
                .padding(10)
            } else {
                Divider()
                Text("No disassembly stored for this solution.")
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
        .onChange(of: step.value) { _, newValue in model.update(step: newValue) }
        .onReceive(timer) { _ in
            guard playing.value else { return }
            let next = step.value + 1.0 / 30 * 1.5
            if next >= Double(model.steps) {
                step.value = Double(model.steps)
                playing.value = false
            } else {
                step.value = next
            }
        }
    }
}
