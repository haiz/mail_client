import XCTest
import AppKit
@testable import LiteMail

@MainActor
final class SidebarTests: XCTestCase {

    func testSidebarShowsAccounts() {
        let sidebar = SidebarView()
        sidebar.setAccounts([
            (id: "acc1", email: "user1@test.com"),
            (id: "acc2", email: "user2@test.com"),
        ], activeId: "acc1")
        pumpRunLoop()

        XCTAssertNotNil(sidebar.view)
        XCTAssertGreaterThan(sidebar.view.subviews.count, 0)
    }

    func testSelectFolderCallback() {
        let sidebar = SidebarView()
        sidebar.setAccounts([(id: "acc1", email: "test@test.com")], activeId: "acc1")
        sidebar.updateFolders(GUITestData.sampleFolders)
        pumpRunLoop()

        var selectedFolder: (String, String)?
        sidebar.onFolderSelected = { accountId, folder in
            selectedFolder = (accountId, folder)
        }

        sidebar.onFolderSelected?("acc1", "INBOX")

        XCTAssertEqual(selectedFolder?.0, "acc1")
        XCTAssertEqual(selectedFolder?.1, "INBOX")
    }

    func testComposeButtonCallback() {
        let sidebar = SidebarView()
        pumpRunLoop()

        var composeCalled = false
        sidebar.onCompose = { composeCalled = true }

        sidebar.onCompose?()
        XCTAssertTrue(composeCalled)
    }

    func testRefreshButtonCallback() {
        let sidebar = SidebarView()
        pumpRunLoop()

        var refreshCalled = false
        sidebar.onRefresh = { refreshCalled = true }

        sidebar.onRefresh?()
        XCTAssertTrue(refreshCalled)
    }

    func testAuthErrorCallback() {
        let sidebar = SidebarView()
        sidebar.setAccounts([(id: "acc1", email: "test@test.com")], activeId: "acc1")
        pumpRunLoop()

        sidebar.setAuthError(for: "acc1", hasError: true)
        pumpRunLoop()

        var fixCalled: String?
        sidebar.onAuthErrorFix = { accountId in fixCalled = accountId }
        sidebar.onAuthErrorFix?("acc1")
        XCTAssertEqual(fixCalled, "acc1")
    }
}
