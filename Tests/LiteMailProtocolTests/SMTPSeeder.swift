import Foundation

/// Seeds test emails into GreenMail via raw SMTP commands.
enum SMTPSeeder {

    static func sendEmail(
        from: String = "sender@test.com",
        to: String = DockerHelper.testEmail,
        subject: String = "Test Email",
        body: String = "This is a test email body.",
        host: String = DockerHelper.smtpHost,
        port: Int = DockerHelper.smtpPort
    ) throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw SMTPError.socketCreationFailed }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Foundation.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw SMTPError.connectionFailed }

        _ = readLine(sock: sock)

        try sendCommand(sock: sock, "EHLO localhost")
        try sendCommand(sock: sock, "MAIL FROM:<\(from)>")
        try sendCommand(sock: sock, "RCPT TO:<\(to)>")
        try sendCommand(sock: sock, "DATA")

        let message = """
        From: \(from)\r
        To: \(to)\r
        Subject: \(subject)\r
        Date: \(ISO8601DateFormatter().string(from: Date()))\r
        Message-ID: <\(UUID().uuidString)@test>\r
        \r
        \(body)\r
        .
        """

        _ = Foundation.send(sock, message, message.utf8.count, 0)
        _ = readLine(sock: sock)

        try sendCommand(sock: sock, "QUIT")
    }

    static func seedEmails(count: Int, to: String = DockerHelper.testEmail) throws {
        for i in 1...count {
            try sendEmail(
                from: "sender\(i)@test.com",
                to: to,
                subject: "Test Email #\(i)",
                body: "Body of test email number \(i)"
            )
        }
    }

    private static func sendCommand(sock: Int32, _ command: String) throws {
        let cmd = command + "\r\n"
        let sent = Foundation.send(sock, cmd, cmd.utf8.count, 0)
        guard sent > 0 else { throw SMTPError.sendFailed }
        let response = readLine(sock: sock)
        guard response.hasPrefix("2") || response.hasPrefix("3") else {
            throw SMTPError.unexpectedResponse(response)
        }
    }

    private static func readLine(sock: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let bytesRead = recv(sock, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return "" }
        return String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
    }

    enum SMTPError: Error {
        case socketCreationFailed
        case connectionFailed
        case sendFailed
        case unexpectedResponse(String)
    }
}
