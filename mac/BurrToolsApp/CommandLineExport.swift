import BurrCore
import Foundation

/// Command line GIF export, a built-in replacement for scripts/burr2gif.py:
///
///   BurrTools.app/Contents/MacOS/BurrTools --export-gif puzzle.xmpuzzle out.gif
///       [--problem N] [--solution N] [--size PIXELS] [--frames-per-move N]
///       [--move-time SECONDS] [--camera follow|fixed|orbit] [--colors vibrant|toy|burrtools]
///       [--background dark|light|white] [--style classic|studio] [--solve]
///
/// The output is an MP4 video if its name ends in .mp4, a single PNG image if it
/// ends in .png (pick the frame with --frame N, counting from 0), otherwise a GIF.
///
/// Problem and solution numbers start at 1. With --solve, the problem is solved
/// again first (with disassembly), for files whose solutions have no moves stored.
enum CommandLineExport {
    static func run(_ args: [String]) -> Int32 {
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let i = args.firstIndex(of: "--export-gif"), i + 2 < args.count else {
            fputs("usage: BurrTools --export-gif puzzle.xmpuzzle out.gif [options]\n", stderr)
            return 2
        }
        let input = URL(fileURLWithPath: args[i + 1])
        let output = URL(fileURLWithPath: args[i + 2])
        let problem = (Int(value("--problem") ?? "1") ?? 1) - 1
        let solution = (Int(value("--solution") ?? "1") ?? 1) - 1

        var options = GifOptions()
        if value("--style") == "studio" { options.applyDefaults(for: .studio) }
        options.stillFrame = value("--frame").flatMap(Int.init)
        if let v = value("--size").flatMap(Int.init) { options.size = v }
        if let v = value("--frames-per-move").flatMap(Int.init) { options.framesPerMove = v }
        if let v = value("--move-time").flatMap(Double.init) { options.moveTime = v }
        switch value("--camera") {
        case "fixed": options.camera = .fixed
        case "orbit": options.camera = .orbit
        default: break
        }
        switch value("--colors") {
        case "burrtools": options.colors = .burrTools
        case "vibrant": options.colors = .vibrant
        case "toy": options.colors = .toy
        default: break
        }
        switch value("--background") {
        case "light": options.background = .light
        case "white": options.background = .white
        default: break
        }

        do {
            let doc = try PuzzleDocument(contentsOf: input)
            guard problem >= 0, problem < doc.problems.count else {
                fputs("error: the puzzle has \(doc.problems.count) problem(s)\n", stderr)
                return 1
            }
            if args.contains("--solve") {
                fputs("solving…\n", stderr)
                var opts = SolveOptions()
                opts.disassemble = doc.canDisassemble
                doc.startSolving(problem: problem, options: opts, fromStart: true, undo: nil)
                while doc.isSolving { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
                if let e = doc.lastError { fputs("error: \(e)\n", stderr); return 1 }
            }
            let count = doc.solutions(problem).count
            guard solution >= 0, solution < count else {
                fputs("error: problem \(problem + 1) has \(count) stored solution(s); use --solve to solve it first\n", stderr)
                return 1
            }
            let renderer = GifRenderer(document: doc, problem: problem, solution: solution, options: options)
            fputs("rendering \(renderer.frameCount) frames (\(renderer.steps) moves)…\n", stderr)
            try renderer.write(to: output) { _ in true }
            fputs("saved \(output.path)\n", stderr)
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
