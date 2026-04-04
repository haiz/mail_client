import Foundation

/// Minimal token-vending interface; lets tests inject a stub without subclassing AuthManager.
protocol TokenProvider: Sendable {
    func oauthAccessToken(accountId: String) async throws -> String
}

extension AuthManager: TokenProvider {}

/// Fetches Google Contacts from the People API and caches them in SQLite for composer autocomplete.
/// fetchAndStore() is non-fatal — failures are logged and swallowed.
actor ContactsStore {
    private let mailStore: MailStore
    private let tokenProvider: any TokenProvider
    private let urlSession: URLSession

    /// Convenience initialiser for production use.
    init(mailStore: MailStore, authManager: AuthManager, urlSession: URLSession = .shared) {
        self.mailStore = mailStore
        self.tokenProvider = authManager
        self.urlSession = urlSession
    }

    /// Designated initialiser that accepts any TokenProvider (used by tests).
    init(mailStore: MailStore, tokenProvider: any TokenProvider, urlSession: URLSession) {
        self.mailStore = mailStore
        self.tokenProvider = tokenProvider
        self.urlSession = urlSession
    }

    // MARK: - Public API

    /// Fetches all contacts from Google People API and upserts into the contacts table.
    /// Non-fatal: any error is logged and swallowed.
    func fetchAndStore(accountId: String) async {
        do {
            let token = try await tokenProvider.oauthAccessToken(accountId: accountId)
            var pageToken: String? = nil
            repeat {
                let (contacts, next) = try await fetchPage(token: token, pageToken: pageToken)
                let records = contacts.map { c in
                    ContactRecord(
                        id: c.resourceName,
                        accountId: accountId,
                        name: c.name,
                        email: c.email,
                        photoURL: c.photoURL,
                        syncedAt: Int(Date().timeIntervalSince1970)
                    )
                }
                try await mailStore.upsertContacts(records)
                pageToken = next
            } while pageToken != nil
        } catch {
            print("[ContactsStore] fetch failed for \(accountId): \(error)")
        }
    }

    /// Returns all cached contacts for the given account (for composer autocomplete preload).
    func allCachedContacts(accountId: String) async throws -> [ContactRecord] {
        try await mailStore.lookupContacts(prefix: "", accountId: accountId, limit: 500)
    }

    // MARK: - Private

    private struct PeopleContact {
        let resourceName: String
        let name: String?
        let email: String
        let photoURL: String?
    }

    private func fetchPage(token: String, pageToken: String?) async throws -> ([PeopleContact], String?) {
        var components = URLComponents(string: "https://people.googleapis.com/v1/people/me/connections")!
        var queryItems: [URLQueryItem] = [
            .init(name: "personFields", value: "names,emailAddresses,photos"),
            .init(name: "pageSize", value: "1000"),
        ]
        if let pageToken {
            queryItems.append(.init(name: "pageToken", value: pageToken))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ContactsError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let nextPageToken = json["nextPageToken"] as? String
        let connections = json["connections"] as? [[String: Any]] ?? []

        let contacts: [PeopleContact] = connections.compactMap { entry in
            guard
                let resourceName = entry["resourceName"] as? String,
                let emailAddresses = entry["emailAddresses"] as? [[String: Any]],
                let emailEntry = emailAddresses.first,
                let email = emailEntry["value"] as? String
            else { return nil }
            let name = (entry["names"] as? [[String: Any]])?.first?["displayName"] as? String
            let photoURL = (entry["photos"] as? [[String: Any]])?.first?["url"] as? String
            return PeopleContact(resourceName: resourceName, name: name, email: email, photoURL: photoURL)
        }

        return (contacts, nextPageToken)
    }
}

enum ContactsError: Error {
    case httpError(Int)
}
