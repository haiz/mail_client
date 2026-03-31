import Foundation

/// Auto-discovers email server configuration from an email address.
/// Tries (in order): provider presets, JMAP well-known, Mozilla autoconfig, manual fallback.
///
/// Usage: let result = try await AutoDiscovery.discover(email: "user@fastmail.com")
struct AutoDiscovery {

    /// Result of auto-discovery.
    struct Result {
        let protocolType: AccountConfig.ProtocolType
        let imapUsername: String?
        let imapHost: String?
        let imapPort: Int?
        let smtpHost: String?
        let smtpPort: Int?
        let jmapUrl: String?
        let authType: AccountConfig.AuthType
        let oauthClientId: String?
        let providerName: String?

        init(protocolType: AccountConfig.ProtocolType, imapUsername: String? = nil,
             imapHost: String?, imapPort: Int?, smtpHost: String?, smtpPort: Int?,
             jmapUrl: String?, authType: AccountConfig.AuthType,
             oauthClientId: String?, providerName: String?) {
            self.protocolType = protocolType
            self.imapUsername = imapUsername
            self.imapHost = imapHost
            self.imapPort = imapPort
            self.smtpHost = smtpHost
            self.smtpPort = smtpPort
            self.jmapUrl = jmapUrl
            self.authType = authType
            self.oauthClientId = oauthClientId
            self.providerName = providerName
        }
    }

    /// Runs the full discovery chain for an email address.
    static func discover(email: String) async -> Result {
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        guard !domain.isEmpty else {
            return guessIMAPConfig(email: email, domain: "example.com")
        }

        // Step 1: Provider presets (handles 90%+ of users)
        if let preset = presetFor(domain: domain) {
            return preset
        }

        // Step 2: JMAP well-known
        if let jmap = await discoverJMAP(domain: domain) {
            return jmap
        }

        // Step 3: Mozilla autoconfig
        if let autoconfig = await discoverAutoconfig(domain: domain) {
            return autoconfig
        }

        // Step 4: Generic IMAP guess — mail.domain.com, username = local part
        return guessIMAPConfig(email: email, domain: domain)
    }

    // MARK: - Provider Presets

    private static func presetFor(domain: String) -> Result? {
        let lowered = domain.lowercased()

        // Gmail
        if lowered == "gmail.com" || lowered == "googlemail.com" {
            return Result(
                protocolType: .imap,
                imapHost: "imap.gmail.com", imapPort: 993,
                smtpHost: "smtp.gmail.com", smtpPort: 465,
                jmapUrl: nil,
                authType: .oauth2,
                oauthClientId: nil, // User must provide their own
                providerName: "Gmail"
            )
        }

        // Outlook / Hotmail / Live
        if ["outlook.com", "hotmail.com", "live.com", "msn.com"].contains(lowered) {
            return Result(
                protocolType: .imap,
                imapHost: "outlook.office365.com", imapPort: 993,
                smtpHost: "smtp.office365.com", smtpPort: 587,
                jmapUrl: nil,
                authType: .oauth2,
                oauthClientId: nil,
                providerName: "Outlook"
            )
        }

        // Fastmail (prefers JMAP)
        if lowered == "fastmail.com" || lowered == "fastmail.fm" || lowered == "messagingengine.com" {
            return Result(
                protocolType: .jmap,
                imapHost: "imap.fastmail.com", imapPort: 993,
                smtpHost: "smtp.fastmail.com", smtpPort: 465,
                jmapUrl: "https://api.fastmail.com",
                authType: .bearer,
                oauthClientId: nil,
                providerName: "Fastmail"
            )
        }

        // iCloud
        if lowered == "icloud.com" || lowered == "me.com" || lowered == "mac.com" {
            return Result(
                protocolType: .imap,
                imapHost: "imap.mail.me.com", imapPort: 993,
                smtpHost: "smtp.mail.me.com", smtpPort: 587,
                jmapUrl: nil,
                authType: .password,
                oauthClientId: nil,
                providerName: "iCloud"
            )
        }

        // Yahoo
        if lowered == "yahoo.com" || lowered == "yahoo.co.uk" || lowered == "ymail.com" {
            return Result(
                protocolType: .imap,
                imapHost: "imap.mail.yahoo.com", imapPort: 993,
                smtpHost: "smtp.mail.yahoo.com", smtpPort: 465,
                jmapUrl: nil,
                authType: .password,
                oauthClientId: nil,
                providerName: "Yahoo"
            )
        }

        // ProtonMail (requires Bridge)
        if lowered == "protonmail.com" || lowered == "proton.me" || lowered == "pm.me" {
            return Result(
                protocolType: .imap,
                imapHost: "127.0.0.1", imapPort: 1143,
                smtpHost: "127.0.0.1", smtpPort: 1025,
                jmapUrl: nil,
                authType: .password,
                oauthClientId: nil,
                providerName: "ProtonMail (Bridge)"
            )
        }

        return nil
    }

