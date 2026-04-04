import Foundation
import AppKit
import AppAuth

/// Manages authentication for multiple accounts.
/// Each account gets its own Keychain entry and auth state.
/// Supports OAuth2 (Gmail, Outlook) and password auth (generic IMAP).
final class AuthManager: @unchecked Sendable {

    private static let keychainService = "com.litemail.auth"

    // In-memory cache of OAuth states per account
    private var oauthStates: [String: OIDAuthState] = [:]

    // Retained during OAuth2 browser flow to keep the loopback HTTP handler alive.
    private nonisolated(unsafe) var currentAuthHandler: OIDRedirectHTTPHandler?

    init() {
        // States are loaded lazily from Keychain on first access
    }

    // MARK: - OAuth2

    /// Initiates OAuth2 login flow for an account using the system browser (loopback redirect).
    /// Requires a "Desktop app" OAuth client type in Google Cloud Console.
    @MainActor
    func authenticateOAuth2(
        accountId: String,
        clientId: String,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        scopes: [String],
        presentingWindow: NSWindow
        // redirectURI removed — generated dynamically by OIDRedirectHTTPHandler
    ) async throws {
        // Spin up a local HTTP listener on a random port.
        // Google redirects here after consent: http://127.0.0.1:PORT/?code=...
        let handler = OIDRedirectHTTPHandler(successURL: nil)
        let redirectURI = handler.startHTTPListener(nil)
        currentAuthHandler = handler   // retain until callback fires

        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint
        )
        let request = OIDAuthorizationRequest(
            configuration: configuration,
            clientId: clientId,
            clientSecret: nil,
            scopes: scopes,
            redirectURL: redirectURI,
            responseType: OIDResponseTypeCode,
            additionalParameters: nil
        )

        let authState = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OIDAuthState, Error>) in
            let session = OIDAuthState.authState(
                byPresenting: request,
                externalUserAgent: OIDExternalUserAgentMac(presenting: presentingWindow)
            ) { authState, error in
                if let authState {
                    continuation.resume(returning: authState)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: AuthError.authenticationFailed)
                }
            }
            handler.currentAuthorizationFlow = session   // routes loopback redirect to session
        }

        currentAuthHandler = nil   // release handler after flow completes

        oauthStates[accountId] = authState
        Self.saveToKeychain(
            accountId: accountId,
            data: try NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true)
        )
    }

    /// Gets a fresh access token for an OAuth2 account, refreshing if needed.
    func oauthAccessToken(accountId: String) async throws -> String {
        let state = try loadOAuthState(accountId: accountId)

        return try await withCheckedThrowingContinuation { continuation in
            state.performAction { accessToken, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let accessToken {
                    continuation.resume(returning: accessToken)
                } else {
                    continuation.resume(throwing: AuthError.noAccessToken)
                }
            }
        }
    }

    func isOAuthAuthenticated(accountId: String) -> Bool {
        if let state = oauthStates[accountId] {
            return state.isAuthorized
        }
        if let state = Self.loadFromKeychain(accountId: accountId).flatMap({ try? NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: $0) }) {
            oauthStates[accountId] = state
            return state.isAuthorized
        }
        return false
    }

    // MARK: - Password Auth

    /// Stores a password for a generic IMAP account.
    func storePassword(accountId: String, password: String) {
        guard let data = password.data(using: .utf8) else { return }
        Self.saveToKeychain(accountId: accountId, data: data)
    }

    /// Retrieves the stored password for a generic IMAP account.
    func getPassword(accountId: String) -> String? {
        guard let data = Self.loadFromKeychain(accountId: accountId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Cleanup

    func removeCredentials(accountId: String) {
        oauthStates.removeValue(forKey: accountId)
        Self.deleteKeychainItem(accountId: accountId)
    }

    // MARK: - Keychain (per-account keys)

    private func loadOAuthState(accountId: String) throws -> OIDAuthState {
        if let cached = oauthStates[accountId] { return cached }
        guard let data = Self.loadFromKeychain(accountId: accountId),
              let state = try? NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data) else {
            throw AuthError.notAuthenticated
        }
        oauthStates[accountId] = state
        return state
    }

    private static func saveToKeychain(accountId: String, data: Data) {
        deleteKeychainItem(accountId: accountId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "account-\(accountId)",
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadFromKeychain(accountId: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "account-\(accountId)",
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func deleteKeychainItem(accountId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "account-\(accountId)",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum AuthError: Error, LocalizedError {
    case notAuthenticated
    case noAccessToken
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Not authenticated. Please sign in."
        case .noAccessToken: "Failed to obtain access token."
        case .authenticationFailed: "Authentication flow failed."
        }
    }
}
