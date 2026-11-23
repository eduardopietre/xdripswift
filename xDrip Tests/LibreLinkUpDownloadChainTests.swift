//
//  LibreLinkUpDownloadChainTests.swift
//  xdripTests
//
//  Created by eduardopietre on 22/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for LibreLinkUp download scheduling.
///
/// Every `download()` ends by scheduling the next one. Extra calls (the app returning to the
/// foreground, a manual refresh) must not leave several timers running in parallel. Before the
/// fix each extra call added a timer that kept rescheduling itself, so a follower left running
/// for hours made dozens of LibreLinkUp downloads per minute until the app was restarted.
final class LibreLinkUpDownloadChainTests: XCTestCase {

    /// Standard defaults changed by the test, restored afterwards.
    private let keys: [UserDefaults.Key] = [.isMaster, .followerDataSourceType, .libreLinkUpEmail, .libreLinkUpPassword,
                                            .libreLinkUpManuallyLoggedOut, .libreLinkUpPreventLogin,
                                            .followerBackgroundKeepAliveType, .libreLinkUpRegion]
    private var saved: [String: Any] = [:]

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in keys { saved[key.rawValue] = defaults.object(forKey: key.rawValue) }

        // A LibreLinkUp follower with credentials, so download() passes its guards.
        defaults.isMaster = false
        defaults.followerDataSourceType = .libreLinkUp
        defaults.libreLinkUpEmail = "follower@example.invalid"
        defaults.libreLinkUpPassword = "password"
        defaults.libreLinkUpManuallyLoggedOut = false
        defaults.libreLinkUpPreventLogin = false

        // Heartbeat mode never schedules the 60 s timer; the timer is only used with the other modes.
        defaults.followerBackgroundKeepAliveType = .normal

        // No real LibreView traffic: every request fails at once.
        FailingLibreLinkUpProtocol.reset()
        URLProtocol.registerClass(FailingLibreLinkUpProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(FailingLibreLinkUpProtocol.self)
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = saved[key.rawValue] { defaults.set(value, forKey: key.rawValue) } else { defaults.removeObject(forKey: key.rawValue) }
        }
        super.tearDown()
    }

    // MARK: - Download scheduling

    /// Regression: three calls, like the first download and two returns to the foreground. After
    /// the next timer interval exactly one more download must start, not three.
    ///
    /// This test waits for the real 60 s timer, so it takes about a minute.
    @MainActor
    func testRegressionExtraDownloadCallsDoNotMultiplyTheTimer() async throws {
        // No initial download, so the test controls every call.
        let manager = CountingLibreLinkUpFollowManager(coreDataManager: CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName),
                                               followerDelegate: NoOpFollowerDelegate(),
                                               backgroundKeepAliveManager: NoOpKeepAliveManager(),
                                               startsInitialDownload: false)

        // Each call fails on the network and then schedules the next download, as a real one would.
        for _ in 0..<3 { manager.download() }
        try await waitForRequests(3, timeout: 10)
        XCTAssertEqual(manager.downloadCount, 3)

        // Let the 60 s timers fire. Count download() runs, not requests: a failed login can
        // block later login requests, so a download may end before reaching the network.
        try await Task.sleep(nanoseconds: 62 * 1_000_000_000)
        XCTAssertEqual(manager.downloadCount - 3, 1, "downloads started by the timers after one interval")
    }

    // MARK: - Helpers

    /// Wait until `count` LibreView requests have been made, then a little longer for each
    /// download to finish and schedule its timer.
    private func waitForRequests(_ count: Int, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while FailingLibreLinkUpProtocol.requestCount < count {
            guard Date() < deadline else { return XCTFail("only \(FailingLibreLinkUpProtocol.requestCount) requests") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // Let each failed download reach its rescheduling step on the main actor.
        try await Task.sleep(nanoseconds: 500_000_000)
    }
}

// MARK: - Test doubles

/// Fails every LibreView request at once and counts them.
private final class FailingLibreLinkUpProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset() { lock.lock(); count = 0; lock.unlock() }

    // Only LibreView hosts; any other request in the test process goes through untouched.
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.contains("libreview") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// Counts every download, including those started by the manager's own timers, which call
/// `download()` through its Objective-C selector and so reach this override.
private final class CountingLibreLinkUpFollowManager: LibreLinkUpFollowManager {
    private(set) var downloadCount = 0
    override func download() {
        downloadCount += 1
        super.download()
    }
}

/// Satisfies the manager's initializer; no reading is delivered because every request fails.
private final class NoOpFollowerDelegate: FollowerDelegate {
    func followerInfoReceived(followGlucoseDataArray: inout [FollowerBgReading]) {}
}

/// Satisfies the manager's initializer without playing any keep-alive audio.
private final class NoOpKeepAliveManager: FollowerBackgroundKeepAliveManaging {
    func start(for source: FollowerBackgroundKeepAliveSource, backgroundRefresh: (() -> Void)?) {}
    func stop(for source: FollowerBackgroundKeepAliveSource) {}
}