    // MARK: - JMAP Well-Known (RFC 8620)

    private static func discoverJMAP(domain: String) async -> Result? {
        let url = URL(string: "https://\(domain)/.well-known/jmap")!
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["capabilities"] != nil else {
            return nil
        }

        return Result(
            protocolType: .jmap,
            imapHost: nil, imapPort: nil,
            smtpHost: nil, smtpPort: nil,
            jmapUrl: "https://\(domain)/.well-known/jmap",
            authType: .bearer,
            oauthClientId: nil,
            providerName: "JMAP (\(domain))"
        )
    }

    // MARK: - Mozilla Autoconfig

    private static func discoverAutoconfig(domain: String) async -> Result? {
        let urls = [
            "https://autoconfig.\(domain)/mail/config-v1.1.xml",
            "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml",
        ]

        for urlString in urls {
            guard let url = URL(string: urlString),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                continue
            }

            if let result = parseAutoconfig(data) {
                return result
            }
        }

        return nil
    }

    /// Parses Mozilla autoconfig XML to extract IMAP/SMTP settings.
    private static func parseAutoconfig(_ data: Data) -> Result? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }

        var imapHost: String?
        var imapPort: Int?
        var smtpHost: String?
        var smtpPort: Int?

        // Simple XML parsing (good enough for autoconfig format)
        if let imapMatch = xml.range(of: "<incomingServer type=\"imap\">.*?</incomingServer>", options: .regularExpression) {
            let imapSection = String(xml[imapMatch])
            imapHost = extractTag("hostname", from: imapSection)
            imapPort = extractTag("port", from: imapSection).flatMap(Int.init)
        }

        if let smtpMatch = xml.range(of: "<outgoingServer type=\"smtp\">.*?</outgoingServer>", options: .regularExpression) {
            let smtpSection = String(xml[smtpMatch])
            smtpHost = extractTag("hostname", from: smtpSection)
            smtpPort = extractTag("port", from: smtpSection).flatMap(Int.init)
        }

        guard imapHost != nil || smtpHost != nil else { return nil }

        return Result(
            protocolType: .imap,
            imapHost: imapHost, imapPort: imapPort ?? 993,
            smtpHost: smtpHost, smtpPort: smtpPort ?? 465,
            jmapUrl: nil,
            authType: .password,
            oauthClientId: nil,
            providerName: nil
        )
    }

    private static func extractTag(_ tag: String, from xml: String) -> String? {
        guard let range = xml.range(of: "<\(tag)>(.*?)</\(tag)>", options: .regularExpression) else { return nil }
        let match = xml[range]
        let content = match.replacingOccurrences(of: "<\(tag)>", with: "").replacingOccurrences(of: "</\(tag)>", with: "")
        return content.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Generic IMAP Guess

    /// For unknown domains, guess common IMAP/SMTP patterns.
    /// hai@caodev.top → server: mail.caodev.top, username: hai, IMAP 993, SMTP 587
    private static func guessIMAPConfig(email: String, domain: String) -> Result {
        let username = email.split(separator: "@").first.map(String.init)

        return Result(
            protocolType: .imap,
            imapUsername: username,
            imapHost: "mail.\(domain)", imapPort: 993,
            smtpHost: "mail.\(domain)", smtpPort: 587,
            jmapUrl: nil,
            authType: .password,
            oauthClientId: nil,
            providerName: "IMAP (\(domain))"
        )
    }
}
