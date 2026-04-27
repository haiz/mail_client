import XCTest
@testable import LiteMail

final class ICSParserTests: XCTestCase {

    func testBasicEvent() {
        let ics = """
        BEGIN:VCALENDAR\r
        BEGIN:VEVENT\r
        SUMMARY:Team Meeting\r
        DTSTART:20260501T140000Z\r
        DTEND:20260501T150000Z\r
        LOCATION:Conference Room B\r
        ORGANIZER:MAILTO:boss@example.com\r
        END:VEVENT\r
        END:VCALENDAR\r

        """
        let events = ICSParser.parse(ics.data(using: .utf8)!)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].summary, "Team Meeting")
        XCTAssertEqual(events[0].location, "Conference Room B")
        XCTAssertEqual(events[0].organizer, "boss@example.com")
        XCTAssertNotNil(events[0].start)
        XCTAssertNotNil(events[0].end)
    }

    func testAllDayEvent() {
        let ics = """
        BEGIN:VCALENDAR\r
        BEGIN:VEVENT\r
        SUMMARY:Holiday\r
        DTSTART;VALUE=DATE:20260601\r
        END:VEVENT\r
        END:VCALENDAR\r

        """
        let events = ICSParser.parse(ics.data(using: .utf8)!)
        XCTAssertEqual(events.count, 1)
        XCTAssertNotNil(events[0].start)
        XCTAssertNil(events[0].end)
    }

    func testMultipleEvents() {
        let ics = """
        BEGIN:VCALENDAR\r
        BEGIN:VEVENT\r
        SUMMARY:Event 1\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        SUMMARY:Event 2\r
        END:VEVENT\r
        END:VCALENDAR\r

        """
        let events = ICSParser.parse(ics.data(using: .utf8)!)
        XCTAssertEqual(events.count, 2)
    }

    func testEscapedCharacters() {
        let ics = """
        BEGIN:VCALENDAR\r
        BEGIN:VEVENT\r
        SUMMARY:Meet\\, Greet\r
        END:VEVENT\r
        END:VCALENDAR\r

        """
        let events = ICSParser.parse(ics.data(using: .utf8)!)
        XCTAssertEqual(events[0].summary, "Meet, Greet")
    }

    func testEmptyData() {
        let events = ICSParser.parse(Data())
        XCTAssertTrue(events.isEmpty)
    }
}
