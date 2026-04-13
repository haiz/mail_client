import Foundation
import AppKit
@testable import LiteMail

enum GUITestData {

    static let testAccountId = "gui-test-acc"
    static let testEmail = "test@example.com"

    static var sampleAccount: AccountConfig {
        AccountConfig(
            id: testAccountId,
            emailAddress: testEmail,
            displayName: "Test User",
            protocolType: .imap,
            imapUsername: testEmail,
            imapHost: "imap.example.com",
            imapPort: 993,
            smtpHost: "smtp.example.com",
            smtpPort: 587,
            jmapUrl: nil,
            authType: .password,
            keychainRef: "gui-test-key",
            isDefault: true
        )
    }

    static var sampleFolders: [MailFolder] {
        [
            MailFolder(id: "INBOX", name: "Inbox", totalCount: 10, hasUnread: true, role: .inbox),
            MailFolder(id: "[Gmail]/Sent Mail", name: "Sent", totalCount: 5, hasUnread: false, role: .sent),
            MailFolder(id: "[Gmail]/Drafts", name: "Drafts", totalCount: 2, hasUnread: true, role: .drafts),
            MailFolder(id: "[Gmail]/Trash", name: "Trash", totalCount: 0, hasUnread: false, role: .trash),
        ]
    }

    static func sampleHeaders(count: Int = 10) -> [EmailHeader] {
        (1...count).map { i in
            EmailHeader(
                id: Int64(i),
                accountId: testAccountId,
                messageId: "<msg-\(i)@test>",
                threadId: "thread-\(i)",
                folder: "INBOX",
                senderName: "Sender \(i)",
                senderEmail: "sender\(i)@example.com",
                subject: "Email Subject #\(i)",
                date: Date().addingTimeInterval(Double(-i * 3600)),
                isRead: i % 2 == 0,
                isStarred: i == 1,
                hasAttachments: i == 3,
                snippet: "Preview of email \(i)..."
            )
        }
    }

    static func sampleBody(emailId: Int64, html: Bool = false) -> EmailBody {
        EmailBody(
            emailId: emailId,
            textBody: "This is the body of email \(emailId).",
            htmlBody: html ? "<html><body><p>HTML body of email \(emailId)</p></body></html>" : nil
        )
    }

    static func sampleAttachments(emailId: Int64) -> [AttachmentInfo] {
        [
            AttachmentInfo(id: "att-1", partId: "1.1", filename: "photo.jpg", mimeType: "image/jpeg", sizeBytes: 204800),
            AttachmentInfo(id: "att-2", partId: "1.2", filename: "report.pdf", mimeType: "application/pdf", sizeBytes: 512000),
        ]
    }
}

/// Pump the RunLoop to allow AppKit layout/rendering to complete.
func pumpRunLoop(seconds: TimeInterval = 0.1) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}
