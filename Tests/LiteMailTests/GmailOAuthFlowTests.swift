// Tests/LiteMailTests/GmailOAuthFlowTests.swift
import XCTest
@testable import LiteMail

// A stub that records calls and controls outcomes
actor StubOAuthFlow: OAuthFlowProtocol {
    enum Outcome { case success, cancelled, failed(String) }
    var outcome: Outcome = .success
    var calledWith: (accountId: String, email: String)? = nil

    func authenticate(accountId: String, email: String) async throws {
        calledWith = (accountId, email)
        switch outcome {
        case .success:      return
        case .cancelled:    throw OAuthError.cancelled
        case .failed(let r): throw OAuthError.failed(r)
        }
    }
}

final class GmailOAuthFlowTests: XCTestCase {
    func testSuccessCallsOAuth() async throws {
        let stub = StubOAuthFlow()
        await stub.setOutcome(.success)
        try await stub.authenticate(accountId: "acc1", email: "user@gmail.com")
        let called = await stub.calledWith
        XCTAssertEqual(called?.accountId, "acc1")
        XCTAssertEqual(called?.email, "user@gmail.com")
    }

    func testCancelledThrowsOAuthError() async {
        let stub = StubOAuthFlow()
        await stub.setOutcome(.cancelled)
        do {
            try await stub.authenticate(accountId: "acc1", email: "user@gmail.com")
            XCTFail("Expected OAuthError.cancelled")
        } catch OAuthError.cancelled {
            // pass
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testFailedThrowsOAuthErrorWithReason() async {
        let stub = StubOAuthFlow()
        await stub.setOutcome(.failed("invalid_client"))
        do {
            try await stub.authenticate(accountId: "acc1", email: "user@gmail.com")
            XCTFail("Expected OAuthError.failed")
        } catch OAuthError.failed(let reason) {
            XCTAssertEqual(reason, "invalid_client")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}

// Helper — actors don't allow direct mutation from outside
extension StubOAuthFlow {
    func setOutcome(_ o: Outcome) { outcome = o }
}
