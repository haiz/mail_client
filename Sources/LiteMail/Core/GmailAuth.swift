import Foundation
import AppAuth

/// Handles Gmail OAuth2 authentication via AppAuth.
/// Stores tokens in macOS Keychain. Auto-refreshes on expiry.
final class GmailAuth: @unchecked Sendable {

    // Google OAuth2 endpoints
    private static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    // Gmail IMAP/SMTP scopes
    private static let scopes = [
        "https://mail.google.com/",  // Full IMAP/SMTP access
    ]

    private let clientId: String
    private let redirectURI: URL

    private var authState: OIDAuthState?
    private var currentAuthorizationFlow: OIDExternalUserAgentSession?

    // Keychain keys
    private static let keychainService = "com.litemail.oauth"
    private static let keychainAccount = "gmail-auth-state"

    init(clientId: String, redirectURI: URL) {
        self.clientId = clientId
        self.redirectURI = redirectURI
        self.authState = Self.loadAuthStateFromKeychain()
    }

    /// Whether we have a valid (or refreshable) auth state.
    var isAuthenticated: Bool {
        authState?.isAuthorized ?? false
    }

    /// The current access token, refreshing if needed.
    func accessToken() async throws -> String {
        guard let authState else {
            throw GmailAuthError.notAuthenticated
        }

        return try await withCheckedThrowingContinuation { continuation in
            authState.performAction { accessToken, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let accessToken {
                    continuation.resume(returning: accessToken)
                } else {
                    continuation.resume(throwing: GmailAuthError.noAccessToken)
                }
            }
        }
    }

    /// Initiates the OAuth2 login flow in the system browser.
    @MainActor
    func authenticate() async throws {
        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: Self.authorizationEndpoint,
            tokenEndpoint: Self.tokenEndpoint
        )

        let request = OIDAuthorizationRequest(
            configuration: configuration,
            clientId: clientId,
            clientSecret: nil,
            scopes: Self.scopes,
            redirectURL: redirectURI,
            responseType: OIDResponseTypeCode,
            additionalParameters: nil
        )

        let authState = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OIDAuthState, Error>) in
            // AppAuth uses a loopback HTTP redirect for macOS
            currentAuthorizationFlow = OIDAuthState.authState(
                byPresenting: request,
                callback: { authState, error in
                    if let authState {
                        continuation.resume(returning: authState)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: GmailAuthError.authenticationFailed)
                    }
                }
            )
        }

        self.authState = authState
        Self.saveAuthStateToKeychain(authState)
    }

    /// Signs out and clears stored credentials.
    func signOut() {
        authState = nil
        Self.deleteKeychainItem()
    }

    // MARK: - Keychain Storage

    private static func saveAuthStateToKeychain(_ authState: OIDAuthState) {
        let data = try? NSKeyedArchiver.archivedData(
            withRootObject: authState,
            requiringSecureCoding: true
        )
        guard let data else { return }

        deleteKeychainItem()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadAuthStateFromKeychain() -> OIDAuthState? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: OIDAuthState.self,
            from: data
        )
    }

    private static func deleteKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum GmailAuthError: Error, LocalizedError {
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
