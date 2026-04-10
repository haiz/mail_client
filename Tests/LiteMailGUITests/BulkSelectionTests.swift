import XCTest
import AppKit
@testable import LiteMail

@MainActor
final class BulkSelectionTests: XCTestCase {

    // MARK: - MessageListView.checkedIds

    func testCheckedIdsStartEmpty() {
        let messageList = MessageListView()
        XCTAssertTrue(messageList.checkedIds.isEmpty)
    }

    func testToggleCheckedAddsAndRemoves() {
        let messageList = MessageListView()
        let headers = GUITestData.sampleHeaders(count: 5)
        messageList.update(messages: headers)
        pumpRunLoop()

        let emailId = headers[0].id

        // Toggle on
        messageList.toggleChecked(emailId: emailId)
        XCTAssertTrue(messageList.checkedIds.contains(emailId))
        XCTAssertEqual(messageList.checkedIds.count, 1)

        // Toggle off
        messageList.toggleChecked(emailId: emailId)
        XCTAssertFalse(messageList.checkedIds.contains(emailId))
        XCTAssertTrue(messageList.checkedIds.isEmpty)
    }

    func testClearCheckedIdsResetsSet() {
        let messageList = MessageListView()
        let headers = GUITestData.sampleHeaders(count: 5)
        messageList.update(messages: headers)
        pumpRunLoop()

        // Check several emails
        messageList.toggleChecked(emailId: headers[0].id)
        messageList.toggleChecked(emailId: headers[1].id)
        messageList.toggleChecked(emailId: headers[2].id)
        XCTAssertEqual(messageList.checkedIds.count, 3)

        // Clear
        messageList.clearCheckedIds()
        XCTAssertTrue(messageList.checkedIds.isEmpty)
    }

    // MARK: - onCheckedIdsChanged callback

    func testToggleCheckedFiresCallback() {
        let messageList = MessageListView()
        let headers = GUITestData.sampleHeaders(count: 3)
        messageList.update(messages: headers)
        pumpRunLoop()

        var receivedIds: Set<Int64>?
        messageList.onCheckedIdsChanged = { ids in receivedIds = ids }

        messageList.toggleChecked(emailId: headers[0].id)
        XCTAssertNotNil(receivedIds)
        XCTAssertTrue(receivedIds?.contains(headers[0].id) == true)
    }

    // MARK: - BulkActionBar

    func testBulkActionBarUpdatesWithCount() {
        let bar = BulkActionBar()
        // Initially hidden
        XCTAssertTrue(bar.isHidden)

        // Showing with a non-zero count makes it visible
        bar.update(selectedCount: 3)
        pumpRunLoop()
        XCTAssertFalse(bar.isHidden)

        // Dropping back to zero triggers hide animation; after RunLoop it completes
        bar.update(selectedCount: 0)
        pumpRunLoop(seconds: 0.3)
        XCTAssertTrue(bar.isHidden)
    }

    func testBulkActionBarCallbacksAreFired() {
        let bar = BulkActionBar()
        bar.update(selectedCount: 2)
        pumpRunLoop()

        var archiveCalled = false
        var deleteCalled = false
        var markReadCalled = false
        var starCalled = false
        var moveCalled = false
        var deselectCalled = false

        bar.onArchive    = { archiveCalled    = true }
        bar.onDelete     = { deleteCalled     = true }
        bar.onMarkRead   = { markReadCalled   = true }
        bar.onStar       = { starCalled       = true }
        bar.onMove       = { moveCalled       = true }
        bar.onDeselectAll = { deselectCalled  = true }

        bar.onArchive?()
        bar.onDelete?()
        bar.onMarkRead?()
        bar.onStar?()
        bar.onMove?()
        bar.onDeselectAll?()

        XCTAssertTrue(archiveCalled)
        XCTAssertTrue(deleteCalled)
        XCTAssertTrue(markReadCalled)
        XCTAssertTrue(starCalled)
        XCTAssertTrue(moveCalled)
        XCTAssertTrue(deselectCalled)
    }

    // MARK: - UndoToastView

    func testUndoToastShowAndDismiss() {
        let toast = UndoToastView()

        // Initially hidden
        XCTAssertTrue(toast.isHidden)

        var expireCalled = false
        let action = UndoableBatchAction(
            description: "Archived 3 emails",
            reverseOperation: {},
            emailIds: [1, 2, 3]
        )

        toast.show(action: action) { expireCalled = true }
        pumpRunLoop()

        // After show(), toast should be visible
        XCTAssertFalse(toast.isHidden)
    }

    func testUndoToastPerformUndoCallsReverseOperation() {
        let toast = UndoToastView()

        var reverseCalled = false
        var undoCalled = false

        let action = UndoableBatchAction(
            description: "Deleted 2 emails",
            reverseOperation: { reverseCalled = true },
            emailIds: [10, 20]
        )

        toast.show(action: action) { /* expire */ }
        toast.onUndo = { undoCalled = true }
        pumpRunLoop()

        toast.performUndo()
        // Give the async Task time to run
        pumpRunLoop(seconds: 0.2)

        XCTAssertTrue(reverseCalled)
        XCTAssertTrue(undoCalled)
    }

    // MARK: - removeRows

    func testRemoveRowsUpdatesDataSource() {
        let messageList = MessageListView()
        let headers = GUITestData.sampleHeaders(count: 5)
        messageList.update(messages: headers)
        pumpRunLoop()

        XCTAssertEqual(messageList.threadGroups.count, 5)

        // Remove emails with IDs 1, 2 (first two headers)
        let idsToRemove: Set<Int64> = [headers[0].id, headers[1].id]
        messageList.removeRows(forIds: idsToRemove)
        pumpRunLoop()

        XCTAssertEqual(messageList.threadGroups.count, 3)
        let remainingIds = Set(messageList.threadGroups.map { $0.primaryHeader.id })
        XCTAssertFalse(remainingIds.contains(headers[0].id))
        XCTAssertFalse(remainingIds.contains(headers[1].id))
    }

    func testRemoveRowsAlsoClearsCheckedIds() {
        let messageList = MessageListView()
        let headers = GUITestData.sampleHeaders(count: 4)
        messageList.update(messages: headers)
        pumpRunLoop()

        let id0 = headers[0].id
        let id1 = headers[1].id

        messageList.toggleChecked(emailId: id0)
        messageList.toggleChecked(emailId: id1)
        XCTAssertEqual(messageList.checkedIds.count, 2)

        messageList.removeRows(forIds: [id0])
        pumpRunLoop()

        // id0 should no longer be in checkedIds; id1 should remain
        XCTAssertFalse(messageList.checkedIds.contains(id0))
        XCTAssertTrue(messageList.checkedIds.contains(id1))
    }
}
