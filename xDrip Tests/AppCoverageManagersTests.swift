//
//  AppCoverageManagersTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import HealthKit
import SwiftUI
import UIKit
import WatchConnectivity
import XCTest
@testable import xdrip

@MainActor
final class AppCoverageManagersTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        appCoverageIsolateDefaults()
    }

    private func mainQueueHop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: - Watch

    private func watchManager(_ core: CoreDataManager) -> WatchManager {
        WatchManager(coreDataManager: core, nightscoutSyncManager: NightscoutSyncManager(coreDataManager: core, messageHandler: nil))
    }

    private func reply(_ manager: WatchManager, to message: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            manager.session(WCSession.default, didReceiveMessage: message) { continuation.resume(returning: $0) }
        }
    }

    private func watchReading(seconds: UInt32, mgDl: Double = 120) -> DirectWatchReading {
        let start = Date().addingTimeInterval(-86_400)
        return DirectWatchReading(transmitterID: "8ABCDE", sensorStartCounter: 1000, sensorStartDate: start, transmitterSeconds: seconds, measuredAt: start.addingTimeInterval(Double(seconds)), mgDl: mgDl, state: 6)
    }

    func testWatchLinkProbeIsEchoed() async {
        let manager = watchManager(AppCoverageFactory.coreData())
        let response = await reply(manager, to: ["directWatchLinkProbe": 12.5])
        XCTAssertEqual(response["directWatchLinkProbe"] as? Double, 12.5)
    }

    func testWatchBatchAcknowledgesOnlyImportedReadings() async throws {
        let manager = watchManager(AppCoverageFactory.coreData())
        let readings = [watchReading(seconds: 300), watchReading(seconds: 600)]
        var imported = [DirectWatchReading]()
        manager.importDirectWatchReadings = { batch in
            imported = batch
            return [batch[1].id]
        }
        let response = await reply(manager, to: ["directWatchReadings": try JSONEncoder().encode(readings)])
        XCTAssertEqual(imported, readings)
        XCTAssertEqual(response["directWatchAcknowledged"] as? [String], [readings[1].id])
    }

    func testMalformedWatchBatchIsNotImported() async {
        let manager = watchManager(AppCoverageFactory.coreData())
        var called = false
        manager.importDirectWatchReadings = { _ in called = true; return [] }
        let response = await reply(manager, to: ["directWatchReadings": Data("not json".utf8)])
        XCTAssertFalse(called)
        XCTAssertNil(response["directWatchAcknowledged"])
        let oversized = await reply(manager, to: ["directWatchReadings": Data(count: 100_001)])
        XCTAssertNil(oversized["directWatchAcknowledged"])
        XCTAssertFalse(called)
    }

    func testWatchStatusIsStoredTruncated() async {
        let manager = watchManager(AppCoverageFactory.coreData())
        manager.session(WCSession.default, didReceiveUserInfo: ["directWatchStatus": String(repeating: "x", count: 600)])
        await mainQueueHop()
        XCTAssertEqual(UserDefaults.standard.string(forKey: DirectWatchSettings.lastStatusKey)?.count, 500)
        XCTAssertNotNil(UserDefaults.standard.object(forKey: DirectWatchSettings.lastStatusDateKey))
        manager.session(WCSession.default, didReceiveMessageData: Data())
    }

    // MARK: - Live Activity

    // MARK: - HealthKit

    // MARK: - Contact image

    private func pixels(_ data: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, rgba)
    }

    private func countPixels(_ data: Data, matching predicate: (Int, Int, Int) -> Bool) throws -> Int {
        let image = try pixels(data)
        var count = 0
        for index in stride(from: 0, to: image.rgba.count, by: 4) where predicate(Int(image.rgba[index]), Int(image.rgba[index + 1]), Int(image.rgba[index + 2])) {
            count += 1
        }
        return count
    }

    private func renderer(value: Double = 120, upToDate: Bool = true, highContrast: Bool = false, disabled: Bool = false, range: BgRangeDescription = .inRange, arrow: String = "→") -> ContactImageRenderer {
        ContactImageRenderer(bgValue: value, isMgDl: true, slopeArrow: arrow, bgRangeDescription: range, valueIsUpToDate: upToDate, useHighContrastContactImage: highContrast, disableContactImage: disabled)
    }

    func testContactImageIsA256PointBlackSquare() throws {
        let data = try XCTUnwrap(renderer().pngData())
        let image = try pixels(data)
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 256)
        XCTAssertEqual(Array(image.rgba[0..<3]), [0, 0, 0], "Corners stay black")
    }

    func testDisabledContactImageShowsCyanOffOrWhiteInHighContrast() throws {
        let cyanish: (Int, Int, Int) -> Bool = { r, g, b in r < 80 && g > 150 && b > 180 }
        let whiteish: (Int, Int, Int) -> Bool = { r, g, b in r > 230 && g > 230 && b > 230 }
        let off = try XCTUnwrap(renderer(disabled: true).pngData())
        XCTAssertGreaterThan(try countPixels(off, matching: cyanish), 50)
        XCTAssertEqual(try countPixels(off, matching: whiteish), 0)
        let highContrast = try XCTUnwrap(renderer(highContrast: true, disabled: true).pngData())
        XCTAssertGreaterThan(try countPixels(highContrast, matching: whiteish), 50)
        XCTAssertEqual(try countPixels(highContrast, matching: cyanish), 0)
    }

    func testHighContrastImageIsWhiteWhileColouredImageIsNot() throws {
        let whiteish: (Int, Int, Int) -> Bool = { r, g, b in r > 230 && g > 230 && b > 230 }
        XCTAssertGreaterThan(try countPixels(try XCTUnwrap(renderer(highContrast: true).pngData()), matching: whiteish), 50)
        XCTAssertEqual(try countPixels(try XCTUnwrap(renderer(range: .urgent).pngData()), matching: whiteish), 0)
    }

    func testRangeAndFreshnessChangeTheRenderedImage() throws {
        let inRange = try XCTUnwrap(renderer(range: .inRange).pngData())
        let urgent = try XCTUnwrap(renderer(range: .urgent).pngData())
        let stale = try XCTUnwrap(renderer(upToDate: false).pngData())
        let missing = try XCTUnwrap(renderer(value: 0).pngData())
        XCTAssertNotEqual(inRange, urgent)
        XCTAssertNotEqual(inRange, stale)
        XCTAssertNotEqual(stale, missing)
        XCTAssertNotEqual(try XCTUnwrap(renderer(value: 250).pngData()), try XCTUnwrap(renderer(value: 250, arrow: "").pngData()))
    }

    func testMmolContactImageRendersDifferentText() throws {
        let mgdl = try XCTUnwrap(renderer(value: 180).pngData())
        let mmol = try XCTUnwrap(ContactImageRenderer(bgValue: 180, isMgDl: false, slopeArrow: "", bgRangeDescription: .inRange, valueIsUpToDate: true, useHighContrastContactImage: false, disableContactImage: false).pngData())
        XCTAssertNotEqual(mgdl, mmol)
    }

    // MARK: - Application coordinator

}
