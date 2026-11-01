// swift-tools-version:5.9
//
// Native macOS app for BurrTools, written in SwiftUI.
// The puzzle solver is the original C++ library in src/, built as the
// BurrCore target and called through a small C bridge (src/bridge).
//
// Build:   swift build -c release
// App:     mac/build-app.sh   (creates build/BurrTools.app)

import PackageDescription

let package = Package(
    name: "BurrTools",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BurrTools", targets: ["BurrToolsApp"]),
    ],
    targets: [
        .target(
            name: "BurrCore",
            path: "src",
            exclude: [
                "lib/tabs_0", "lib/tabs_1", "lib/tabs_2", "lib/tabs_3", "lib/tabs_4",
            ],
            sources: [
                "lib",
                "halfedge",
                "tools/fileexists.cpp", "tools/gzstream.cpp", "tools/xml.cpp",
                "bridge/burrbridge.cpp", "bridge/generator.cpp",
            ],
            publicHeadersPath: "bridge/include",
            cxxSettings: [
                .unsafeFlags(["-w"]),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
        .executableTarget(
            name: "BurrToolsApp",
            dependencies: ["BurrCore"],
            path: "mac/BurrToolsApp"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
