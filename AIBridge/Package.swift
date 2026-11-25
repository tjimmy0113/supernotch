// swift-tools-version: 5.9
// CodeIslandBridge: the hook bridge binary invoked by Claude Code / Codex hooks.
// Built and embedded into SuperNotch.app/Contents/Helpers/ by the
// "Embed AI Bridge" Run Script build phase of the boringNotch target.
import PackageDescription

let package = Package(
    name: "AIBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodeIslandBridge", targets: ["CodeIslandBridge"]),
    ],
    targets: [
        .executableTarget(
            name: "CodeIslandBridge",
            path: "Sources/CodeIslandBridge"
        ),
    ]
)
