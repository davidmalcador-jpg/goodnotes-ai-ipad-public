import XCTest
@testable import NoteAssistant

final class AttachmentExportStateTests: XCTestCase {
    func testSavedDelegateBeforeSheetDismissalRemainsSaved() throws {
        var state = AttachmentExportState()
        let id = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.complete(.saved, attemptID: id))
        XCTAssertTrue(state.isPresented)
        XCTAssertNil(state.begin())
        XCTAssertFalse(state.dismiss())
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.result, .saved)
    }

    func testSheetDismissalBeforeSavedDelegateAcceptsActualSave() throws {
        var state = AttachmentExportState()
        let id = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.dismiss())
        XCTAssertEqual(state.result, .unconfirmed)
        XCTAssertFalse(state.isPresented)
        XCTAssertTrue(state.complete(.saved, attemptID: id))
        XCTAssertEqual(state.result, .saved)
    }

    func testCancelledDelegateBeforeSheetDismissalRemainsCancelled() throws {
        var state = AttachmentExportState()
        let id = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.complete(.cancelled, attemptID: id))
        XCTAssertNil(state.begin())
        XCTAssertFalse(state.dismiss())
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.result, .cancelled)
    }

    func testSheetDismissalBeforeCancelledDelegateAcceptsActualCancellation() throws {
        var state = AttachmentExportState()
        let id = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.dismiss())
        XCTAssertEqual(state.result, .unconfirmed)
        XCTAssertTrue(state.complete(.cancelled, attemptID: id))
        XCTAssertEqual(state.result, .cancelled)
    }

    func testSheetDismissalWithoutDelegateDoesNotClaimCancellation() throws {
        var state = AttachmentExportState()
        _ = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.dismiss())
        XCTAssertEqual(state.result, .unconfirmed)
        XCTAssertFalse(state.dismiss())
        XCTAssertNotNil(state.begin())
        XCTAssertNil(state.result)
    }

    func testLateDelegateFromDismissedAttemptCannotChangeRetry() throws {
        var state = AttachmentExportState()
        let oldID = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.dismiss())
        let retryID = try XCTUnwrap(state.begin())
        XCTAssertNotEqual(retryID, oldID)
        XCTAssertFalse(state.complete(.saved, attemptID: oldID))
        XCTAssertFalse(state.complete(.cancelled, attemptID: oldID))
        XCTAssertTrue(state.isPresented)
        XCTAssertNil(state.result)
        XCTAssertTrue(state.complete(.saved, attemptID: retryID))
    }

    func testDefinitiveDelegateResultCannotBeOverwrittenByOtherCallbacks() throws {
        for result in [AttachmentExportResult.saved, .cancelled] {
            var state = AttachmentExportState()
            let id = try XCTUnwrap(state.begin())
            XCTAssertTrue(state.complete(result, attemptID: id))
            XCTAssertFalse(state.complete(.unconfirmed, attemptID: id))
            XCTAssertFalse(state.complete(.saved, attemptID: id))
            XCTAssertFalse(state.complete(.cancelled, attemptID: id))
            XCTAssertFalse(state.dismiss())
            XCTAssertEqual(state.result, result)
        }
    }

    func testUnconfirmedDelegateCanBeFollowedBySavedDelegate() throws {
        var state = AttachmentExportState()
        let id = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.complete(.unconfirmed, attemptID: id))
        XCTAssertFalse(state.dismiss())
        XCTAssertTrue(state.complete(.saved, attemptID: id))
        XCTAssertEqual(state.result, .saved)
    }
}
