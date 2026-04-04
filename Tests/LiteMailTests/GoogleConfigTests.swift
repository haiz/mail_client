// Tests/LiteMailTests/GoogleConfigTests.swift
import XCTest
@testable import LiteMail

final class GoogleConfigTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "googleClientId")
        super.tearDown()
    }

    func testBundledClientIdUsedByDefault() {
        UserDefaults.standard.removeObject(forKey: "googleClientId")
        XCTAssertFalse(GoogleConfig.clientId.isEmpty)
        XCTAssertEqual(GoogleConfig.clientId, GoogleConfig.bundledClientId)
    }

    func testUserDefaultsOverridesTakePrecedence() {
        UserDefaults.standard.set("custom-client-id", forKey: "googleClientId")
        XCTAssertEqual(GoogleConfig.clientId, "custom-client-id")
    }

    func testClearingOverrideRestoresBundled() {
        UserDefaults.standard.set("custom-client-id", forKey: "googleClientId")
        UserDefaults.standard.removeObject(forKey: "googleClientId")
        XCTAssertEqual(GoogleConfig.clientId, GoogleConfig.bundledClientId)
    }

    func testScopesIncludeRequired() {
        XCTAssertTrue(GoogleConfig.scopes.contains("https://mail.google.com/"))
        XCTAssertTrue(GoogleConfig.scopes.contains("openid"))
        XCTAssertTrue(GoogleConfig.scopes.contains("email"))
        XCTAssertTrue(GoogleConfig.scopes.contains("profile"))
        XCTAssertTrue(GoogleConfig.scopes.contains("https://www.googleapis.com/auth/contacts.readonly"))
    }
}
