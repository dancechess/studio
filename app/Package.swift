// swift-tools-version:5.10
// SPM dev harness: lets us build and smoke-test the Swift side with only the
// Command Line Tools (no Xcode). The shipping app is still the XcodeGen
// project (project.yml); targets here mirror its source layout.
import PackageDescription
import Foundation

// absolute path to the Rust build products, derived from this file's location
let pkgDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let rustLib = "\(pkgDir)/../core/target/release"

let package = Package(
    name: "DanceChessStudio",
    platforms: [.macOS(.v14)],
    targets: [
        // uniffi's C header (copied in by scripts/build-core.sh)
        .target(
            name: "dancechess_coreFFI",
            path: "FFI",
            publicHeadersPath: "include"
        ),
        // the generated Swift bindings + the Rust static library
        .target(
            name: "DanceChessCore",
            dependencies: ["dancechess_coreFFI"],
            path: "Generated",
            sources: ["dancechess_core.swift"],
            linkerSettings: [
                // The archive by path, not -ldancechess_core: cargo emits both
                // a .a and a .dylib, ld picks the .dylib, and records it by
                // its absolute path in this build directory — an app that
                // launches on the machine that built it and nowhere else.
                // (Hardened runtime then refuses it even here, because the
                // dylib carries no Team ID. That is how this was found.)
                .unsafeFlags(["\(rustLib)/libdancechess_core.a"]),
            ]
        ),
        // UCI engine subprocess management (pure Foundation, no UI)
        .target(name: "UCIKit", path: "UCIKit"),
        // end-to-end smoke checks:  swift run StudioSmoke
        .executableTarget(
            name: "StudioSmoke",
            dependencies: ["DanceChessCore", "UCIKit"],
            path: "Smoke"
        ),
        // the SwiftUI app, runnable without a bundle:  swift run StudioApp
        .executableTarget(
            name: "StudioApp",
            dependencies: ["DanceChessCore", "UCIKit"],
            path: "Studio",
            resources: [.copy("Resources/pieces")]
        ),
    ]
)
