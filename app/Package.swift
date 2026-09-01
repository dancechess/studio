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
    name: "MacBaseDev",
    platforms: [.macOS(.v14)],
    targets: [
        // uniffi's C header (copied in by scripts/build-core.sh)
        .target(
            name: "macbase_coreFFI",
            path: "FFI",
            publicHeadersPath: "include"
        ),
        // the generated Swift bindings + the Rust static library
        .target(
            name: "MacBaseCore",
            dependencies: ["macbase_coreFFI"],
            path: "Generated",
            sources: ["macbase_core.swift"],
            linkerSettings: [
                .unsafeFlags(["-L\(rustLib)"]),
                .linkedLibrary("macbase_core"),
            ]
        ),
        // UCI engine subprocess management (pure Foundation, no UI)
        .target(name: "UCIKit", path: "UCIKit"),
        // end-to-end smoke checks:  swift run MacBaseSmoke
        .executableTarget(
            name: "MacBaseSmoke",
            dependencies: ["MacBaseCore", "UCIKit"],
            path: "Smoke"
        ),
        // the SwiftUI app, runnable without a bundle:  swift run MacBaseApp
        .executableTarget(
            name: "MacBaseApp",
            dependencies: ["MacBaseCore"],
            path: "MacBase"
        ),
    ]
)
