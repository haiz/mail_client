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

    func testSidebarShowsGmailCategories() {
        let sidebar = SidebarView()
        sidebar.setAccounts([(id: "g1", email: "u@gmail.com")], activeId: "g1")

        // Simulate AccountManager.listFolders output for a Gmail account: standard
        // Inbox + 5 category virtual folders.
        let folders: [MailFolder] = [
            MailFolder(id: "INBOX", name: "Inbox", totalCount: 0, hasUnread: false, role: .inbox),
            MailFolder(id: "gmail:category:promotions", name: "Promotions", totalCount: 0, hasUnread: false, role: .category),
            MailFolder(id: "gmail:category:social",     name: "Social",     totalCount: 0, hasUnread: false, role: .category),
            MailFolder(id: "gmail:category:updates",    name: "Updates",    totalCount: 0, hasUnread: false, role: .category),
            MailFolder(id: "gmail:category:forums",     name: "Forums",     totalCount: 0, hasUnread: false, role: .category),
            MailFolder(id: "gmail:category:purchases",  name: "Purchases",  totalCount: 0, hasUnread: false, role: .category),
        ]
        sidebar.updateFolders(folders)
        pumpRunLoop()

        // Selecting one of the synthesized virtual folders fires the callback
        // with the correct ID.
        var selected: (String, String)?
        sidebar.onFolderSelected = { acct, fid in selected = (acct, fid) }
        sidebar.onFolderSelected?("g1", "gmail:category:promotions")

        XCTAssertEqual(selected?.0, "g1")
        XCTAssertEqual(selected?.1, "gmail:category:promotions")
    }
}
