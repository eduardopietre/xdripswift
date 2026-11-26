//
//  DailyTimeInRangeTests.swift
//  xdripTests
//
//  Created by eduardopietre on 26/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

/// Regression tests for the daily time in range in mmol/L.
///
/// The daily statistics classified readings converted to mmol/L against the rounded mmol/L limits
/// (3.9 and 10.0), so a reading of exactly 70 mg/dL (3.885 mmol/L) counted as low. The root
/// statistics classify in mg/dL against the mg/dL limits, so the same day gave another time in
/// range depending on the unit.
final class DailyTimeInRangeTests: XCTestCase {

    private var core: CoreDataManager!
    private var savedUnit = true
    private var savedRangeType: Any?

    override func setUp() {
        super.setUp()
        core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        savedUnit = UserDefaults.standard.bloodGlucoseUnitIsMgDl
        savedRangeType = UserDefaults.standard.object(forKey: UserDefaults.Key.timeInRangeType.rawValue)
        UserDefaults.standard.timeInRangeType = .standardRange
    }

    override func tearDown() {
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = savedUnit
        UserDefaults.standard.set(savedRangeType, forKey: UserDefaults.Key.timeInRangeType.rawValue)
        core = nil
        super.tearDown()
    }

    @MainActor
    func testBoundaryReadingsAreClassifiedTheSameInMmolAsInMgDl() async throws {
        let start = try yesterdayAtTen()
        // 70 and 180 are in range, 69 is low, 181 is high
        for (index, value) in [70.0, 100, 180, 181, 69, 100].enumerated() {
            let reading = BgReading(timeStamp: start.addingTimeInterval(Double(index) * 300), sensor: nil, calibration: nil, rawData: value, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = value
        }
        XCTAssertTrue(core.saveChangesSynchronously())

        for isMgDl in [true, false] {
            UserDefaults.standard.bloodGlucoseUnitIsMgDl = isMgDl
            let day = try await dailyStatistics(for: start)
            XCTAssertEqual(day.inRangeStatisticValue, 400.0 / 6, accuracy: 0.000_001, "mg/dL: \(isMgDl)")
            XCTAssertEqual(day.lowStatisticValue, 100.0 / 6, accuracy: 0.000_001, "mg/dL: \(isMgDl)")
            XCTAssertEqual(day.highStatisticValue, 100.0 / 6, accuracy: 0.000_001, "mg/dL: \(isMgDl)")
        }
        // the average is still shown in the user's unit
        let day = try await dailyStatistics(for: start)
        XCTAssertEqual(day.averageStatisticValue, 700.0 / 6 * ConstantsBloodGlucose.mgDlToMmoll, accuracy: 0.000_001)
    }

    @MainActor
    private func dailyStatistics(for date: Date) async throws -> StatisticsManager.Statistics {
        let manager = StatisticsManager(coreDataManager: core)
        let daily: [Date: StatisticsManager.Statistics] = await withCheckedContinuation { continuation in
            manager.calculateDailyTIR(fromDate: Calendar.current.startOfDay(for: date), toDate: Date()) { continuation.resume(returning: $0) }
        }
        return try XCTUnwrap(daily[Calendar.current.startOfDay(for: date)])
    }

    private func yesterdayAtTen() throws -> Date {
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: today))
        return try XCTUnwrap(Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: yesterday))
    }
}
