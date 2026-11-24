//
//  NightscoutCredentialsCheckTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for the "verify" action in the Nightscout settings.
///
/// Issue #636: with a URL and an access token (no API_SECRET), verifying answered 401 "Token is
/// not valid" although the token was correct. The check sent the token as plain text in the
/// `api-secret` header, which Nightscout only accepts as an API_SECRET hash or, in recent versions
/// only, as a token it finds in its database. Syncing itself passes the token as the `token` query
/// parameter, which every Nightscout version accepts, so the check rejected working settings.
final class NightscoutCredentialsCheckTests: XCTestCase {

    private let path = "/api/v1/experiments/test"

    // MARK: - token (#636)

    func testTokenIsSentAsQueryParameterLikeTheSync() throws {
        let request = try XCTUnwrap(NightscoutCredentialsCheck.request(siteURL: "https://example.us.nightscoutpro.com", port: 0, hashedAPISecret: nil, token: "follower-07bd5d239ab9e", path: path))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "token", value: "follower-07bd5d239ab9e")])
        XCTAssertNil(request.value(forHTTPHeaderField: "api-secret"), "a token is not an API_SECRET")
    }

    func testTokenRequestKeepsPortAndPath() throws {
        let request = try XCTUnwrap(NightscoutCredentialsCheck.request(siteURL: "https://example.com", port: 1337, hashedAPISecret: nil, token: "follower-07bd5d239ab9e", path: path))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "example.com")
        XCTAssertEqual(components.port, 1337)
        XCTAssertEqual(components.path, path)
    }

    // MARK: - API_SECRET

    func testAPISecretHashIsSentInHeaderAndTakesPrecedence() throws {
        let request = try XCTUnwrap(NightscoutCredentialsCheck.request(siteURL: "https://example.com", port: 0, hashedAPISecret: "0123456789abcdef", token: "follower-07bd5d239ab9e", path: path))

        XCTAssertEqual(request.value(forHTTPHeaderField: "api-secret"), "0123456789abcdef")
        XCTAssertNil(try XCTUnwrap(request.url).query)
    }

    func testInvalidURLProducesNoRequest() {
        XCTAssertNil(NightscoutCredentialsCheck.request(siteURL: "", port: 0, hashedAPISecret: nil, token: nil, path: path))
    }
}
