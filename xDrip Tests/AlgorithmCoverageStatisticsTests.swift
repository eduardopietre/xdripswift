//
//  AlgorithmCoverageStatisticsTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

final class AlgorithmCoverageStatisticsTests: XCTestCase {
    private let values: [Double] = [100, 100, 50, 60, 100, 100, 200, 300, 100, 100, 100, 100]
    private var core: CoreDataManager!
    private var savedUnit = true
    private var savedRangeType: Any?

    override func setUp() {
        super.setUp()
        core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        savedUnit = UserDefaults.standard.bloodGlucoseUnitIsMgDl
        savedRangeType = UserDefaults.standard.object(forKey: UserDefaults.Key.timeInRangeType.rawValue)
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = true
        UserDefaults.standard.timeInRangeType = .standardRange
    }

    override func tearDown() {
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = savedUnit
        UserDefaults.standard.set(savedRangeType, forKey: UserDefaults.Key.timeInRangeType.rawValue)
        core = nil
        super.tearDown()
    }

    // MARK: - Report analytics

    @MainActor
    func testReportAnalyticsMomentsAndDistributions() async throws {
        let start = try yesterdayAtTen()
        insert(values, from: start)
        insertExcludedReadings(after: start.addingTimeInterval(3600))
        XCTAssertTrue(core.saveChangesSynchronously())
        let analytics = await StatisticsManager(coreDataManager: core).reportAnalytics(for: configuration())
        let mean = values.reduce(0, +) / 12
        let sd = sqrt(values.map { pow($0 - mean, 2) }.reduce(0, +) / 12)
        XCTAssertTrue(analytics.hasData)
        XCTAssertEqual(analytics.sampleCount, 12)
        XCTAssertEqual(analytics.averageMgDl, 117.5, accuracy: 0.000_001)
        XCTAssertEqual(analytics.standardDeviationMgDl, sd, accuracy: 0.000_001)
        XCTAssertEqual(analytics.coefficientOfVariation, sd / mean * 100, accuracy: 0.000_001)
        XCTAssertEqual(analytics.gmiPercentage, 3.31 + 0.02392 * 117.5, accuracy: 0.000_001)
        XCTAssertEqual(analytics.readingsPerDay, 12.0 / 7, accuracy: 0.000_001)
        XCTAssertEqual(analytics.dataCapturePercentage, 12.0 / 2016 * 100, accuracy: 0.000_001)
        XCTAssertEqual(analytics.firstReading, start)
        XCTAssertEqual(analytics.lastReading, start.addingTimeInterval(55 * 60))
        XCTAssertTrue(analytics.usesMgDl)
        let range = analytics.rangeDistribution
        assertClose([range.veryLow, range.low, range.target, range.high, range.veryHigh].map { $0 * 12 / 100 }, [1, 1, 8, 1, 1].map(Double.init), accuracy: 0.000_001)
        let tight = analytics.tightRangeDistribution
        XCTAssertEqual((tight.veryLow + tight.low) * 12 / 100, 2, accuracy: 0.000_001)
        XCTAssertEqual(tight.target * 12 / 100, 8, accuracy: 0.000_001)
        XCTAssertEqual((tight.high + tight.veryHigh) * 12 / 100, 2, accuracy: 0.000_001)
        XCTAssertEqual(analytics.lowEventCount, 1)
        XCTAssertEqual(analytics.veryLowEventCount, 1)
        XCTAssertEqual(analytics.highEventCount, 1)
        XCTAssertEqual(analytics.veryHighEventCount, 1)
        XCTAssertNil(analytics.aidAnalytics)
        XCTAssertEqual(analytics.sensorCount, 0)
        XCTAssertNil(analytics.averageSensorDuration)
        XCTAssertEqual(analytics.calibrationCount, 0)
    }

