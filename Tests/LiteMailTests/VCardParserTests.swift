import XCTest
@testable import LiteMail

final class VCardParserTests: XCTestCase {

    func testBasicVCard() {
        let vcf = """
        BEGIN:VCARD\r
        VERSION:3.0\r
        FN:John Doe\r
        EMAIL;TYPE=INTERNET:john@example.com\r
        TEL;TYPE=CELL:+1-555-0100\r
        ORG:Acme Corp\r
        END:VCARD\r

        """
        let cards = VCardParser.parse(vcf.data(using: .utf8)!)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].fn, "John Doe")
        XCTAssertEqual(cards[0].emails, ["john@example.com"])
        XCTAssertEqual(cards[0].phones, ["+1-555-0100"])
        XCTAssertEqual(cards[0].org, "Acme Corp")
    }

    func testMultipleCards() {
        let vcf = """
        BEGIN:VCARD\r
        FN:Alice\r
        END:VCARD\r
        BEGIN:VCARD\r
        FN:Bob\r
        END:VCARD\r

        """
        let cards = VCardParser.parse(vcf.data(using: .utf8)!)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].fn, "Alice")
        XCTAssertEqual(cards[1].fn, "Bob")
    }

    func testFoldedLines() {
        // RFC 6350: continuation lines start with a single whitespace which is removed on unfold.
        // "FN:John\r\n Doe" (one space) unfolds to "FN:JohnDoe"
        let vcf = "BEGIN:VCARD\r\nFN:John\r\n Doe\r\nEND:VCARD\r\n"
        let cards = VCardParser.parse(vcf.data(using: .utf8)!)
        XCTAssertEqual(cards[0].fn, "JohnDoe")
    }

    func testEmptyData() {
        let cards = VCardParser.parse(Data())
        XCTAssertTrue(cards.isEmpty)
    }
}
