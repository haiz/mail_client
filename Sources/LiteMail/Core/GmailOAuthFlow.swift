// Sources/LiteMail/Core/GmailOAuthFlow.swift
import Foundation
import AppAuth

/// Errors thrown by OAuth2 browser flows.
enum OAuthError: Error, LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:         return "Sign-in was cancelled."
        case .failed(let msg):  return "Sign-in failed: \(msg)"
        }
    }
}

/// Abstraction over the OAuth2 browser flow. Inject a stub in tests.
protocol OAuthFlowProtocol: Actor {
    func authenticate(accountId: String, email: String) async throws
}

/// Runs the Google OAuth2 consent flow in the system browser via AppAuth.
/// On success the token is persisted by AuthManager. Throws OAuthError on failure.
actor GmailOAuthFlow: OAuthFlowProtocol {
    private let authManager: AuthManager

    init(authManager: AuthManager) {
        self.authManager = authManager
    }

    func authenticate(accountId: String, email: String) async throws {
        do {
            try await authManager.authenticateOAuth2(
                accountId: accountId,
                clientId: GoogleConfig.clientId,
                clientSecret: GoogleConfig.clientSecret,
                authorizationEndpoint: GoogleConfig.authorizationEndpoint,
                tokenEndpoint: GoogleConfig.tokenEndpoint,
                scopes: GoogleConfig.scopes,
                loginHint: email
            )
        } catch let error as OAuthError {
            throw error
        } catch {
            let ns = error as NSError
            // OIDErrorCodeUserCanceledAuthorizationFlow = -3
            // OIDErrorCodeProgramCanceledAuthorizationFlow = -4
            if ns.domain == OIDGeneralErrorDomain && (ns.code == -3 || ns.code == -4) {
                throw OAuthError.cancelled
            }
            throw OAuthError.failed(ns.localizedDescription)
        }
    }
}
