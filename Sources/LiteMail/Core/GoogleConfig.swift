// Sources/LiteMail/Core/GoogleConfig.swift
import Foundation

enum GoogleConfig {
    /// UserDefaults key for the user-supplied Google Client ID override.
    static let clientIdDefaultsKey = "googleClientId"

    /// Client ID registered in Google Cloud Console under the LiteMail project.
    /// OAuth client type: "Desktop app" — supports loopback redirect URIs.
    /// Power users can override this via Settings → Google Client ID.
    static var clientId: String {
        UserDefaults.standard.string(forKey: clientIdDefaultsKey) ?? bundledClientId
    }

    static let bundledClientId = "137028004144-gvdnsjaol7amgjv5jd4plb1dqdc3t1o4.apps.googleusercontent.com"

    /// Client secret for the Desktop app OAuth client.
    /// Not truly secret for native apps — Google requires it for Desktop type but acknowledges it cannot be kept confidential.
    static let bundledClientSecret = "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"

    static var clientSecret: String {
        bundledClientSecret
    }

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Scopes: IMAP access + identity (display name, avatar) + read-only contacts.
    static let scopes: [String] = [
        "https://mail.google.com/",
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/contacts.readonly",
    ]
}