    @MainActor
    func testReportAGPPercentilesAndDailyBreakdown() async throws {
        let start = try yesterdayAtTen()
        insert(values, from: start)
        XCTAssertTrue(core.saveChangesSynchronously())
        let analytics = await StatisticsManager(coreDataManager: core).reportAnalytics(for: configuration())
        XCTAssertEqual(analytics.agpPoints.map(\.minuteOfDay), [600, 630])
        let morning = try XCTUnwrap(analytics.agpPoints.first)
        assertClose([morning.p5MgDl, morning.p25MgDl, morning.medianMgDl, morning.p75MgDl, morning.p95MgDl], [52.5, 70, 100, 100, 100], accuracy: 0.000_001)
        let later = try XCTUnwrap(analytics.agpPoints.last)
        assertClose([later.p5MgDl, later.p25MgDl, later.medianMgDl, later.p75MgDl, later.p95MgDl], [100, 100, 100, 175, 275], accuracy: 0.000_001)
        XCTAssertEqual(analytics.dailySummaries.count, 7)
        let day = try XCTUnwrap(analytics.dailySummaries.first { $0.sampleCount > 0 })
        XCTAssertEqual(day.date, Calendar.current.startOfDay(for: start))
        XCTAssertEqual(day.sampleCount, 12)
        XCTAssertEqual(day.averageMgDl, 117.5, accuracy: 0.000_001)
        XCTAssertEqual(day.targetPercentage, 800.0 / 12, accuracy: 0.000_001)
        XCTAssertEqual(day.lowPercentage, 200.0 / 12, accuracy: 0.000_001)
        XCTAssertEqual(day.highPercentage, 200.0 / 12, accuracy: 0.000_001)
        XCTAssertEqual(analytics.dailySummaries.filter { $0.sampleCount == 0 }.count, 6)
        XCTAssertEqual(analytics.dailyGlucoseProfiles.count, 7)
        let profile = try XCTUnwrap(analytics.dailyGlucoseProfiles.first { !$0.points.isEmpty })
        XCTAssertEqual(profile.points.map(\.minuteOfDay), (0..<12).map { 600 + $0 * 5 })
        XCTAssertEqual(profile.points.map(\.valueMgDl), values)
    }

    @MainActor
    func testTrendPointsNeedTwelveSamplesInOneBucket() async throws {
        insert(values, from: Date().addingTimeInterval(-3 * 86_400 + 60))
        XCTAssertTrue(core.saveChangesSynchronously())
        let manager = StatisticsManager(coreDataManager: core)
        let analytics = await manager.reportAnalytics(for: configuration())
        XCTAssertEqual(analytics.trendPoints.count, 1)
        let point = try XCTUnwrap(analytics.trendPoints.first)
        XCTAssertEqual(point.interval, .daily)
        XCTAssertEqual(point.sampleCount, 12)
        XCTAssertEqual(point.averageMgDl, 117.5, accuracy: 0.000_001)
        XCTAssertNil(point.averageTDDPerDay)
        XCTAssertNil(point.averageCarbsPerDay)
        let fewer = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        insert(Array(values.prefix(11)), from: Date().addingTimeInterval(-3 * 86_400 + 60), into: fewer)
        XCTAssertTrue(fewer.saveChangesSynchronously())
        let sparse = await StatisticsManager(coreDataManager: fewer).reportAnalytics(for: configuration())
        XCTAssertTrue(sparse.trendPoints.isEmpty)
        XCTAssertEqual(sparse.sampleCount, 11)
    }

    @MainActor
    func testLongerPeriodsUseWiderTrendBuckets() async throws {
        insert(values, from: Date().addingTimeInterval(-10 * 86_400))
        XCTAssertTrue(core.saveChangesSynchronously())
        let manager = StatisticsManager(coreDataManager: core)
        let thirty = await manager.reportAnalytics(for: configuration(period: .thirty))
        XCTAssertEqual(thirty.trendPoints.map(\.interval), [.threeDay])
        XCTAssertEqual(thirty.dailySummaries.count, 30)
        XCTAssertEqual(thirty.readingsPerDay, 12.0 / 30, accuracy: 0.000_001)
        let ninety = await manager.reportAnalytics(for: configuration(period: .ninety))
        XCTAssertEqual(ninety.trendPoints.map(\.interval), [.weekly])
        let seven = await manager.reportAnalytics(for: configuration(period: .seven))
        XCTAssertFalse(seven.hasData)
        XCTAssertEqual(seven.sampleCount, 0)
        XCTAssertTrue(seven.agpPoints.isEmpty)
        XCTAssertEqual(seven.averageMgDl, 0)
    }

    @MainActor
    func testSeparatedLowEpisodesCountAsSeparateEvents() async throws {
        let start = Date().addingTimeInterval(-6 * 3600)
        insert([60, 100, 60, 100, 100, 100, 100, 60, 260, 100, 100, 260], from: start)
        XCTAssertTrue(core.saveChangesSynchronously())
        let analytics = await StatisticsManager(coreDataManager: core).reportAnalytics(for: configuration())
        XCTAssertEqual(analytics.lowEventCount, 2)
        XCTAssertEqual(analytics.veryLowEventCount, 0)
        XCTAssertEqual(analytics.highEventCount, 1)
        XCTAssertEqual(analytics.veryHighEventCount, 1)
    }

