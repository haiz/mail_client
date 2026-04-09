import Foundation
@testable import LiteMail

/// A spy implementing MailEngineProtocol for GUI testing.
final class MockMailEngine: MailEngineProtocol, @unchecked Sendable {

    // MARK: - Stub data
    var accounts: [AccountConfig] = []
    var folders: [String: [MailFolder]] = [:]
    var headers: [String: [EmailHeader]] = [:]
    var bodies: [Int64: EmailBody] = [:]
    var threads: [String: [EmailHeader]] = [:]
    var searchResults: [EmailHeader] = []
    var attachmentList: [Int64: [AttachmentInfo]] = [:]
    var attachmentData: [String: Data] = [:]
    var labelsByEmail: [Int64: [String]] = [:]
    var allLabelsByAccount: [String: [String]] = [:]

    // MARK: - Call recording
    private(set) var calls: [String] = []
    private(set) var markReadCalls: [(Int64, Bool)] = []
    private(set) var markStarredCalls: [(Int64, Bool)] = []
    private(set) var archiveCalls: [Int64] = []
    private(set) var deleteCalls: [Int64] = []
    private(set) var moveCalls: [(Int64, String)] = []
    private(set) var sendCalls: [(OutgoingMessage, String)] = []
    private(set) var draftCalls: [(OutgoingMessage, String)] = []
    private(set) var syncCalls: [String] = []

    func listAccounts() async throws -> [AccountConfig] { calls.append("listAccounts"); return accounts }
    func addAccount(_ config: AccountConfig) async throws { calls.append("addAccount"); accounts.append(config) }
    func removeAccount(id: String) async throws { calls.append("removeAccount"); accounts.removeAll { $0.id == id } }
    func performInitialSync(accountId: String) async throws { calls.append("initialSync"); syncCalls.append(accountId) }
    func performIncrementalSync(accountId: String) async throws { calls.append("incrementalSync"); syncCalls.append(accountId) }
    func syncAllAccounts() async throws { calls.append("syncAll"); for a in accounts { syncCalls.append(a.id) } }
    func search(query: String, accountId: String?) async throws -> [EmailHeader] { calls.append("search"); return searchResults }

    func fetchHeaders(accountId: String, folder: String, offset: Int, limit: Int) async throws -> [EmailHeader] {
        calls.append("fetchHeaders")
        let all = headers["\(accountId):\(folder)"] ?? []
        let end = min(offset + limit, all.count)
        guard offset < all.count else { return [] }
        return Array(all[offset..<end])
    }

    func fetchBody(emailId: Int64) async throws -> EmailBody? { calls.append("fetchBody"); return bodies[emailId] }
    func fetchThread(threadId: String) async throws -> [EmailHeader] { calls.append("fetchThread"); return threads[threadId] ?? [] }
    func listFolders(accountId: String) async throws -> [MailFolder] { calls.append("listFolders"); return folders[accountId] ?? [] }
    func markRead(emailId: Int64, read: Bool) async throws { calls.append("markRead"); markReadCalls.append((emailId, read)) }
    func markStarred(emailId: Int64, starred: Bool) async throws { calls.append("markStarred"); markStarredCalls.append((emailId, starred)) }
    func archive(emailId: Int64) async throws { calls.append("archive"); archiveCalls.append(emailId) }
    func delete(emailId: Int64) async throws { calls.append("delete"); deleteCalls.append(emailId) }
    func move(emailId: Int64, toFolder: String) async throws { calls.append("move"); moveCalls.append((emailId, toFolder)) }
    func createFolder(name: String, accountId: String) async throws { calls.append("createFolder") }
    func addLabel(emailId: Int64, label: String) async throws { calls.append("addLabel") }
    func removeLabel(emailId: Int64, label: String) async throws { calls.append("removeLabel") }
    func fetchLabels(emailId: Int64) async throws -> [String] { calls.append("fetchLabels"); return labelsByEmail[emailId] ?? [] }
    func allLabels(accountId: String) async throws -> [String] { calls.append("allLabels"); return allLabelsByAccount[accountId] ?? [] }
    func listAttachments(emailId: Int64) async throws -> [AttachmentInfo] { calls.append("listAttachments"); return attachmentList[emailId] ?? [] }
    func fetchAttachmentData(emailId: Int64, partId: String) async throws -> Data { calls.append("fetchAttachmentData"); return attachmentData["\(emailId):\(partId)"] ?? Data() }
    func send(message: OutgoingMessage, fromAccountId: String) async throws { calls.append("send"); sendCalls.append((message, fromAccountId)) }
    func saveDraft(_ draft: OutgoingMessage, accountId: String) async throws { calls.append("saveDraft"); draftCalls.append((draft, accountId)) }
}
