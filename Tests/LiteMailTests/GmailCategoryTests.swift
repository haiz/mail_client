import XCTest
@testable import LiteMail

final class GmailCategoryTests: XCTestCase {

    func testAllCasesHaveDistinctRawValues() {
        let raws = GmailCategory.allCases.map { $0.rawValue }
        XCTAssertEqual(Set(raws).count, raws.count)
        XCTAssertEqual(raws.count, 6)
    }

    func testRawValueRoundTrip() {
        for c in GmailCategory.allCases {
            XCTAssertEqual(GmailCategory(rawValue: c.rawValue), c)
        }
    }

    func testLabelIdMappingMatchesGmailSystemLabels() {
        XCTAssertEqual(GmailCategory.personal.labelId,   "CATEGORY_PERSONAL")
        XCTAssertEqual(GmailCategory.promotions.labelId, "CATEGORY_PROMOTIONS")
        XCTAssertEqual(GmailCategory.social.labelId,     "CATEGORY_SOCIAL")
        XCTAssertEqual(GmailCategory.updates.labelId,    "CATEGORY_UPDATES")
        XCTAssertEqual(GmailCategory.forums.labelId,     "CATEGORY_FORUMS")
        XCTAssertEqual(GmailCategory.purchases.labelId,  "CATEGORY_PURCHASES")
    }

    func testSearchTokenForPersonalIsPrimary() {
        // Gmail's `q=category:` accepts "primary" not "personal"
        XCTAssertEqual(GmailCategory.personal.searchToken, "primary")
    }

    func testSearchTokenForOtherCategoriesMatchesRawValue() {
        XCTAssertEqual(GmailCategory.promotions.searchToken, "promotions")
        XCTAssertEqual(GmailCategory.social.searchToken,     "social")
        XCTAssertEqual(GmailCategory.updates.searchToken,    "updates")
        XCTAssertEqual(GmailCategory.forums.searchToken,     "forums")
        XCTAssertEqual(GmailCategory.purchases.searchToken,  "purchases")
    }

    func testVirtualFolderIdRoundTrip() {
        for c in GmailCategory.allCases {
            let id = c.virtualFolderId
            XCTAssertTrue(id.hasPrefix("gmail:category:"))
            XCTAssertEqual(GmailCategory(virtualFolderId: id), c)
        }
        XCTAssertNil(GmailCategory(virtualFolderId: "INBOX"))
        XCTAssertNil(GmailCategory(virtualFolderId: "gmail:category:bogus"))
    }
}
