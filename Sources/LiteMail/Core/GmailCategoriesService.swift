import Foundation
import OSLog

// TokenProvider protocol and AuthManager conformance are defined in ContactsStore.swift.

/// What AccountManager depends on. Allows test doubles in sync-workflow tests.
protocol CategoriesRefresher: Sendable {
    func refresh(accountId: String) async throws
}

/// Refreshes Gmail inbox category assignments after each sync.
/// Best-effort — failures are logged but never thrown, so IMAP sync success
/// isn't gated on Gmail REST availability.
actor GmailCategoriesService: CategoriesRefresher {

    private let client: GmailAPI
    private let store: MailStore
    private let tokenProvider: TokenProvider
    private let log = Logger(subsystem: "com.litemail", category: "gmail-categories")

    init(client: GmailAPI, store: MailStore, tokenProvider: TokenProvider) {
        self.client = client
        self.store = store
        self.tokenProvider = tokenProvider
    }

    /// For each of the 6 Gmail categories, query the API for inbox message IDs
    /// in the last 30 days, fetch their RFC-822 Message-Id headers, and update
    /// `emails.gmail_category` for each match in the local DB.
    func refresh(accountId: String) async throws {
        let token: String
        do {
            token = try await tokenProvider.oauthAccessToken(accountId: accountId)
        } catch {
            log.warning("Cannot refresh Gmail categories — no access token: \(error.localizedDescription)")
            return
        }

        for category in GmailCategory.allCases {
            do {
                try await refreshCategory(accountId: accountId, category: category, token: token)
            } catch GmailAPIError.rateLimited {
                log.warning("Gmail rate limit hit during \(category.rawValue) refresh; aborting cycle")
                return  // Skip remaining categories this cycle
            } catch {
                log.warning("Gmail \(category.rawValue) refresh failed: \(error.localizedDescription)")
                // Continue to next category; one failure shouldn't abort all.
            }
        }
    }

    private func refreshCategory(accountId: String, category: GmailCategory, token: String) async throws {
        let query = "category:\(category.searchToken) label:inbox newer_than:30d"
        let gmailIds = try await client.listMessageIds(query: query, maxResults: 500, accessToken: token)
        guard !gmailIds.isEmpty else { return }

        let mapping = try await client.batchGetMessageIds(ids: gmailIds, accessToken: token)
        for (_, rfc822MessageId) in mapping {
            try? await store.setGmailCategory(
                accountId: accountId,
                messageId: rfc822MessageId,
                category: category.rawValue
            )
        }
    }
}
