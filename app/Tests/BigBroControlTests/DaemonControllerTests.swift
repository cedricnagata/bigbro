import Foundation
import XCTest

@testable import BigBroControl

/// Which daemon the app decides to run.
///
/// The ordering here is the difference between a DMG that works on a machine with
/// no Python and one that silently runs a different, older daemon the developer
/// happened to have installed.
final class DaemonLaunchTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: "/tmp/bb-launch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The interpreter is invoked as `python3 -m bigbro`, never through a console
    /// script — a generated script carries an absolute shebang from the machine
    /// that built it, which is exactly what a relocated bundle breaks.
    func testTheBundledRuntimeIsPreferredAndInvokedAsAModule() throws {
        let python = directory.appendingPathComponent("python/bin/python3")
        try makeExecutable(python)

        let launch = DaemonController.resolveLaunch(
            resources: directory, environment: [:], pathCandidates: []
        )

        XCTAssertEqual(launch?.executable, python.path)
        XCTAssertEqual(launch?.arguments, ["-m", "bigbro", "serve", "--no-ui"])
    }

    func testAnInstalledCLIIsUsedWhenNothingIsBundled() throws {
        let cli = directory.appendingPathComponent("bin/bigbro")
        try makeExecutable(cli)

        let launch = DaemonController.resolveLaunch(
            resources: nil, environment: [:], pathCandidates: [cli.path]
        )

        XCTAssertEqual(launch?.executable, cli.path)
        XCTAssertEqual(launch?.arguments, ["serve", "--no-ui"])
    }

    func testTheBundleWinsOverAnInstalledCLI() throws {
        let python = directory.appendingPathComponent("python/bin/python3")
        let cli = directory.appendingPathComponent("bin/bigbro")
        try makeExecutable(python)
        try makeExecutable(cli)

        let launch = DaemonController.resolveLaunch(
            resources: directory, environment: [:], pathCandidates: [cli.path]
        )

        // Otherwise a developer's older `uv tool install`ed daemon would quietly
        // shadow the one that shipped inside the app.
        XCTAssertEqual(launch?.executable, python.path)
    }

    func testTheEnvironmentOverrideBeatsEverything() throws {
        let python = directory.appendingPathComponent("python/bin/python3")
        try makeExecutable(python)

        let launch = DaemonController.resolveLaunch(
            resources: directory,
            environment: ["BIGBRO_DAEMON_COMMAND": "/usr/bin/env bigbro"],
            pathCandidates: []
        )

        XCTAssertEqual(launch?.executable, "/usr/bin/env")
        XCTAssertEqual(launch?.arguments, ["bigbro", "serve", "--no-ui"])
    }

    func testNothingToRunIsReportedRatherThanGuessed() {
        let launch = DaemonController.resolveLaunch(
            resources: nil, environment: [:], pathCandidates: ["/nope/bigbro"]
        )
        XCTAssertNil(launch)
    }

    /// `serve --no-ui` is always passed, never inferred from a tty check.
    func testServeIsAlwaysHeadless() throws {
        let python = directory.appendingPathComponent("python/bin/python3")
        try makeExecutable(python)

        let launch = DaemonController.resolveLaunch(
            resources: directory, environment: [:], pathCandidates: []
        )

        XCTAssertEqual(launch?.arguments.suffix(2), ["serve", "--no-ui"])
    }
}
