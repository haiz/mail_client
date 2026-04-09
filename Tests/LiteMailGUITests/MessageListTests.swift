import XCTest
import AppKit
@testable import LiteMail

@MainActor
final class MessageListTests: XCTestCase {

    func testLoadEmails() {
        let messageList = MessageListView()
        let headers = GUITestData.sampleHeaders(count: 50)
        messageList.update(messages: headers)
        pumpRunLoop()

        XCTAssertEqual(messageList.messages.count, 50)
    }

    func testSelectEmailCallback() {
        let messageList = MessageListView()
        let headers = GUITestData.sampleHeaders(count: 5)
        messageList.update(messages: headers)
        pumpRunLoop()

        var selectedHeader: EmailHeader?
        messageList.onMessageSelected = { header in
            selectedHeader = header
        }

        messageList.onMessageSelected?(headers[2])

        XCTAssertEqual(selectedHeader?.id, headers[2].id)
        XCTAssertEqual(selectedHeader?.subject, "Email Subject #3")
    }

    func testSearchCallback() {
        let messageList = MessageListView()
        pumpRunLoop()

        var searchQuery: String?
        messageList.onSearchChanged = { query in
            searchQuery = query
        }

        messageList.onSearchChanged?("meeting notes")
        XCTAssertEqual(searchQuery, "meeting notes")
    }

    func testEmptyFolder() {
        let messageList = MessageListView()
        messageList.update(messages: [])
        pumpRunLoop()

        XCTAssertEqual(messageList.messages.count, 0)
    }

    func testThreadGrouping() {
        let messageList = MessageListView()

        let headers = [
            EmailHeader(id: 1, accountId: "acc1", messageId: "<t1@test>", threadId: "thread-A", folder: "INBOX", senderName: "Alice", senderEmail: "alice@test.com", subject: "Thread topic", date: Date(), isRead: false, isStarred: false, hasAttachments: false, snippet: nil),
            EmailHeader(id: 2, accountId: "acc1", messageId: "<t2@test>", threadId: "thread-A", folder: "INBOX", senderName: "Bob", senderEmail: "bob@test.com", subject: "Re: Thread topic", date: Date().addingTimeInterval(60), isRead: false, isStarred: false, hasAttachments: false, snippet: nil),
            EmailHeader(id: 3, accountId: "acc1", messageId: "<t3@test>", threadId: "thread-B", folder: "INBOX", senderName: "Carol", senderEmail: "carol@test.com", subject: "Other thread", date: Date(), isRead: false, isStarred: false, hasAttachments: false, snippet: nil),
        ]

        messageList.update(messages: headers)
        pumpRunLoop()

        XCTAssertEqual(messageList.threadGroups.count, 2)

        let groupA = messageList.threadGroups.first(where: { $0.threadId == "thread-A" })
        XCTAssertEqual(groupA?.count, 2)
    }
}
