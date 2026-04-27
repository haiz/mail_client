import XCTest
@testable import LiteMail

final class SearchQueryParserTests: XCTestCase {

    func testPlainFTS() {
        let q = SearchQueryParser.parse("hello world")
        XCTAssertEqual(q.ftsQuery, "hello world")
        XCTAssertTrue(q.predicates.isEmpty)
    }

    func testQuotedFTS() {
        let q = SearchQueryParser.parse("\"hello world\"")
        XCTAssertEqual(q.ftsQuery, "\"hello world\"")
        XCTAssertTrue(q.predicates.isEmpty)
    }

    func testFromOperator() {
        let q = SearchQueryParser.parse("from:alice@example.com")
        XCTAssertNil(q.ftsQuery)
        XCTAssertEqual(q.predicates.count, 1)
        XCTAssertEqual(q.predicates[0].kind, .from)
        XCTAssertEqual(q.predicates[0].value, "alice@example.com")
    }

    func testToOperator() {
        let q = SearchQueryParser.parse("to:bob@example.com")
        XCTAssertEqual(q.predicates[0].kind, .to)
        XCTAssertEqual(q.predicates[0].value, "bob@example.com")
    }

    func testSubjectWithQuotes() {
        let q = SearchQueryParser.parse("subject:\"hello world\"")
        XCTAssertEqual(q.predicates[0].kind, .subject)
        XCTAssertEqual(q.predicates[0].value, "hello world")
    }

    func testHasAttachment() {
        let q = SearchQueryParser.parse("has:attachment")
        XCTAssertEqual(q.predicates[0].kind, .hasAttachment)
        XCTAssertEqual(q.predicates[0].value, "1")
    }

    func testIsUnread() {
        let q = SearchQueryParser.parse("is:unread")
        XCTAssertEqual(q.predicates[0].kind, .isUnread)
    }

    func testIsStarred() {
        let q = SearchQueryParser.parse("is:starred")
        XCTAssertEqual(q.predicates[0].kind, .isStarred)
    }

    func testBeforeDate() {
        let q = SearchQueryParser.parse("before:2026-01-01")
        XCTAssertEqual(q.predicates[0].kind, .before)
        XCTAssertFalse(q.predicates[0].value.isEmpty)
        // Value should be a unix timestamp near 2026-01-01
        let ts = Int(q.predicates[0].value) ?? 0
        XCTAssertGreaterThan(ts, 1_700_000_000)
    }

    func testBeforeDateSlash() {
        let q = SearchQueryParser.parse("before:2026/01/01")
        XCTAssertEqual(q.predicates[0].kind, .before)
        XCTAssertFalse(q.predicates[0].value.isEmpty)
    }

    func testAfterDate() {
        let q = SearchQueryParser.parse("after:2025-12-01")
        XCTAssertEqual(q.predicates[0].kind, .after)
        XCTAssertFalse(q.predicates[0].value.isEmpty)
    }

    func testOlderThanDays() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let q = SearchQueryParser.parse("older_than:7d", now: now)
        XCTAssertEqual(q.predicates[0].kind, .before)
        let ts = Int(q.predicates[0].value) ?? 0
        let expected = Int(now.timeIntervalSince1970) - 7 * 86400
        XCTAssertEqual(ts, expected, accuracy: 2)
    }

    func testOlderThanWeeks() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let q = SearchQueryParser.parse("older_than:2w", now: now)
        let ts = Int(q.predicates[0].value) ?? 0
        let expected = Int(now.timeIntervalSince1970) - 14 * 86400
        XCTAssertEqual(ts, expected, accuracy: 2)
    }

    func testOlderThanMonths() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let q = SearchQueryParser.parse("older_than:1m", now: now)
        let ts = Int(q.predicates[0].value) ?? 0
        let expected = Int(now.timeIntervalSince1970) - 30 * 86400
        XCTAssertEqual(ts, expected, accuracy: 2)
    }

    func testNewerThan() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let q = SearchQueryParser.parse("newer_than:3d", now: now)
        XCTAssertEqual(q.predicates[0].kind, .after)
        let ts = Int(q.predicates[0].value) ?? 0
        let expected = Int(now.timeIntervalSince1970) - 3 * 86400
        XCTAssertEqual(ts, expected, accuracy: 2)
    }

    func testMixedOperatorsAndFTS() {
        let q = SearchQueryParser.parse("from:alice invoice has:attachment")
        XCTAssertEqual(q.ftsQuery, "invoice")
        XCTAssertEqual(q.predicates.count, 2)
        XCTAssertEqual(q.predicates[0].kind, .from)
        XCTAssertEqual(q.predicates[1].kind, .hasAttachment)
    }

    func testChipsPopulated() {
        let q = SearchQueryParser.parse("from:alice is:unread")
        XCTAssertEqual(q.chips.count, 2)
        XCTAssertTrue(q.chips[0].hasPrefix("from:"))
        XCTAssertTrue(q.chips[1].hasPrefix("is:"))
    }

    func testMalformedHasIgnored() {
        let q = SearchQueryParser.parse("has:garbage more text")
        XCTAssertEqual(q.ftsQuery, "has:garbage more text")
        XCTAssertTrue(q.predicates.isEmpty)
    }

    func testMalformedIsIgnored() {
        let q = SearchQueryParser.parse("is:bogus hello")
        XCTAssertEqual(q.ftsQuery, "is:bogus hello")
        XCTAssertTrue(q.predicates.isEmpty)
    }

    func testEmptyQuery() {
        let q = SearchQueryParser.parse("")
        XCTAssertNil(q.ftsQuery)
        XCTAssertTrue(q.predicates.isEmpty)
    }

    func testInFolder() {
        let q = SearchQueryParser.parse("in:archive")
        XCTAssertEqual(q.predicates[0].kind, .inFolder)
        XCTAssertEqual(q.predicates[0].value, "archive")
    }

    func testCaseInsensitiveOperator() {
        let q = SearchQueryParser.parse("FROM:alice@example.com")
        XCTAssertEqual(q.predicates[0].kind, .from)
        XCTAssertEqual(q.predicates[0].value, "alice@example.com")
    }
}
