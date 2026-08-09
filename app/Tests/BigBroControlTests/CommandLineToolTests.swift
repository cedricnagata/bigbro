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

    // MARK: - Scopes

    func testTheTwoScopesPointWhereTheySay() {
        XCTAssertEqual(CommandLineTool.Scope.allTerminals.destination.path, "/usr/local/bin/bigbro")
        XCTAssertEqual(
            CommandLineTool.Scope.thisUser.destination.path,
            "\(NSHomeDirectory())/.local/bin/bigbro"
        )
    }

    /// The whole reason `/usr/local/bin` is the recommended scope: it is the first
    /// line of `/etc/paths`, so there is nothing to detect and nothing to warn about.
    func testOnlyTheAllTerminalsScopeNeedsAuthorization() {
        XCTAssertTrue(CommandLineTool.Scope.allTerminals.needsAuthorization)
        XCTAssertTrue(CommandLineTool.Scope.allTerminals.isAlwaysOnPath)

        XCTAssertFalse(CommandLineTool.Scope.thisUser.needsAuthorization)
        XCTAssertFalse(CommandLineTool.Scope.thisUser.isAlwaysOnPath)
    }

    @MainActor
    func testInstallingForThisUserRaisesNoAuthorization() throws {
        var authorized = false
        // Redirected to a temp path: a test must not install software into the
        // home directory of whoever is running it.
        let written = try CommandLineTool.install(
            into: .thisUser, at: destination, interpreter: interpreter,
            authorize: { _ in authorized = true }
        )

        XCTAssertFalse(authorized, "the unprivileged scope must never prompt")
        XCTAssertEqual(written, destination)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.path))
    }

    /// The privileged half is meant to be as small as it can be: stage the shim with
    /// no rights, then authorize three fixed commands that only move it into place.
    @MainActor
    func testInstallingForAllTerminalsAuthorizesOnlyMoveIntoPlace() throws {
        var command: String?
        _ = try CommandLineTool.install(
            into: .allTerminals, interpreter: interpreter, authorize: { command = $0 }
        )

        let authorized = try XCTUnwrap(command)
        XCTAssertTrue(authorized.contains("/bin/mkdir -p '/usr/local/bin'"))
        XCTAssertTrue(authorized.contains("/bin/cp "))
        XCTAssertTrue(authorized.contains("/bin/chmod 755 '/usr/local/bin/bigbro'"))
        // Nothing about the app's contents is decided while running as root.
        XCTAssertFalse(authorized.contains("python3"))
    }

    @MainActor
    func testAnUnauthorizedInstallInstallsNothing() {
        struct Denied: Error {}
        XCTAssertThrowsError(
            try CommandLineTool.install(
                into: .allTerminals, at: destination, interpreter: interpreter,
                authorize: { _ in throw Denied() }
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Quoting

    /// An app in a directory with a space or a quote in its name must not produce a
    /// command that runs as root and means something other than it reads.
    func testAwkwardPathsSurviveQuoting() {
        XCTAssertEqual(CommandLineTool.shellQuoted("/tmp/My Apps/x"), "'/tmp/My Apps/x'")
        XCTAssertEqual(CommandLineTool.shellQuoted("/tmp/it's"), "'/tmp/it'\\''s'")
        XCTAssertEqual(CommandLineTool.appleScriptQuoted("say \"hi\""), "say \\\"hi\\\"")
        XCTAssertEqual(CommandLineTool.appleScriptQuoted("back\\slash"), "back\\\\slash")
    }

    // MARK: - PATH

    /// A shim in a directory the shell never searches looks installed and behaves
    /// as though it is not, so the UI has to be able to tell the difference.
    func testPathDetectionForTheUserScope() {
        XCTAssertTrue(
            CommandLineTool.isOnPath(
                scope: .thisUser, pathProvider: { "/usr/bin:\(NSHomeDirectory())/.local/bin:/bin" }
            )
        )
        XCTAssertFalse(
            CommandLineTool.isOnPath(scope: .thisUser, pathProvider: { "/usr/bin:/bin" })
        )
        XCTAssertFalse(CommandLineTool.isOnPath(scope: .thisUser, pathProvider: { nil }))
    }

    /// `/usr/local/bin` is on PATH by virtue of `/etc/paths`, so this must not depend
    /// on what any particular shell reports — including a shell that reports nothing.
    func testTheAllTerminalsScopeIsOnPathWithoutAsking() {
        XCTAssertTrue(CommandLineTool.isOnPath(scope: .allTerminals, pathProvider: { nil }))
        XCTAssertTrue(CommandLineTool.isOnPath(scope: .allTerminals, pathProvider: { "/usr/bin" }))
    }

    /// The bug this replaced: a GUI app's own PATH comes from launchd and never
    /// sources a shell profile, so asking it reports `~/.local/bin` missing for
    /// someone who has had it on PATH for years.
    func testTheLoginShellIsWhatGetsAsked() {
        let path = CommandLineTool.loginShellPath(environment: ["SHELL": "/bin/zsh", "PATH": "/nope"])
        XCTAssertNotEqual(path, "/nope", "should have run the login shell, not read our own PATH")
    }

    func testLoginShellPathFallsBackWhenTheShellCannotStart() {
        let path = CommandLineTool.loginShellPath(
            environment: ["SHELL": "/nonexistent/shell", "PATH": "/usr/bin:/bin"]
        )
        XCTAssertEqual(path, "/usr/bin:/bin")
    }
}
