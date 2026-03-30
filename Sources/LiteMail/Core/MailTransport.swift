import Foundation
import SwiftMail

/// Actor that owns SwiftMail IMAP/SMTP connections.
/// SyncEngine and Composer both use this — single connection pool,
/// single auth handler, single reconnection logic.
actor MailTransport {

    private let auth: GmailAuth
    private let userEmail: String
    private var imapServer: IMAPServer?
    private var smtpServer: SMTPServer?

    private let imapHost = "imap.gmail.com"
    private let imapPort = 993
    private let smtpHost = "smtp.gmail.com"
    private let smtpPort = 465

    private var reconnectAttempts = 0
    private let maxReconnectDelay: TimeInterval = 60

    init(auth: GmailAuth, userEmail: String) {
        self.auth = auth
        self.userEmail = userEmail
    }

    // MARK: - IMAP Connection

    func connectIMAP() async throws -> IMAPServer {
        if let server = imapServer {
            return server
        }

        let accessToken = try await auth.accessToken()
        let server = IMAPServer(host: imapHost, port: imapPort)
        try await server.connect()
        try await server.authenticateXOAUTH2(email: userEmail, accessToken: accessToken)

        reconnectAttempts = 0
        imapServer = server
        return server
    }

    func disconnectIMAP() async {
        if let server = imapServer {
            try? await server.logout()
            imapServer = nil
        }
    }

    /// Reconnects IMAP with exponential backoff.
    func reconnectIMAP() async throws -> IMAPServer {
        await disconnectIMAP()

        let delay = min(pow(2.0, Double(reconnectAttempts)), maxReconnectDelay)
        reconnectAttempts += 1

        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }

        return try await connectIMAP()
    }

    // MARK: - SMTP Connection

    func connectSMTP() async throws -> SMTPServer {
        if let server = smtpServer {
            return server
        }

        let accessToken = try await auth.accessToken()
        let server = SMTPServer(host: smtpHost, port: smtpPort)
        try await server.connect()
        try await server.authenticateXOAUTH2(email: userEmail, accessToken: accessToken)

        smtpServer = server
        return server
    }

    func disconnectSMTP() async {
        if let server = smtpServer {
            try? await server.disconnect()
            smtpServer = nil
        }
    }

    // MARK: - Lifecycle

    func disconnectAll() async {
        await disconnectIMAP()
        await disconnectSMTP()
    }
}
