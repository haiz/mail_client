import Foundation

enum DockerHelper {

    static let imapHost = "localhost"
    static let imapPort = 3993  // IMAPS (TLS) — SwiftMail requires TLS
    static let smtpHost = "localhost"
    static let smtpPort = 3025
    static let testEmail = "test@localhost.com"
    static let testPassword = "password123"

    /// Check if GreenMail is running by attempting a TCP connection.
    static func isGreenMailRunning() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(3993).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Foundation.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
