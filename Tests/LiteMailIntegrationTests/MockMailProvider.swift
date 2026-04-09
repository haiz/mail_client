import Foundation
@testable import LiteMail

/// A spy+stub actor that records all calls and returns pre-configured responses.
actor MockMailProvider: MailProvider {
    let accountId: String
    let emailAddress: String

    private(set) var isConnected: Bool = false

    // MARK: - Stub data
    var stubbedFolders: [ProviderFolder] = []
    var stubbedMessages: [String: [ProviderMessage]] = [:]
    var stubbedBodies: [String: ProviderMessageBody] = [:]
    var stubbedAttachments: [String: Data] = [:]
    var stubbedError: Error?

    // MARK: - Call recording
    private(set) var calls: [String] = []
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var sendCalls: [OutgoingMessage] = []
    private(set) var markReadCalls: [(ref: String, read: Bool)] = []
    private(set) var markStarredCalls: [(ref: String, starred: Bool)] = []
    private(set) var moveCalls: [(ref: String, toFolderId: String)] = []
    private(set) var deleteCalls: [String] = []
    private(set) var fetchAttachmentCalls: [(ref: String, partId: String)] = []
    private(set) var createFolderCalls: [String] = []

    init(accountId: String, emailAddress: String = "test@example.com") {
        self.accountId = accountId
        self.emailAddress = emailAddress
    }

    // MARK: - Setters for stubs

    func setStubbedFolders(_ folders: [ProviderFolder]) {
        stubbedFolders = folders
    }

    func setStubbedMessages(_ messages: [String: [ProviderMessage]]) {
        stubbedMessages = messages
    }

    func setStubbedBodies(_ bodies: [String: ProviderMessageBody]) {
        stubbedBodies = bodies
    }

    func setStubbedAttachments(_ attachments: [String: Data]) {
        stubbedAttachments = attachments
    }

    func setStubbedError(_ error: Error?) {
        stubbedError = error
    }

    // MARK: - MailProvider conformance

    func connect() async throws {
        calls.append("connect")
        connectCount += 1
        if let error = stubbedError { throw error }
        isConnected = true
    }

    func disconnect() async throws {
        calls.append("disconnect")
        disconnectCount += 1
        isConnected = false
    }

    func performInitialSync() async throws {
        calls.append("performInitialSync")
        if let error = stubbedError { throw error }
    }

    func performIncrementalSync() async throws {
        calls.append("performIncrementalSync")
        if let error = stubbedError { throw error }
    }

    func startPushNotifications(onNewMessage: @escaping @Sendable () async -> Void) async throws {
        calls.append("startPushNotifications")
    }

    func stopPushNotifications() async throws {
        calls.append("stopPushNotifications")
    }

    func listFolders() async throws -> [ProviderFolder] {
        calls.append("listFolders")
        if let error = stubbedError { throw error }
        return stubbedFolders
    }

    func fetchMessages(folderId: String, cursor: String?, limit: Int) async throws -> (messages: [ProviderMessage], nextCursor: String?) {
        calls.append("fetchMessages:\(folderId)")
        if let error = stubbedError { throw error }
        let msgs = stubbedMessages[folderId] ?? []
        return (messages: msgs, nextCursor: nil)
    }

    func fetchMessageBody(messageRef: String) async throws -> ProviderMessageBody {
        calls.append("fetchMessageBody:\(messageRef)")
        if let error = stubbedError { throw error }
        return stubbedBodies[messageRef] ?? ProviderMessageBody(ref: messageRef, textBody: "default body", htmlBody: nil)
    }

    func markRead(messageRef: String, read: Bool) async throws {
        calls.append("markRead:\(messageRef):\(read)")
        markReadCalls.append((ref: messageRef, read: read))
        if let error = stubbedError { throw error }
    }

    func markStarred(messageRef: String, starred: Bool) async throws {
        calls.append("markStarred:\(messageRef):\(starred)")
        markStarredCalls.append((ref: messageRef, starred: starred))
        if let error = stubbedError { throw error }
    }

    func moveMessage(messageRef: String, toFolderId: String) async throws {
        calls.append("moveMessage:\(messageRef):\(toFolderId)")
        moveCalls.append((ref: messageRef, toFolderId: toFolderId))
        if let error = stubbedError { throw error }
    }

    func deleteMessage(messageRef: String) async throws {
        calls.append("deleteMessage:\(messageRef)")
        deleteCalls.append(messageRef)
        if let error = stubbedError { throw error }
    }

    func fetchAttachment(messageRef: String, partId: String) async throws -> Data {
        calls.append("fetchAttachment:\(messageRef):\(partId)")
        fetchAttachmentCalls.append((ref: messageRef, partId: partId))
        if let error = stubbedError { throw error }
        return stubbedAttachments["\(messageRef):\(partId)"] ?? Data()
    }

    func createFolder(name: String) async throws {
        calls.append("createFolder:\(name)")
        createFolderCalls.append(name)
        if let error = stubbedError { throw error }
    }

    func send(message: OutgoingMessage) async throws {
        calls.append("send")
        sendCalls.append(message)
        if let error = stubbedError { throw error }
    }
}
