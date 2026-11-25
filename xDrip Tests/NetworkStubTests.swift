//
//  NetworkStubTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 25/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// A flag set from another thread.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Guards the network stub and the waiting helpers that replace fixed sleeps in manager tests.
/// The stub intercepts `URLSession.shared`, like the app's follower and Nightscout managers use it.
final class NetworkStubTests: XCTestCase {

    private func send(_ request: URLRequest, session: URLSession = .shared) async -> (status: Int?, body: String, error: URLError?) {
        await withCheckedContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                continuation.resume(returning: ((response as? HTTPURLResponse)?.statusCode,
                                                data.map { String(decoding: $0, as: UTF8.self) } ?? "",
                                                error as? URLError))
            }.resume()
        }
    }

    private func request(_ method: String, _ url: String, body: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        return request
    }

    func testRoutesAnswerTheSharedSessionAndRecordRequests() async {
        let network = installNetworkStub()
        network.on("POST", host: "ns.test", path: "/api/v1/entries") { request in
            .json("{\"received\": \((request.jsonBody as? [Any])?.count ?? -1)}", status: 201)
        }

        let result = await send(request("POST", "https://ns.test/api/v1/entries?token=abc", body: "[1, 2, 3]"))

        XCTAssertEqual(result.status, 201)
        XCTAssertEqual(result.body, "{\"received\": 3}")
        let recorded = network.requests("POST", path: "/api/v1/entries")
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.query("token"), "abc")
        XCTAssertEqual(recorded.first?.body, Data("[1, 2, 3]".utf8))
    }

    func testRequestsWithoutARouteNeverReachTheNetwork() async {
        let network = installNetworkStub()
        network.on(host: "known.test", reply: .status(204))

        let result = await send(request("GET", "https://unknown.test/anything"))

        XCTAssertNil(result.status)
        XCTAssertEqual(result.error?.code, .notConnectedToInternet)
        XCTAssertEqual(network.unexpectedRequests.map(\.host), ["unknown.test"])
        XCTAssertTrue(network.requests.isEmpty)
    }

    func testFirstRouteThatAnswersWinsAndNilFallsThrough() async {
        let network = installNetworkStub()
        network.on(host: "ns.test") { request in request.path == "/special" ? .status(418) : nil }
        network.on(host: "ns.test", reply: .status(200))

        let special = await send(request("GET", "https://ns.test/special"))
        let other = await send(request("GET", "https://ns.test/other"))

        XCTAssertEqual(special.status, 418)
        XCTAssertEqual(other.status, 200)
    }

    func testFailureResponsesSurfaceAsURLErrors() async {
        let network = installNetworkStub()
        network.on(reply: .failure(.timedOut))

        let result = await send(request("GET", "https://slow.test/"))

        XCTAssertEqual(result.error?.code, .timedOut)
    }

    func testMadeSessionsAreAnsweredToo() async {
        let network = installNetworkStub()
        network.on(reply: .json("{}"))

        let result = await send(request("GET", "https://custom.test/"), session: network.makeSession())

        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(network.requests.count, 1)
    }

    func testUninstalledStubNoLongerAnswers() async {
        let network = NetworkStub.install()
        network.on(reply: .status(200))
        network.uninstall()

        XCTAssertNil(NetworkStub.current)
        // A newer stub takes over the shared session.
        let newer = installNetworkStub()
        newer.on(reply: .status(202))
        let result = await send(request("GET", "https://ns.test/"))
        XCTAssertEqual(result.status, 202)
        XCTAssertTrue(network.requests.isEmpty)
    }

    func testWaitUntilIdleReturnsSoonAfterTheLastRequest() async {
        let network = installNetworkStub()
        network.on(reply: .status(200))
        // Background work like a manager's upload: three requests one after another.
        let work = Task {
            for _ in 0..<3 {
                _ = await self.send(self.request("GET", "https://ns.test/"))
            }
        }

        let started = Date()
        let idle = await network.waitUntilIdle(quietPeriod: 0.05, timeout: 5)
        await work.value

        XCTAssertTrue(idle)
        XCTAssertEqual(network.requests.count, 3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "should not wait for the timeout")
    }

    func testWaitForConditionReturnsAsSoonAsItHolds() async {
        let done = LockedFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done.set() }

        let started = Date()
        let held = await waitForCondition(timeout: 5) { done.isSet }

        XCTAssertTrue(held)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testPollGivesUpAfterTheTimeout() async {
        let started = Date()
        let held = await AsyncTestConditions.poll(timeout: 0.05) { false }

        XCTAssertFalse(held)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.05)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    @MainActor
    func testDrainPendingWorkRunsQueuedMainQueueBlocks() async {
        var ran = false
        DispatchQueue.main.async { ran = true }

        await drainPendingWork()

        XCTAssertTrue(ran)
    }
}
