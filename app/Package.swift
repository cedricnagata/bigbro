// swift-tools-version: 5.9
import PackageDescription

// SwiftPM rather than an .xcodeproj: `swift build` and `swift test` run on a bare
// runner with no project file to keep in sync, and a .pbxproj is merge-hostile in
// a repo whose build story is otherwise just hatchling and uv.
//
// BigBroControl deliberately links no SwiftUI. Everything that decides *what* the
// dashboard shows lives here, so it can be tested without a window server — and
// so the app target is left with nothing but presentation.
let package = Package(
    name: "BigBro",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BigBroControl", targets: ["BigBroControl"]),
        .executable(name: "BigBroApp", targets: ["BigBroApp"])
    ],
    targets: [
        .target(name: "BigBroControl"),
        // Produces a bare Mach-O, not a bundle. `Scripts/make-app.sh` assembles
        // BigBro.app around it — macOS decides what is an app by layout, so a
        // binary at Contents/MacOS with an Info.plist beside it behaves normally.
        .executableTarget(name: "BigBroApp", dependencies: ["BigBroControl"]),
        .testTarget(name: "BigBroControlTests", dependencies: ["BigBroControl"])
    ]
)
