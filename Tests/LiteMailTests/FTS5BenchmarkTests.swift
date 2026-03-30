import XCTest
import GRDB
@testable import LiteMail

final class FTS5BenchmarkTests: XCTestCase {

    private var store: MailStore!
    private var dbPath: String!

    override func setUp() async throws {
        dbPath = NSTemporaryDirectory() + "litemail_bench_\(UUID().uuidString).sqlite"
        store = try MailStore(path: dbPath)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    // MARK: - Benchmark: Insert 50k rows, then search

    func testFTS5SearchPerformanceOn50kEmails() async throws {
        // Step 1: Insert 50,000 emails with realistic content
        let batchSize = 1000
        let totalEmails = 50_000

        let subjects = [
            "API migration timeline update",
            "Weekly standup notes",
            "Quarterly revenue report Q3",
            "Bug fix: OAuth token refresh",
            "Design review: new dashboard layout",
            "Infrastructure cost optimization",
            "Customer feedback analysis",
            "Sprint planning for next iteration",
            "Security audit findings",
            "Performance benchmark results",
        ]

        let bodies = [
            "We discussed the Kubernetes deployment strategy and decided to go with a rolling update approach.",
            "The new API endpoints are ready for review. Please check the breaking changes in the auth module.",
            "Revenue increased by 23% compared to last quarter. Key drivers were enterprise accounts.",
            "Fixed the token refresh bug that caused silent failures when the session expired after 30 minutes.",
            "The dashboard redesign focuses on information hierarchy. Attached are the updated wireframes.",
            "Moving to spot instances could save us approximately $4,200 per month on compute costs.",
            "Users consistently request better search functionality. Top complaint is slow email search.",
            "Next sprint priorities: IMAP IDLE support, incremental sync, and command palette polish.",
            "No critical vulnerabilities found. Two medium-severity issues in the OAuth flow need attention.",
            "FTS5 search latency measured at 2.3ms for single-term queries across 100k documents.",
        ]

        let senders = [
            "alice@company.com", "bob@startup.io", "carol@enterprise.org",
            "dave@dev.team", "eve@security.firm", "frank@ops.center",
            "grace@design.co", "henry@sales.biz", "iris@support.help",
            "jack@engineering.dev",
        ]

        print("Inserting \(totalEmails) emails...")
        let insertStart = Date()

        for batch in 0..<(totalEmails / batchSize) {
            for i in 0..<batchSize {
                let index = batch * batchSize + i
                let record = EmailRecord(
                    messageId: "<msg-\(index)@benchmark.test>",
                    threadId: "thread-\(index / 5)", // 5 messages per thread
                    folder: "INBOX",
                    senderName: nil,
                    senderEmail: senders[index % senders.count],
                    subject: subjects[index % subjects.count],
                    date: Int(Date().timeIntervalSince1970) - (totalEmails - index) * 60,
                    isRead: index % 3 == 0,
                    isStarred: index % 10 == 0,
                    isDeleted: false,
                    hasAttachments: index % 7 == 0
                )
                let id = try await store.insertEmail(record)

                // Insert body for every email (simulating full backfill)
                try await store.insertBody(
                    emailId: id,
                    text: bodies[index % bodies.count],
                    html: nil
                )
            }
        }

        let insertDuration = Date().timeIntervalSince(insertStart)
        print("Insert complete: \(totalEmails) emails in \(String(format: "%.2f", insertDuration))s")
        print("Rate: \(Int(Double(totalEmails) / insertDuration)) emails/sec")

        // Step 2: Warm the FTS5 cache
        try await store.warmSearchCache()

        // Step 3: Benchmark single-term search
        let searchTerms = ["Kubernetes", "OAuth", "revenue", "dashboard", "security"]
        var totalSearchTime: TimeInterval = 0
        let iterations = 50

        for term in searchTerms {
            let searchStart = Date()
            for _ in 0..<(iterations / searchTerms.count) {
                let results = try await store.search(query: term)
                XCTAssertGreaterThan(results.count, 0, "Search for '\(term)' should return results")
            }
            let elapsed = Date().timeIntervalSince(searchStart)
            totalSearchTime += elapsed
        }

        let avgSearchMs = (totalSearchTime / Double(iterations)) * 1000
        print("Average search latency: \(String(format: "%.2f", avgSearchMs))ms over \(iterations) queries")
        print("Target: <5ms")

        // Step 4: Assert <5ms average (warm cache)
        XCTAssertLessThan(avgSearchMs, 5.0, "FTS5 search should be under 5ms on 50k emails (warm cache)")

        // Step 5: Also test a search that returns no results (different code path)
        let noResultStart = Date()
        let noResults = try await store.search(query: "xyznonexistent")
        let noResultMs = Date().timeIntervalSince(noResultStart) * 1000
        XCTAssertTrue(noResults.isEmpty)
        print("No-result search latency: \(String(format: "%.2f", noResultMs))ms")

        // Step 6: Report email count to confirm
        let count = try await store.emailCount()
        XCTAssertEqual(count, totalEmails)
        print("Verified: \(count) emails in store")
    }
}
