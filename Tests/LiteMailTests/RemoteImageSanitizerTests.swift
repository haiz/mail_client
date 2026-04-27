import XCTest
@testable import LiteMail

final class RemoteImageSanitizerTests: XCTestCase {

    func testPassthroughWhenBlockingDisabled() {
        let html = #"<img src="https://example.com/track.png">"#
        let (result, count) = RemoteImageSanitizer.sanitize(html, blockImages: false)
        XCTAssertEqual(result, html)
        XCTAssertEqual(count, 0)
    }

    func testBlocksRemoteImgSrc() {
        let html = #"<img src="https://example.com/track.png">"#
        let (result, count) = RemoteImageSanitizer.sanitize(html, blockImages: true)
        // The img src= must now point to the placeholder, not the remote URL
        XCTAssertTrue(result.contains(#"src="data:"#), "src= must use placeholder")
        XCTAssertTrue(result.contains("data-blocked-src"), "should set data-blocked-src")
        XCTAssertTrue(result.contains("data:image/gif;base64,"), "should use transparent placeholder")
        XCTAssertEqual(count, 1)
    }

    func testBlocksHttpImgSrc() {
        let html = #"<img src="http://example.com/img.jpg">"#
        let (result, count) = RemoteImageSanitizer.sanitize(html, blockImages: true)
        XCTAssertTrue(result.contains(#"src="data:"#), "src= must use placeholder")
        XCTAssertTrue(result.contains("data-blocked-src"))
        XCTAssertEqual(count, 1)
    }

    func testPassesCidUrls() {
        let html = #"<img src="cid:abc@example.com">"#
        let (result, count) = RemoteImageSanitizer.sanitize(html, blockImages: true)
        XCTAssertTrue(result.contains("cid:abc@example.com"), "cid: URLs must not be blocked")
        XCTAssertEqual(count, 0)
    }

    func testPassesDataUrls() {
        let html = #"<img src="data:image/png;base64,abc123">"#
        let (result, count) = RemoteImageSanitizer.sanitize(html, blockImages: true)
        XCTAssertTrue(result.contains("data:image/png;base64,abc123"), "data: URLs must not be blocked")
        XCTAssertEqual(count, 0)
    }

    func testBlocksSrcset() {
        let html = #"<img srcset="https://example.com/img.png 2x">"#
        let (result, count) = RemoteImageSanitizer.sanitize(html, blockImages: true)
        XCTAssertTrue(result.contains("data-blocked-srcset="), "srcset must be replaced with data-blocked-srcset")
        XCTAssertEqual(count, 1)
    }

    func testBlocksVideoPoster() {
        let html = #"<video poster="https://example.com/thumb.jpg">"#
        let (result, count) = RemoteImageSanitizer.sanitize(html, blockImages: true)
        XCTAssertTrue(result.contains("data-blocked-poster="), "poster must be replaced with data-blocked-poster")
        XCTAssertEqual(count, 1)
    }

    func testBlocksCssUrlInStyle() {
        let html = #"<div style="background: url(https://example.com/bg.png)"></div>"#
        let (result, count) = RemoteImageSanitizer.sanitize(html, blockImages: true)
        XCTAssertFalse(result.contains("https://example.com/bg.png"))
        XCTAssertEqual(count, 1)
    }

    func testCountsMultipleBlocked() {
        let html = """
        <img src="https://a.com/1.png">
        <img src="https://b.com/2.png">
        """
        let (_, count) = RemoteImageSanitizer.sanitize(html, blockImages: true)
        XCTAssertEqual(count, 2)
    }
}