    @MainActor
    func testSensorPeriodsAreMergedAndCalibrationsCounted() async throws {
        let now = Date()
        insert([100], from: now.addingTimeInterval(-3600))
        let a = Sensor(startDate: now.addingTimeInterval(-5 * 86_400), nsManagedObjectContext: core.mainManagedObjectContext)
        a.endDate = now.addingTimeInterval(-3 * 86_400)
        let b = Sensor(startDate: now.addingTimeInterval(-3 * 86_400 + 600), nsManagedObjectContext: core.mainManagedObjectContext)
        b.endDate = now.addingTimeInterval(-86_400)
        let c = Sensor(startDate: now.addingTimeInterval(-12 * 3600), nsManagedObjectContext: core.mainManagedObjectContext)
        let old = Sensor(startDate: now.addingTimeInterval(-30 * 86_400), nsManagedObjectContext: core.mainManagedObjectContext)
        old.endDate = now.addingTimeInterval(-20 * 86_400)
        for minutes in [60.0, 120] {
            _ = Calibration(timeStamp: now.addingTimeInterval(-minutes * 60), sensor: c, bg: 100, rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1, rawTimeStamp: now, slope: 1, intercept: 0, distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 100, slopeConfidence: 1, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        let analytics = await StatisticsManager(coreDataManager: core).reportAnalytics(for: configuration())
        XCTAssertEqual(analytics.sensorCount, 2)
        XCTAssertEqual(analytics.averageSensorDuration ?? 0, (4 * 86_400 + 12 * 3600) / 2, accuracy: 10)
        XCTAssertEqual(analytics.calibrationCount, 2)
    }

    @MainActor
    func testReportAnalyticsCacheIsInvalidatedBySaves() async throws {
        insert([100, 110], from: Date().addingTimeInterval(-3600))
        XCTAssertTrue(core.saveChangesSynchronously())
        let manager = StatisticsManager(coreDataManager: core)
        let first = await manager.reportAnalytics(for: configuration())
        XCTAssertEqual(first.sampleCount, 2)
        insert([120], from: Date().addingTimeInterval(-60))
        XCTAssertTrue(core.saveChangesSynchronously())
        let second = await manager.reportAnalytics(for: configuration())
        XCTAssertEqual(second.sampleCount, 3)
        manager.invalidate()
        let third = await manager.reportAnalytics(for: configuration())
        XCTAssertEqual(third.sampleCount, 3)
        let snapshots = await manager.nightscoutLoopSnapshots(for: configuration())
        XCTAssertTrue(snapshots.deviceStatuses.isEmpty)
        XCTAssertTrue(snapshots.profiles.isEmpty)
    }

    @MainActor
    func testAvailableReportPeriodsRequireSeventyPercentCoverage() async throws {
        let end = Date()
        insert(Array(repeating: 120, count: 7 * 288 - 10), from: end.addingTimeInterval(-7 * 86_400 + 3000))
        XCTAssertTrue(core.saveChangesSynchronously())
        let availability = await StatisticsManager(coreDataManager: core).availableReportPeriods()
        XCTAssertEqual(availability[.seven], true)
        XCTAssertEqual(availability[.thirty], false)
        XCTAssertEqual(availability[.oneYear], false)
        XCTAssertEqual(availability.count, GlucoseReportPeriod.allCases.count)
        let empty = await StatisticsManager(coreDataManager: CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)).availableReportPeriods()
        XCTAssertTrue(empty.values.allSatisfy { !$0 })
    }

    // MARK: - Home statistics

    @MainActor
    func testRootStatisticsInMgDlAndMmol() async throws {
        insert(values, from: Date().addingTimeInterval(-2 * 3600))
        XCTAssertTrue(core.saveChangesSynchronously())
        let manager = StatisticsManager(coreDataManager: core)
        let mean = values.reduce(0, +) / 12
        let sd = sqrt(values.map { pow($0 - mean, 2) }.reduce(0, +) / 12)
        let mgDl = await rootStatistics(manager)
        XCTAssertEqual(mgDl.lowStatisticValue, 200.0 / 12, accuracy: 0.000_001)
        XCTAssertEqual(mgDl.inRangeStatisticValue, 800.0 / 12, accuracy: 0.000_001)
        XCTAssertEqual(mgDl.highStatisticValue, 200.0 / 12, accuracy: 0.000_001)
        XCTAssertEqual(mgDl.averageStatisticValue, 117.5, accuracy: 0.000_001)
        XCTAssertEqual(mgDl.cVStatisticValue, sd / mean * 100, accuracy: 0.000_001)
        XCTAssertEqual(mgDl.gmiPercentage, 3.31 + 0.02392 * 117.5, accuracy: 0.000_001)
        XCTAssertEqual(mgDl.estimatedHbA1cPercentage, (117.5 + 46.7) / 28.7, accuracy: 0.000_001)
        XCTAssertEqual(mgDl.lowLimitForTIR, 70)
        XCTAssertEqual(mgDl.highLimitForTIR, 180)
        XCTAssertEqual(mgDl.numberOfDaysUsed, 0, "two hours of readings are less than one full day")
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = false
        let mmol = await rootStatistics(manager)
        XCTAssertEqual(mmol.averageStatisticValue, 117.5 * ConstantsBloodGlucose.mgDlToMmoll, accuracy: 0.000_001)
        XCTAssertEqual(mmol.cVStatisticValue, mgDl.cVStatisticValue, accuracy: 0.000_001)
        XCTAssertEqual(mmol.inRangeStatisticValue, mgDl.inRangeStatisticValue, accuracy: 0.000_001)
        XCTAssertEqual(mmol.lowLimitForTIR, 3.9)
        XCTAssertEqual(mmol.gmiPercentage, mgDl.gmiPercentage, accuracy: 0.000_001)
    }

    @MainActor
    func testRootStatisticsTightRangeAndEmptyStore() async throws {
        let manager = StatisticsManager(coreDataManager: core)
        let empty = await rootStatistics(manager)
        XCTAssertEqual([empty.lowStatisticValue, empty.inRangeStatisticValue, empty.highStatisticValue, empty.averageStatisticValue, empty.gmiPercentage], [0, 0, 0, 0, 0])
        XCTAssertEqual(empty.numberOfDaysUsed, 0)
        insert(values, from: Date().addingTimeInterval(-2 * 3600))
        XCTAssertTrue(core.saveChangesSynchronously())
        UserDefaults.standard.timeInRangeType = .tightRange
        let tight = await rootStatistics(manager)
        XCTAssertEqual(tight.highLimitForTIR, ConstantsStatistics.standardisedHighValueForTITRInMgDl)
        XCTAssertEqual(tight.inRangeStatisticValue, 800.0 / 12, accuracy: 0.000_001)
        XCTAssertEqual(tight.highStatisticValue, 200.0 / 12, accuracy: 0.000_001)
    }

    @MainActor
    func testDailyTIRReturnsOneEntryPerDay() async throws {
        let start = try yesterdayAtTen()
        insert([70, 100, 180, 181, 69, 100], from: start)
        XCTAssertTrue(core.saveChangesSynchronously())
        let manager = StatisticsManager(coreDataManager: core)
        let fromDate = Calendar.current.date(byAdding: .day, value: -2, to: start)!
        let daily: [Date: StatisticsManager.Statistics] = await withCheckedContinuation { continuation in
            manager.calculateDailyTIR(fromDate: fromDate, toDate: Date()) { continuation.resume(returning: $0) }
        }
        XCTAssertGreaterThanOrEqual(daily.count, 3)
        let day = try XCTUnwrap(daily[Calendar.current.startOfDay(for: start)])
        XCTAssertEqual(day.numberOfDaysUsed, 1)
        XCTAssertEqual(day.inRangeStatisticValue, 400.0 / 6, accuracy: 0.000_001)
        XCTAssertEqual(day.lowStatisticValue, 100.0 / 6, accuracy: 0.000_001)
        XCTAssertEqual(day.highStatisticValue, 100.0 / 6, accuracy: 0.000_001)
        XCTAssertEqual(day.averageStatisticValue, 700.0 / 6, accuracy: 0.000_001)
        let emptyDay = try XCTUnwrap(daily[Calendar.current.startOfDay(for: fromDate)])
        XCTAssertEqual(emptyDay.numberOfDaysUsed, 0)
        XCTAssertEqual(emptyDay.inRangeStatisticValue, 0)
    }

    // MARK: - Landscape

    @MainActor
    func testLandscapeBaselineUsesOnlyCompleteEarlierDays() async throws {
        let start = try yesterdayAtTen()
        insert(values, from: start)
        insert(values, from: Calendar.current.date(byAdding: .day, value: -1, to: start)!)
        XCTAssertTrue(core.saveChangesSynchronously())
        let manager = StatisticsManager(coreDataManager: core)
        let baseline = await manager.landscapeBaseline(referenceDate: Date(), daysBack: 7)
        XCTAssertEqual(baseline.dayCount, 2)
        XCTAssertEqual(baseline.agpPoints.count, 2)
        XCTAssertTrue(baseline.usesMgDl)
        let excludingYesterday = await manager.landscapeBaseline(referenceDate: start, daysBack: 7)
        XCTAssertEqual(excludingYesterday.dayCount, 1)
        let none = await manager.landscapeBaseline(referenceDate: start, daysBack: 0)
        XCTAssertEqual(none.dayCount, 0)
        XCTAssertTrue(none.agpPoints.isEmpty)
    }

    @MainActor
    func testLandscapeAnalyticsSummarisesSelectedDay() async throws {
        let start = try yesterdayAtTen()
        insert(values, from: start)
        insert([300, 300, 300], from: Calendar.current.date(byAdding: .day, value: -1, to: start)!)
        XCTAssertTrue(core.saveChangesSynchronously())
        let analytics = await StatisticsManager(coreDataManager: core).landscapeAnalytics(referenceDate: start, daysBack: 3, includesAID: false)
        XCTAssertEqual(analytics.averageMgDl ?? 0, 117.5, accuracy: 0.000_001)
        XCTAssertEqual(analytics.rangeSummary.timeInRange.inRangePercentage, 800.0 / 12, accuracy: 0.000_001)
        XCTAssertEqual(analytics.rangeSummary.timeInTightRange.abovePercentage, 200.0 / 12, accuracy: 0.000_001)
        XCTAssertEqual(analytics.baseline.dayCount, 1)
        XCTAssertEqual(analytics.baseline.agpPoints.map(\.medianMgDl), [300])
        XCTAssertNil(analytics.loopalyzer)
        let emptyDay = await StatisticsManager(coreDataManager: core).landscapeAnalytics(referenceDate: Date().addingTimeInterval(-20 * 86_400), daysBack: 1, includesAID: false)
        XCTAssertNil(emptyDay.averageMgDl)
        XCTAssertEqual(emptyDay.rangeSummary, .empty)
    }

    // MARK: - Helpers

    private func configuration(period: GlucoseReportPeriod = .seven) -> GlucoseReportConfiguration {
        GlucoseReportConfiguration(patientName: "Coverage", patientID: "", period: period, aidPeriod: .notIncluded, paperSize: .a4, language: .english)
    }

    private func insert(_ values: [Double], from start: Date, spacing: TimeInterval = 300, into manager: CoreDataManager? = nil) {
        let target = manager ?? core!
        for (index, value) in values.enumerated() {
            let reading = BgReading(timeStamp: start.addingTimeInterval(Double(index) * spacing), sensor: nil, calibration: nil, rawData: value, deviceName: nil, nsManagedObjectContext: target.mainManagedObjectContext)
            reading.calculatedValue = value
        }
    }

    private func insertExcludedReadings(after date: Date) {
        for (offset, value) in [(0.0, 30.0), (300, 500), (600, 250), (900, 0)] {
            let reading = BgReading(timeStamp: date.addingTimeInterval(offset), sensor: nil, calibration: nil, rawData: 100, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = value
            reading.isSuppressedByFiveMinuteCadence = value == 250
        }
    }

    private func yesterdayAtTen() throws -> Date {
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: today))
        return try XCTUnwrap(Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: yesterday))
    }

    private func rootStatistics(_ manager: StatisticsManager) async -> StatisticsManager.Statistics {
        await withCheckedContinuation { continuation in
            manager.calculateStatistics(fromDate: Date().addingTimeInterval(-7 * 86_400), toDate: Date()) { continuation.resume(returning: $0) }
        }
    }
}

private func assertClose(_ actual: [Double], _ expected: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (left, right) in zip(actual, expected) {
        XCTAssertEqual(left, right, accuracy: accuracy, file: file, line: line)
    }
}
