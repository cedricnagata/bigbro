import Foundation
import XCTest

@testable import BigBroControl

/// What the two buttons on a model row say, and whether they can be pressed.
///
/// The daemon reports state as prose, so these predicates are string reading, and
/// string reading is exactly the kind of thing that looks right and is not. Every
/// state the daemon can produce is covered: the six in `Daemon._STATE_RANK`, plus
/// the forms that carry a percentage or a message.
final class ModelActionTests: XCTestCase {
    private func model(_ state: String) throws -> ModelEntry {
        let json = """
            {"id": "m", "name": "M", "family": "language", "state": "\(state)",
             "sizeGB": 1.0, "tools": true, "images": false, "reasoning": "none",
             "memory": null}
            """
        return try JSONDecoder().decode(ModelEntry.self, from: Data(json.utf8))
    }

    func testNotDownloadedOffersADownloadAndNothingToStart() throws {
        let m = try model("not downloaded")
        XCTAssertFalse(m.hasWeights)
        XCTAssertFalse(m.canRunAction)                 // nothing to start
        XCTAssertFalse(m.weightsActionIsDelete)        // reads "Download"
        XCTAssertTrue(m.canWeightsAction)
    }

    func testDownloadedOffersStartAndDelete() throws {
        let m = try model("downloaded")
        XCTAssertTrue(m.hasWeights)
        XCTAssertTrue(m.canRunAction)
        XCTAssertFalse(m.runActionIsStop)              // reads "Start"
        XCTAssertTrue(m.weightsActionIsDelete)         // reads "Delete"
        XCTAssertTrue(m.canWeightsAction)
    }

    func testRunningOffersStopButNotDelete() throws {
        let m = try model("running")
        XCTAssertTrue(m.runActionIsStop)               // reads "Stop"
        XCTAssertTrue(m.canRunAction)
        // Deleting weights out from under a loaded model is not something to
        // offer casually — stop it first.
        XCTAssertFalse(m.canWeightsAction)
    }

    func testDownloadingDisablesBoth() throws {
        let m = try model("downloading 47%")
        XCTAssertFalse(m.hasWeights)                   // not on disk yet
        XCTAssertFalse(m.canRunAction)
        XCTAssertFalse(m.canWeightsAction)             // already in flight
    }

    func testStartingDisablesBoth() throws {
        let m = try model("starting")
        XCTAssertTrue(m.hasWeights)
        XCTAssertFalse(m.canRunAction)                 // already on its way
        XCTAssertFalse(m.canWeightsAction)
    }

    /// An error may or may not have left weights behind, so the row offers a
    /// retry rather than a delete for something that might not be there.
    func testErrorOffersADownloadRetry() throws {
        let m = try model("error: no space left on device")
        XCTAssertFalse(m.hasWeights)
        XCTAssertFalse(m.weightsActionIsDelete)        // reads "Download"
        XCTAssertTrue(m.canWeightsAction)
        XCTAssertFalse(m.canRunAction)
    }

    /// "downloading" and "downloaded" share a prefix in the other direction —
    /// `hasPrefix("downloaded")` must not match "downloading 12%".
    func testDownloadingIsNotMistakenForDownloaded() throws {
        XCTAssertFalse(try model("downloading 12%").hasWeights)
        XCTAssertTrue(try model("downloaded").hasWeights)
    }

    /// The invariant worth stating across every state the daemon can report:
    /// weights are never deletable while a model is loaded or loading. Getting
    /// this wrong pulls a file out from under MLX rather than showing a bad label.
    func testWeightsAreNeverDeletableWhileLoaded() throws {
        for state in [
            "running", "starting", "downloading 1%", "downloaded",
            "error: something", "not downloaded",
        ] {
            let m = try model(state)
            if m.isRunning || m.isStarting {
                XCTAssertFalse(m.canWeightsAction, "should not offer to delete while \(state)")
            }
        }
    }

    /// And its mirror: a start is never offered for something that is not there.
    func testStartIsNeverOfferedWithoutWeights() throws {
        for state in ["downloading 1%", "error: something", "not downloaded"] {
            let m = try model(state)
            XCTAssertFalse(m.canRunAction, "should not offer to start while \(state)")
        }
    }
}
