//
//  AppCoverageUtilitiesTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import OSLog
import SwiftUI
import XCTest
@testable import xdrip

final class AppCoverageUtilitiesTests: XCTestCase {
    private let log = OSLog(subsystem: "AppCoverage", category: "AppCoverage")

    override func setUp() {
        super.setUp()
        appCoverageIsolateDefaults()
    }

    // MARK: - Trace

    private func traceText() -> String {
        Trace.getTraceFilesInData().0.compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    private func line(containing token: String) -> String? {
        traceText().split(separator: "\n").map(String.init).first { $0.contains(token) }
    }

    func testTraceSubstitutesPublicStringIntegerAndDoubleArguments() throws {
        UserDefaults.standard.OSLogEnabled = false
        UserDefaults.standard.NSLogEnabled = false
        let token = UUID().uuidString
        trace("coverage %{public}@ count %{public}d ratio %{public}f end", log: log, category: "AppCoverageCategory", type: .info, token, 42, 1.5)
        let written = try XCTUnwrap(line(containing: token))
        XCTAssertTrue(written.hasSuffix("AppCoverageCategory coverage \(token) count 42 ratio 1.5 end"), written)
    }

    func testTraceKeepsUnfilledPlaceholdersAndIgnoresExtraArguments() throws {
        UserDefaults.standard.NSLogEnabled = false
        let token = UUID().uuidString
        trace("first %{public}@ second %{public}@", log: log, category: "AppCoverage", type: .error, token)
        XCTAssertTrue(try XCTUnwrap(line(containing: token)).hasSuffix("first \(token) second %{public}@"))
        let other = UUID().uuidString
        trace("plain message", log: log, category: other, type: .info, "unused")
        XCTAssertTrue(try XCTUnwrap(line(containing: other)).hasSuffix("\(other) plain message"))
    }

    func testDebugTracesAreOnlyWrittenWhenRequested() {
        UserDefaults.standard.NSLogEnabled = false
        UserDefaults.standard.OSLogEnabled = true
        UserDefaults.standard.addDebugLevelLogsInTraceFileAndNSLog = false
        let hidden = UUID().uuidString
        trace("debug %{public}@", log: log, category: "AppCoverage", type: .debug, hidden)
        XCTAssertNil(line(containing: hidden))
        UserDefaults.standard.addDebugLevelLogsInTraceFileAndNSLog = true
        let shown = UUID().uuidString
        trace("debug %{public}@ %{public}@ %{public}@", log: log, category: "AppCoverage", type: .debug, shown, "b", "c")
        XCTAssertNotNil(line(containing: shown + " b c"))
    }

    func testTraceFilesAreListedInRotationOrder() {
        trace("ensure file exists", log: log, category: "AppCoverage", type: .info)
        let (data, names) = Trace.getTraceFilesInData()
        XCTAssertEqual(data.count, names.count)
        XCTAssertEqual(names.first, ConstantsTrace.traceFileName + ".0.log")
        XCTAssertLessThanOrEqual(names.count, ConstantsTrace.maximumAmountOfTraceFiles)
    }

    func testAppInfoReportsCredentialsOnlyAsPresentOrMissing() throws {
        let defaults = UserDefaults.standard
        let secret = "secret-" + UUID().uuidString
        defaults.isMaster = true
        defaults.nightscoutEnabled = true
        defaults.nightscoutUrl = "https://private-" + secret + ".invalid"
        defaults.nightscoutAPIKey = secret
        defaults.nightscoutToken = nil
        defaults.uploadReadingstoDexcomShare = true
        defaults.dexcomShareAccountName = ""
        defaults.dexcomSharePassword = secret
        defaults.speakReadings = true
        Trace.initialize(coreDataManager: AppCoverageFactory.coreData())
        // Trace keeps the Core Data manager in a global; leave it as the test found it.
        addTeardownBlock { Trace.initialize(coreDataManager: nil) }
        let (data, name) = Trace.getAppInfoFileAsData()
        let text = try XCTUnwrap(data.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(name, ConstantsTrace.appInfoFileName)
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("CGM Data Source: Master"))
        XCTAssertTrue(text.contains("    URL: present"))
        XCTAssertTrue(text.contains("    API_SECRET: present"))
        XCTAssertTrue(text.contains("    Token: missing"))
        XCTAssertTrue(text.contains("    Account name: missing"))
        XCTAssertTrue(text.contains("    Password: present"))
        XCTAssertTrue(text.contains("    Speak interval: "))
        XCTAssertTrue(text.contains("App name: " + ConstantsHomeView.applicationName))
        XCTAssertTrue(text.contains("List of Alarm Types:"))
    }

    // MARK: - Small utilities

    func testKeyValueObserverTimeKeeperRejectsRepeatsWithinDelay() {
        let keeper = KeyValueObserverTimeKeeper()
        XCTAssertTrue(keeper.verifyKey(forKey: "a", withMinimumDelayMilliSeconds: 200))
        XCTAssertFalse(keeper.verifyKey(forKey: "a", withMinimumDelayMilliSeconds: 200))
        XCTAssertTrue(keeper.verifyKey(forKey: "b", withMinimumDelayMilliSeconds: 200))
        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertTrue(keeper.verifyKey(forKey: "a", withMinimumDelayMilliSeconds: 10))
    }

    func testRepeatingTimerFiresUntilSuspended() {
        let fired = expectation(description: "fired twice")
        fired.expectedFulfillmentCount = 2
        fired.assertForOverFulfill = false
        let timer = RepeatingTimer(timeInterval: 0.02) { fired.fulfill() }
        timer.resume()
        timer.resume()
        wait(for: [fired], timeout: 2)
        timer.suspend()
        timer.suspend()
    }

    func testUniqueIdUsesRequestedLengthAndAlphanumerics() {
        let id = UniqueId.createEventId()
        XCTAssertEqual(id.count, 24)
        XCTAssertEqual(UniqueId.createEventId(withLength: 8).count, 8)
        XCTAssertEqual(UniqueId.createEventId(withLength: nil).count, 24)
        XCTAssertTrue(id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
        XCTAssertNotEqual(id, UniqueId.createEventId())
    }

    func testEndpointBuildsUrlAndOmitsZeroPort() throws {
        let endpoint = Endpoint(host: "example.com", scheme: .https, path: "/api/v1/entries", queryItems: [URLQueryItem(name: "count", value: "2")], port: 0)
        XCTAssertEqual(try XCTUnwrap(endpoint.url).absoluteString, "https://example.com/api/v1/entries?count=2")
        let withPort = Endpoint(host: "localhost", scheme: .http, path: "/x", queryItems: [], port: 1337)
        XCTAssertEqual(try XCTUnwrap(withPort.url).absoluteString, "http://localhost:1337/x?")
    }

    func testEndpointSchemeSplitsHostAndScheme() {
        let cases: [(String, String, EndPointScheme?)] = [
            ("https://example.com", "example.com", .https),
            ("http://example.com", "example.com", .http),
            ("HTTPS://Example.com", "Example.com", .https),
            ("https:example.com", "example.com", .https),
            ("example.com", "example.com", nil)
        ]
        for (input, host, scheme) in cases {
            let result = EndPointScheme.getHostAndScheme(hostAndScheme: input)
            XCTAssertEqual(result.0, host, input)
            XCTAssertEqual(result.1, scheme, input)
        }
    }

    func testDebouncerRunsFirstImmediatelyThenOnlyLatestWithinDelay() {
        let queue = DispatchQueue(label: "AppCoverageDebouncer")
        let debouncer = ContactImageManager.Debouncer(delay: 0.3, queue: queue)
        var runs = [String]()
        let first = expectation(description: "first")
        debouncer.debounce { runs.append("first"); first.fulfill() }
        wait(for: [first], timeout: 1)
        let latest = expectation(description: "latest")
        let start = Date()
        debouncer.debounce { runs.append("dropped") }
        debouncer.debounce { runs.append("latest"); latest.fulfill() }
        wait(for: [latest], timeout: 2)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.1)
        queue.sync {}
        XCTAssertEqual(runs, ["first", "latest"])
    }

    // MARK: - Constants with logic

    func testLoessSpanIsOddAndCappedBySampleCount() {
        XCTAssertEqual(ConstantsBgSmoothing.loessSpan(forSmoothingStrength: 2, isFastCadence: true, sampleCount: 100), 11)
        XCTAssertEqual(ConstantsBgSmoothing.loessSpan(forSmoothingStrength: 1, isFastCadence: false, sampleCount: 6), 5)
        XCTAssertEqual(ConstantsBgSmoothing.loessSpan(forSmoothingStrength: 0, isFastCadence: false, sampleCount: 2), 3)
        for strength in 0...2 {
            for count in 1...20 {
                let span = ConstantsBgSmoothing.loessSpan(forSmoothingStrength: strength, isFastCadence: count.isMultiple(of: 2), sampleCount: count)
                XCTAssertFalse(span.isMultiple(of: 2))
                XCTAssertGreaterThanOrEqual(span, 3)
            }
        }
    }

    func testFollowerAppVersionValidationAndDiscoveryURL() {
        XCTAssertTrue(ConstantsFollower.isValidAppVersion("3.8.0"))
        for invalid in ["3.8", "3.8.0.1", "3..0", "a.b.c", "3.8.0 ", "٣.8.0", ""] {
            XCTAssertFalse(ConstantsFollower.isValidAppVersion(invalid), invalid)
        }
        XCTAssertEqual(ConstantsCareLink.carePartnerDiscoveryURL(appVersion: "3.8.0")?.lastPathComponent, "3.8")
        XCTAssertNil(ConstantsCareLink.carePartnerDiscoveryURL(appVersion: "3.8"))
    }

}
