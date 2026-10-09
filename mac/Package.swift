// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "understudy",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // What the host and the control app share: effects.json's schema.
        .target(name: "UnderstudyShared"),
        // The CMIO camera extension: the virtual camera apps actually open.
        // Sandboxed and deliberately dumb; it serves frames and draws the
        // fallback card, nothing more.
        .executableTarget(name: "understudy-camera"),
        // The host app: installs the extension, and (from Phase 1) owns the
        // real Cam Link session and the uhubctl bounce.
        .executableTarget(name: "understudy", dependencies: ["UnderstudyShared"]),
    ]
)
