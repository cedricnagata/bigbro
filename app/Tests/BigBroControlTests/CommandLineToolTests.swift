import Foundation
import XCTest

@testable import BigBroControl

final class CommandLineToolTests: XCTestCase {
    private var directory: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: "/tmp/bb-cli-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        destination = directory.appendingPathComponent("bin/bigbro")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private let interpreter = "/Applications/BigBro.app/Contents/Resources/python/bin/python3"

    func testTheShimRunsTheBundledInterpreterAsAModule() throws {
        try CommandLineTool.install(at: destination, interpreter: interpreter)

        let script = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        // `-m bigbro`, not a console script: a generated script carries an
        // absolute shebang from the machine that built the wheel.
        XCTAssertTrue(script.contains("exec \"\(interpreter)\" -m bigbro \"$@\""))
    }

    func testTheShimIsExecutable() throws {
        try CommandLineTool.install(at: destination, interpreter: interpreter)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.path))
    }

    func testInstallingCreatesTheDirectory() throws {
        // ~/.local/bin does not exist on a clean machine.
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        try CommandLineTool.install(at: destination, interpreter: interpreter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testStatusIsNotInstalledWhenNothingIsThere() {
        XCTAssertEqual(
            CommandLineTool.status(at: destination, interpreter: interpreter),
            .notInstalled
        )
    }

    func testStatusIsCurrentWhenItPointsAtThisApp() throws {
        try CommandLineTool.install(at: destination, interpreter: interpreter)
        XCTAssertEqual(
            CommandLineTool.status(at: destination, interpreter: interpreter),
            .current
        )
    }

    /// Someone drags BigBro from Downloads to Applications and the shim keeps
    /// pointing at a path that no longer exists. Saying "repair" beats leaving
    /// them with a `bigbro` that fails in a way they cannot read.
    func testAShimPointingSomewhereElseIsStale() throws {
        try CommandLineTool.install(
            at: destination,
            interpreter: "/Users/someone/Downloads/BigBro.app/Contents/Resources/python/bin/python3"
        )

        let status = CommandLineTool.status(at: destination, interpreter: interpreter)
        guard case .stale(let pointingAt) = status else {
            return XCTFail("expected stale, got \(status)")
        }
        XCTAssertTrue(pointingAt.contains("Downloads"))
    }

    func testReinstallingOverAStaleShimRepairsIt() throws {
        try CommandLineTool.install(at: destination, interpreter: "/old/python3")
        try CommandLineTool.install(at: destination, interpreter: interpreter)

        XCTAssertEqual(
            CommandLineTool.status(at: destination, interpreter: interpreter),
            .current
        )
    }

    func testInstallingWithNoBundledRuntimeFails() {
        // A `swift run` build has no Python inside it to point at.
        XCTAssertThrowsError(try CommandLineTool.install(at: destination, interpreter: nil))
    }

    /// A shim in a directory the shell never searches looks installed and behaves
    /// as though it is not, so the UI has to be able to tell the difference.
    func testPathDetection() {
        let onPath = CommandLineTool.destinationIsOnPath(
            environment: ["PATH": "/usr/bin:\(NSHomeDirectory())/.local/bin:/bin"]
        )
        XCTAssertTrue(onPath)

        XCTAssertFalse(CommandLineTool.destinationIsOnPath(environment: ["PATH": "/usr/bin:/bin"]))
        XCTAssertFalse(CommandLineTool.destinationIsOnPath(environment: [:]))
    }
}
