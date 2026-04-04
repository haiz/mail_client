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

    /// The bundled client ID. Replace with the value from Google Cloud Console.
    static let bundledClientId = "YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com"

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
