import BurrCore
import Foundation

/// Converts a malloc'ed C string from the bridge into a Swift string and frees it.
func takeString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    defer { bt_free(ptr) }
    return String(cString: ptr)
}

struct BurrError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum GridType: Int, CaseIterable, Identifiable {
    case bricks = 0, triangularPrism, spheres, rhombic, tetraOcta

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .bricks: return "Cubes"
        case .triangularPrism: return "Triangular prisms"
        case .spheres: return "Spheres"
        case .rhombic: return "Rhombic"
        case .tetraOcta: return "Tetra-octa"
        }
    }
}

struct ShapeInfo: Identifiable, Hashable {
    let id: Int
    let name: String
    let size: (x: Int, y: Int, z: Int)
    let voxels: Int

    var displayName: String { name.isEmpty ? "S\(id + 1)" : "S\(id + 1) – \(name)" }

    static func == (a: ShapeInfo, b: ShapeInfo) -> Bool {
        a.id == b.id && a.name == b.name && a.voxels == b.voxels
            && a.size.x == b.size.x && a.size.y == b.size.y && a.size.z == b.size.z
    }

    func hash(into h: inout Hasher) { h.combine(id) }
}

struct ProblemInfo: Identifiable, Hashable {
    let id: Int
    let name: String
    var displayName: String { name.isEmpty ? "Problem \(id + 1)" : name }
}

struct SolutionInfo: Identifiable, Hashable {
    let id: Int
    let number: Int
    let assemblyNumber: Int
    let moves: Int
    let movesText: String?

    var title: String {
        var t = "Solution \(id + 1)"
        if moves >= 0 {
            t += " · \(moves) moves"
            if let movesText, !movesText.isEmpty { t += " (\(movesText))" }
        }
        return t
    }
}

/// Piece colours, ported from src/gui/piececolor.cpp so pieces look like they did in the old app.
enum PieceColors {
    private static let r: [Float] = [0, 0, 1, 0, 1, 1, 0, 0, 0.6, 0, 0.6, 0.6, 0, 0.6, 0, 0.6, 1, 1]
    private static let g: [Float] = [0, 1, 0, 1, 1, 0, 0, 0.6, 0, 0.6, 0.6, 0, 1, 1, 0.6, 0, 0.6, 0]
    private static let b: [Float] = [1, 0, 0, 1, 0, 1, 0.6, 0, 0, 0.6, 0, 0.6, 0.6, 0, 1, 1, 0, 0.6]

    private static let jr: [Float] = [
        0, -0.3, 0.3, -0.3, 0.3, -0.3, 0.3, -0.3, 0.3, 0.3, -0.3, -0.3, 0.3, 0.3, -0.3, -0.3, 0.3, 0, 0,
        0, 0, 0, 0, 0, 0, 0.3, -0.3, -0.4, 0.4, -0.4, 0.4, -0.4, 0.4, -0.4, 0.4, 0.4, -0.4, -0.4, 0.4, 0.4,
        -0.4, -0.4, 0.4, 0, 0, 0, 0, 0, 0, 0, 0, 0.4, -0.4,
    ]
    private static let jg: [Float] = [
        0, -0.3, 0.3, 0.3, -0.3, -0.3, 0.3, 0.3, -0.3, 0.3, -0.3, 0.3, -0.3, 0, 0, 0, 0, 0.3, -0.3,
        -0.3, 0.3, 0, 0, 0.3, -0.3, 0, 0, -0.4, 0.4, 0.4, -0.4, -0.4, 0.4, 0.4, -0.4, 0.4, -0.4, 0.4, -0.4, 0,
        0, 0, 0, 0.4, -0.4, -0.4, 0.4, 0, 0, 0.4, -0.4, 0, 0,
    ]
    private static let jb: [Float] = [
        0, -0.3, 0.3, 0.3, -0.3, 0.3, -0.3, -0.3, 0.3, 0, 0, 0, 0, 0.3, -0.3, 0.3, -0.3, 0.3, -0.3,
        0.3, -0.3, 0.3, -0.3, 0, 0, 0, 0, -0.4, 0.4, 0.4, -0.4, 0.4, -0.4, -0.4, 0.4, 0, 0, 0, 0, 0.4,
        -0.4, 0.4, -0.4, 0.4, -0.4, 0.4, -0.4, 0.4, -0.4, 0, 0, 0, 0,
    ]

    private static func base(_ x: Int) -> (Float, Float, Float) {
        if x < r.count { return (r[x], g[x], b[x]) }
        let f = Double(x)
        return (Float((1 + sin(0.7 * f)) / 2), Float((1 + sin(1.3 * f + 1.5)) / 2), Float((1 + sin(3.5 * f + 2.3)) / 2))
    }

    private static func jitterIndex(_ x: Int, _ sub: Int) -> Int {
        let (br, bg, bb) = base(x)
        var sub = sub
        var j = 0
        while j < jr.count {
            let ok = (0...1).contains(br + jr[j]) && (0...1).contains(bg + jg[j]) && (0...1).contains(bb + jb[j])
            if ok {
                if sub == 0 { break }
                sub -= 1
            }
            j += 1
        }
        return j == jr.count ? 0 : j
    }

    private static func ramp(_ v: Float) -> Float { 0.5 + 0.5 * abs(1 - 2 * v) }

    /// Colour of copy `copy` of shape `shape`, components in 0...1.
    static func color(shape: Int, copy: Int = 0) -> (r: Float, g: Float, b: Float) {
        let (br, bg, bb) = base(shape)
        let j = jitterIndex(shape, copy)
        func clamp(_ v: Float) -> Float { min(1, max(0, v)) }
        return (clamp(br + jr[j] * 0.5 * ramp(br)),
                clamp(bg + jg[j] * 0.4 * ramp(bg)),
                clamp(bb + jb[j] * 0.7 * ramp(bb)))
    }

    static func light(_ c: (r: Float, g: Float, b: Float)) -> (r: Float, g: Float, b: Float) {
        (1 - 0.9 * (1 - c.r), 1 - 0.9 * (1 - c.g), 1 - 0.9 * (1 - c.b))
    }

    static func dark(_ c: (r: Float, g: Float, b: Float)) -> (r: Float, g: Float, b: Float) {
        (c.r * 0.9, c.g * 0.9, c.b * 0.9)
    }
}

/// Holds a piece of view state.
///
/// Used instead of SwiftUI's `@State`, which in recent SDKs is a compiler macro
/// that only builds with full Xcode. This keeps the app buildable with just the
/// Command Line Tools (`swift build`).
final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
