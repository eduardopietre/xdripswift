//
//  AlgorithmCoveragePostProcessingTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

final class AlgorithmCoveragePostProcessingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 600)

    // MARK: - Downstream policy

    func testDownstreamPolicyRequiresANewerVisibleReading() {
        XCTAssertFalse(BgReadingDownstreamPolicy.shouldProcess(previousVisibleReadingTimeStamp: base, currentVisibleReadingTimeStamp: nil))
        XCTAssertTrue(BgReadingDownstreamPolicy.shouldProcess(previousVisibleReadingTimeStamp: nil, currentVisibleReadingTimeStamp: base))
        XCTAssertTrue(BgReadingDownstreamPolicy.shouldProcess(previousVisibleReadingTimeStamp: base, currentVisibleReadingTimeStamp: base.addingTimeInterval(1)))
        XCTAssertFalse(BgReadingDownstreamPolicy.shouldProcess(previousVisibleReadingTimeStamp: base, currentVisibleReadingTimeStamp: base))
        XCTAssertFalse(BgReadingDownstreamPolicy.shouldProcess(previousVisibleReadingTimeStamp: base, currentVisibleReadingTimeStamp: base.addingTimeInterval(-1)))
    }

    func testDownstreamGateUnrestrictedAlwaysProcesses() {
        XCTAssertTrue(BgPostProcessingDownstreamGate.unrestricted.shouldProcess(currentVisibleReadingTimeStamp: nil))
        XCTAssertTrue(BgPostProcessingDownstreamGate.newerVisibleReading(previousTimeStamp: nil).shouldProcess(currentVisibleReadingTimeStamp: base))
        XCTAssertFalse(BgPostProcessingDownstreamGate.newerVisibleReading(previousTimeStamp: base).shouldProcess(currentVisibleReadingTimeStamp: base))
        XCTAssertFalse(BgPostProcessingDownstreamGate.newerVisibleReading(previousTimeStamp: nil).shouldProcess(currentVisibleReadingTimeStamp: nil))
    }

    // MARK: - Cadence helpers

    func testFiveMinuteCadenceDetectionUsesTheMedianGap() {
        let manager = makeManager()
        XCTAssertTrue(manager.sourceCanUseFiveMinuteReadings(readingDates: dates(count: 10, spacing: 60)))
        XCTAssertTrue(manager.sourceCanUseFiveMinuteReadings(readingDates: dates(count: 10, spacing: 4.7 * 60)))
        XCTAssertFalse(manager.sourceCanUseFiveMinuteReadings(readingDates: dates(count: 10, spacing: 300)))
        XCTAssertFalse(manager.sourceCanUseFiveMinuteReadings(readingDates: dates(count: 1, spacing: 60)))
        XCTAssertFalse(manager.sourceCanUseFiveMinuteReadings(readingDates: []))
        XCTAssertFalse(manager.sourceCanUseFiveMinuteReadings(readingDates: dates(count: 10, spacing: 30 * 60)))
        let mixed = [0.0, 60, 120, 180, 2000, 2060, 2360, 2660].map { base.addingTimeInterval($0) }
        XCTAssertTrue(manager.sourceCanUseFiveMinuteReadings(readingDates: mixed))
        let duplicates = [0.0, 0, 0, 300, 600].map { base.addingTimeInterval($0) }
        XCTAssertFalse(manager.sourceCanUseFiveMinuteReadings(readingDates: duplicates))
    }

    func testVisibleReadingIndexesKeepOneReadingPerFiveMinutesPerSegment() {
        let manager = makeManager()
        let oneMinute = dates(count: 12, spacing: 60)
        XCTAssertEqual(manager.visibleReadingIndexesAfterApplyingFiveMinuteCadence(readingDates: oneMinute, enableFiveMinuteReadings: false), Array(0..<12))
        XCTAssertEqual(manager.visibleReadingIndexesAfterApplyingFiveMinuteCadence(readingDates: oneMinute, enableFiveMinuteReadings: true), [0, 5, 10])
        let withGap = [0.0, 1, 2, 3, 4, 5, 40, 41, 42, 43, 44, 45].map { base.addingTimeInterval($0 * 60) }
        XCTAssertEqual(manager.visibleReadingIndexesAfterApplyingFiveMinuteCadence(readingDates: withGap, enableFiveMinuteReadings: true), [0, 5, 6, 11])
        XCTAssertEqual(manager.visibleReadingIndexesAfterApplyingFiveMinuteCadence(readingDates: [], enableFiveMinuteReadings: true), [])
    }

    // MARK: - Smoothing through the manager support

    func testSmoothingLeavesMismatchedOrShortInputUnchanged() {
        let manager = makeManager()
        XCTAssertEqual(manager.smoothedValuesSeparatedByReadingGap(values: [1, 2, 3, 4, 5], readingDates: dates(count: 4, spacing: 300), smoothingStrength: 1, smoothingAlgorithm: .savitzkyGolay), [1, 2, 3, 4, 5])
        XCTAssertEqual(manager.smoothedValuesSeparatedByReadingGap(values: [1, 90, 3, 4], readingDates: dates(count: 4, spacing: 300), smoothingStrength: 1, smoothingAlgorithm: .kalman), [1, 90, 3, 4])
    }

    func testMostRecentSmoothedValueIsClampedToTheLiveReading() {
        let manager = makeManager()
        let result = manager.smoothedValuesSeparatedByReadingGap(values: Array(repeating: 100, count: 9) + [40, 100], readingDates: dates(count: 11, spacing: 300), smoothingStrength: 0, smoothingAlgorithm: .savitzkyGolay)
        assertEqual(result, [100, 100, 100, 100, 100, 100, 100, 105.142_857_143, 79.428_571_429, 65.714_285_714, 94], accuracy: 0.000_001)
        let exponential = manager.smoothedValuesSeparatedByReadingGap(values: [0, 0, 0, 0, 100], readingDates: dates(count: 5, spacing: 300), smoothingStrength: 0, smoothingAlgorithm: .exponential)
        XCTAssertEqual(exponential.last ?? 0, 94, accuracy: 0.000_001)
        let strong = manager.smoothedValuesSeparatedByReadingGap(values: [0, 0, 0, 0, 100], readingDates: dates(count: 5, spacing: 300), smoothingStrength: 2, smoothingAlgorithm: .exponential)
        XCTAssertEqual(strong.last ?? 0, 88, accuracy: 0.000_001)
    }

    func testSmoothingStopsAtLongGapsAndSkipsShortSegments() {
        let manager = makeManager()
        let times = [0.0, 5, 10, 15, 20, 25, 60, 65, 70].map { base.addingTimeInterval($0 * 60) }
        let values: [Double] = [0, 0, 21, 0, 0, 0, 150, 90, 160]
        let result = manager.smoothedValuesSeparatedByReadingGap(values: values, readingDates: times, smoothingStrength: 1, smoothingAlgorithm: .savitzkyGolay)
        XCTAssertEqual(Array(result[6...]), [150, 90, 160])
        XCTAssertNotEqual(result[2], 21)
        XCTAssertNotEqual(Array(result[0..<6]), Array(values[0..<6]))
    }

    func testEveryAlgorithmPreservesLinearFiveMinuteTrends() {
        let manager = makeManager()
        let line = (0..<12).map { 80 + 4 * Double($0) }
        for algorithm in [BgSmoothingAlgorithm.savitzkyGolay, .loess, .hampelSavitzkyGolay] {
            for strength in 0...2 {
                assertEqual(manager.smoothedValuesSeparatedByReadingGap(values: line, readingDates: dates(count: 12, spacing: 300), smoothingStrength: strength, smoothingAlgorithm: algorithm), line, accuracy: 0.000_1)
            }
        }
    }

    func testFastCadenceSmoothingPreservesLinesAndDampensSpikes() {
        let manager = makeManager()
        let line = (0..<40).map { 100 + 0.5 * Double($0) }
        for strength in 0...2 {
            assertEqual(manager.smoothedValuesSeparatedByReadingGap(values: line, readingDates: dates(count: 40, spacing: 60), smoothingStrength: strength, smoothingAlgorithm: .savitzkyGolay), line, accuracy: 0.000_1)
        }
        var spiky = Array(repeating: 100.0, count: 40)
        spiky[20] = 160
        for algorithm in BgSmoothingAlgorithm.allCases {
            let result = manager.smoothedValuesSeparatedByReadingGap(values: spiky, readingDates: dates(count: 40, spacing: 60), smoothingStrength: 2, smoothingAlgorithm: algorithm)
            XCTAssertEqual(result.count, 40)
            XCTAssertLessThan(result[20], 160, algorithm.rawValue)
            XCTAssertEqual(result[39], 100, accuracy: 12, algorithm.rawValue)
        }
    }

    func testFastCadenceBlendWeightScalesTheCorrection() {
        let manager = makeManager()
        var spiky = Array(repeating: 100.0, count: 40)
        spiky[20] = 160
        let light = manager.smoothedValuesSeparatedByReadingGap(values: spiky, readingDates: dates(count: 40, spacing: 60), smoothingStrength: 0, smoothingAlgorithm: .savitzkyGolay)
        let strong = manager.smoothedValuesSeparatedByReadingGap(values: spiky, readingDates: dates(count: 40, spacing: 60), smoothingStrength: 2, smoothingAlgorithm: .savitzkyGolay)
        XCTAssertEqual((160 - light[20]) / (160 - strong[20]), 0.35, accuracy: 0.000_001)
    }

    func testHampelThroughManagerRemovesIsolatedSpike() {
        let manager = makeManager()
        var values = (0..<11).map { 100 + Double($0) }
        values[5] = 200
        let result = manager.smoothedValuesSeparatedByReadingGap(values: values, readingDates: dates(count: 11, spacing: 300), smoothingStrength: 1, smoothingAlgorithm: .hampelSavitzkyGolay)
        XCTAssertEqual(result[5], 105, accuracy: 0.5)
        let plain = manager.smoothedValuesSeparatedByReadingGap(values: values, readingDates: dates(count: 11, spacing: 300), smoothingStrength: 1, smoothingAlgorithm: .savitzkyGolay)
        XCTAssertGreaterThan(plain[5], result[5] + 20)
    }

    // MARK: - Processing with Core Data

    @MainActor
    func testProcessingWithoutReadingsDoesNothing() throws {
        try withManager { manager, _, _ in
            let result = manager.processBgReadings(processingStartDateOverride: nil)
            XCTAssertFalse(result.shouldProcessDownstream)
            XCTAssertFalse(result.rewroteDownstreamHistory)
            XCTAssertFalse(manager.hasActiveDownstreamPostProcessing())
            XCTAssertNil(manager.latestActiveBgAdjustment())
        }
    }

    @MainActor
    func testProcessingRecalculatesSlopesWithoutPostProcessing() throws {
        try withManager { manager, core, sensor in
            let readings = insertReadings(core: core, sensor: sensor, values: [100, 105, 115], minutesBeforeNow: [10, 5, 0])
            let result = manager.processBgReadings(processingStartDateOverride: nil)
            XCTAssertTrue(result.shouldProcessDownstream)
            XCTAssertFalse(result.rewroteDownstreamHistory)
            XCTAssertTrue(readings[0].hideSlope)
            XCTAssertEqual(readings[1].calculatedValueSlope * 60_000, 1, accuracy: 0.000_01)
            XCTAssertEqual(readings[2].calculatedValueSlope * 60_000, 2, accuracy: 0.000_01)
            XCTAssertFalse(readings[2].hideSlope)
            XCTAssertNil(readings[2].smoothedValue)
            XCTAssertNil(readings[2].adjustedValue)
        }
    }

    @MainActor
    func testLatestReadingGateSuppressesDownstreamForAlreadySeenReading() throws {
        try withManager { manager, core, sensor in
            let readings = insertReadings(core: core, sensor: sensor, values: [100, 110], minutesBeforeNow: [5, 0])
            XCTAssertFalse(manager.processLatestReadings(previousVisibleReadingTimeStamp: readings[1].timeStamp).shouldProcessDownstream)
            XCTAssertTrue(manager.processLatestReadings(previousVisibleReadingTimeStamp: readings[0].timeStamp).shouldProcessDownstream)
            XCTAssertTrue(manager.processLatestReadings(previousVisibleReadingTimeStamp: nil).shouldProcessDownstream)
        }
    }

    @MainActor
    func testUpdateSmoothingStoresSettingsAndWritesSmoothedValues() throws {
        try withManager { manager, core, sensor in
            UserDefaults.standard.postProcessingApplyFromTimeStamp = sensor.startDate
            let readings = insertReadings(core: core, sensor: sensor, values: [0, 0, 0, 0, 10], minutesBeforeNow: [20, 15, 10, 5, 0])
            manager.updateSmoothing(enableSmoothing: true, useFiveMinuteReadings: false, smoothingPeriodInMinutes: 45, smoothingStrength: 0, smoothingAlgorithm: .exponential)
            XCTAssertTrue(UserDefaults.standard.enableSmoothing)
            XCTAssertEqual(UserDefaults.standard.bgSmoothingPeriodInMinutes, 45)
            XCTAssertEqual(UserDefaults.standard.bgSmoothingStrength, 0)
            XCTAssertEqual(UserDefaults.standard.bgSmoothingAlgorithm, .exponential)
            XCTAssertTrue(manager.hasActiveDownstreamPostProcessing())
            assertEqual(readings.map { $0.smoothedValue?.doubleValue ?? -1 }, [0.648, 1.08, 1.8, 3.0, 7.0], accuracy: 0.000_001)
            XCTAssertEqual(readings[4].finalValue, 7, accuracy: 0.000_001)
            XCTAssertEqual(readings[4].calculatedValue, 10)
            manager.updateSmoothing(enableSmoothing: false, useFiveMinuteReadings: false, smoothingPeriodInMinutes: 45, smoothingStrength: 0, smoothingAlgorithm: .exponential)
            XCTAssertNil(readings[4].smoothedValue)
            XCTAssertEqual(readings[4].finalValue, 10)
            XCTAssertFalse(manager.hasActiveDownstreamPostProcessing())
        }
    }

    @MainActor
    func testApplyOffsetAndScaleUsesShapeCenter() throws {
        try withManager { manager, core, sensor in
            let readings = insertReadings(core: core, sensor: sensor, values: [120, 60], minutesBeforeNow: [5, 0])
            XCTAssertTrue(apply(manager, from: sensor.startDate, offset: 10, slope: 1.5, glucose: true, curve: true, shape: .softerLows))
            XCTAssertEqual(readings[0].adjustedValue?.doubleValue ?? 0, 80 + 1.5 * 40 + 10, accuracy: 0.000_001)
            XCTAssertEqual(readings[1].adjustedValue?.doubleValue ?? 0, 80 + 1.5 * -20 + 10, accuracy: 0.000_001)
            XCTAssertTrue(manager.hasActiveDownstreamPostProcessing())
            XCTAssertEqual(manager.latestActiveBgAdjustment()?.adjustmentShapeType, BgAdjustmentShapeType.softerLows.rawValue)
            XCTAssertTrue(apply(manager, from: sensor.startDate, offset: 0, slope: 1.5, glucose: false, curve: true, shape: .softerHighs))
            XCTAssertEqual(readings[0].adjustedValue?.doubleValue ?? 0, 120, accuracy: 0.000_001)
            XCTAssertEqual(readings[1].adjustedValue?.doubleValue ?? 0, 120 + 1.5 * -60, accuracy: 0.000_001)
        }
    }

    @MainActor
    func testApplyRejectsOutOfRangeScale() throws {
        try withManager { manager, _, sensor in
            XCTAssertFalse(apply(manager, from: sensor.startDate, offset: 0, slope: 1.8, glucose: false, curve: true))
            XCTAssertFalse(apply(manager, from: sensor.startDate, offset: 0, slope: 0.2, glucose: false, curve: true))
            XCTAssertFalse(apply(manager, from: sensor.startDate, offset: 0, slope: .nan, glucose: false, curve: true))
            XCTAssertNil(manager.latestActiveBgAdjustment())
            XCTAssertTrue(apply(manager, from: sensor.startDate, offset: 0, slope: 1.75, glucose: false, curve: true))
            XCTAssertEqual(manager.latestActiveBgAdjustment()?.slope, 1.75)
        }
    }

    @MainActor
    func testLaterAdjustmentOnlyAppliesFromItsStartTime() throws {
        try withManager { manager, core, sensor in
            let readings = insertReadings(core: core, sensor: sensor, values: [100, 100, 100, 100], minutesBeforeNow: [15, 10, 5, 0])
            XCTAssertTrue(apply(manager, from: sensor.startDate, offset: 10))
            XCTAssertEqual(readings.map { $0.finalValue }, [110, 110, 110, 110])
            XCTAssertTrue(apply(manager, from: readings[1].timeStamp.addingTimeInterval(60), offset: 20))
            XCTAssertEqual(readings.map { $0.finalValue }, [110, 110, 120, 120])
            let adjustments = BgAdjustmentsAccessor(coreDataManager: core).getBgAdjustments(forSourceContextIdentifier: try XCTUnwrap(UserDefaults.standard.postProcessingSourceContextIdentifier), on: core.mainManagedObjectContext)
            XCTAssertEqual(adjustments.map(\.intercept), [10, 20])
            XCTAssertTrue(adjustments.allSatisfy(\.isEnabled))
            XCTAssertTrue(apply(manager, from: sensor.startDate.addingTimeInterval(-60), offset: 5))
            XCTAssertEqual(readings.map { $0.finalValue }, [105, 105, 105, 105])
            XCTAssertEqual(manager.latestActiveBgAdjustment()?.intercept, 5)
        }
    }

    @MainActor
    func testApplyWritesAndReplacesPostProcessingNote() throws {
        try withManager { manager, core, sensor in
            _ = insertReadings(core: core, sensor: sensor, values: [100], minutesBeforeNow: [0])
            XCTAssertTrue(apply(manager, from: sensor.startDate, offset: 12.34, slope: 1.234, glucose: true, curve: true))
            let accessor = TreatmentEntryAccessor(coreDataManager: core)
            let first = try XCTUnwrap(accessor.getLatestTreatments(limit: 10).first)
            XCTAssertEqual(first.treatmentType, .Note)
            XCTAssertEqual(first.enteredBy, ConstantsHomeView.applicationName)
            XCTAssertEqual(first.date, sensor.startDate)
            let lines = try XCTUnwrap(first.notes).components(separatedBy: "\n")
            XCTAssertEqual(lines.count, 2)
            XCTAssertTrue(lines[0].hasPrefix("Adjustment: offset 12.3, scale 1.23, emphasis "))
            XCTAssertTrue(lines[0].hasSuffix("Smoothing: disabled."))
            XCTAssertTrue(lines[1].hasPrefix("Applied at "))
            XCTAssertTrue(apply(manager, from: sensor.startDate.addingTimeInterval(-60), offset: 0, glucose: false, smoothing: true, fiveMinute: true))
            let all = accessor.getLatestTreatments(limit: 10)
            XCTAssertEqual(all.count, 2)
            XCTAssertTrue(first.treatmentdeleted)
            XCTAssertFalse(first.uploaded)
            let second = try XCTUnwrap(all.first { !$0.treatmentdeleted })
            XCTAssertTrue(try XCTUnwrap(second.notes).hasPrefix("Adjustment: disabled. Smoothing: " + BgSmoothingAlgorithm.savitzkyGolay.description + ", "))
            XCTAssertTrue(try XCTUnwrap(second.notes).contains(" 5-minute readings: enabled."))
        }
    }

    @MainActor
    func testFiveMinuteCadenceSuppressesAndRestoresFastReadings() throws {
        try withManager { manager, core, sensor in
            let readings = insertReadings(core: core, sensor: sensor, values: Array(repeating: 100, count: 12), minutesBeforeNow: (0..<12).map { Double(11 - $0) })
            XCTAssertTrue(manager.currentSourceCanUseFiveMinuteReadings())
            XCTAssertTrue(apply(manager, from: sensor.startDate, offset: 0, glucose: false, fiveMinute: true))
            XCTAssertEqual(readings.enumerated().filter { !$0.element.isSuppressedByFiveMinuteCadence }.map(\.offset), [0, 5, 10])
            XCTAssertTrue(readings[1].hideSlope)
            XCTAssertTrue(manager.hasActiveDownstreamPostProcessing())
            let visible = BgReadingsAccessor(coreDataManager: core).getLatestBgReadings(limit: nil, fromDate: nil, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: true)
            XCTAssertEqual(visible.count, 3)
            XCTAssertTrue(apply(manager, from: sensor.startDate, offset: 0, glucose: false, fiveMinute: false))
            XCTAssertTrue(readings.allSatisfy { !$0.isSuppressedByFiveMinuteCadence })
            XCTAssertFalse(manager.hasActiveDownstreamPostProcessing())
        }
    }

    @MainActor
    func testExplicitHistoricalPassReportsDownstreamRewrite() throws {
        try withManager { manager, core, sensor in
            _ = insertReadings(core: core, sensor: sensor, values: [100, 104, 108], minutesBeforeNow: [10, 5, 0])
            let explicit = manager.processBgReadings(processingStartDateOverride: sensor.startDate, allowHistoricalDownstreamRewrite: true)
            XCTAssertTrue(explicit.shouldProcessDownstream)
            XCTAssertTrue(explicit.rewroteDownstreamHistory)
            let unchanged = manager.processLatestReadings(previousVisibleReadingTimeStamp: nil)
            XCTAssertTrue(unchanged.shouldProcessDownstream)
            XCTAssertFalse(unchanged.rewroteDownstreamHistory)
            UserDefaults.standard.enableSmoothing = true
            XCTAssertTrue(manager.processLatestReadings(previousVisibleReadingTimeStamp: nil).rewroteDownstreamHistory)
        }
    }

    @MainActor
    func testDexcomG6AndUncalibratedLibreSourcesDisableAdjustment() throws {
        try withManager(transmitter: .dexcom) { manager, core, sensor in
            UserDefaults.standard.activeSensorTransmitterId = "8ABCDE"
            XCTAssertFalse(manager.shouldAllowBgAdjustmentForCurrentSource())
            XCTAssertEqual(manager.bgAdjustmentDisabledMessageForCurrentSource(), Texts_HomeView.postProcessingAdjustmentDisabledBecauseSensorIsCalibrated)
            let reading = insertReadings(core: core, sensor: sensor, values: [100], minutesBeforeNow: [0])[0]
            XCTAssertTrue(apply(manager, from: sensor.startDate, offset: 10))
            XCTAssertNil(reading.adjustedValue)
            XCTAssertFalse(UserDefaults.standard.enableAdjustment)
            XCTAssertFalse(UserDefaults.standard.enableGlucoseAdjustment)
            UserDefaults.standard.activeSensorTransmitterId = "4ABCDE"
            UserDefaults.standard.activeSensorDescription = "Dexcom G6"
            XCTAssertFalse(manager.shouldAllowBgAdjustmentForCurrentSource())
            UserDefaults.standard.activeSensorDescription = "Dexcom ONE"
            XCTAssertTrue(manager.shouldAllowBgAdjustmentForCurrentSource())
            XCTAssertNil(manager.bgAdjustmentDisabledMessageForCurrentSource())
            XCTAssertEqual(manager.currentSourceDescriptionForPostProcessing(), "Dexcom ONE")
        }
        try withManager(transmitter: .Libre2) { manager, _, _ in
            XCTAssertFalse(manager.shouldAllowBgAdjustmentForCurrentSource())
            XCTAssertEqual(manager.bgAdjustmentDisabledMessageForCurrentSource(), Texts_HomeView.postProcessingAdjustmentDisabledUseNativeAlgorithm)
        }
    }

    @MainActor
    func testSourceChangeResetsPostProcessingSettings() throws {
        try withManager { manager, core, sensor in
            let originalIdentifier = try XCTUnwrap(UserDefaults.standard.postProcessingSourceContextIdentifier)
            XCTAssertTrue(originalIdentifier.hasPrefix("master|\(sensor.id)|"))
            XCTAssertTrue(apply(manager, from: sensor.startDate, offset: 10, smoothing: true))
            sensor.endDate = Date()
            let newSensor = Sensor(startDate: Date().addingTimeInterval(-60), nsManagedObjectContext: core.mainManagedObjectContext)
            XCTAssertTrue(core.saveChangesSynchronously())
            manager.refreshSourceContext()
            XCTAssertFalse(UserDefaults.standard.enableSmoothing)
            XCTAssertFalse(UserDefaults.standard.enableAdjustment)
            XCTAssertEqual(UserDefaults.standard.bgSmoothingStrength, ConstantsBgSmoothing.defaultSmoothingStrength)
            XCTAssertEqual(UserDefaults.standard.postProcessingStartTimeStamp, newSensor.startDate)
            XCTAssertEqual(UserDefaults.standard.postProcessingApplyFromTimeStamp, newSensor.startDate)
            XCTAssertNil(UserDefaults.standard.fiveMinuteReadingsStartTimeStamp)
            XCTAssertEqual(UserDefaults.standard.postProcessingSourceContextIdentifier, "master|\(newSensor.id)|\(newSensor.startDate.toMillisecondsAsDouble())")
            XCTAssertTrue(manager.currentSensorForPostProcessing() === newSensor)
            XCTAssertNil(manager.latestActiveBgAdjustment())
        }
    }

    @MainActor
    func testCorrectSensorStartDateKeepsAdjustmentsAttached() throws {
        try withManager { manager, core, sensor in
            XCTAssertTrue(apply(manager, from: sensor.startDate, offset: 15))
            let newStart = sensor.startDate.addingTimeInterval(-3600)
            XCTAssertTrue(manager.correctSensorStartDate(sensor, to: newStart))
            let identifier = "master|\(sensor.id)|\(newStart.toMillisecondsAsDouble())"
            XCTAssertEqual(sensor.startDate, newStart)
            XCTAssertEqual(UserDefaults.standard.postProcessingSourceContextIdentifier, identifier)
            XCTAssertEqual(UserDefaults.standard.activeSensorStartDate, newStart)
            XCTAssertEqual(manager.latestActiveBgAdjustment()?.intercept, 15)
            XCTAssertEqual(BgAdjustmentsAccessor(coreDataManager: core).getBgAdjustments(forSourceContextIdentifier: identifier, on: core.mainManagedObjectContext).count, 1)
            let other = Sensor(startDate: Date().addingTimeInterval(-7200), nsManagedObjectContext: core.mainManagedObjectContext)
            other.endDate = Date()
            XCTAssertFalse(manager.correctSensorStartDate(other, to: Date()))
        }
    }

    @MainActor
    func testFollowerSourceIdentifierAndDescription() throws {
        try withManager(master: false) { manager, _, _ in
            UserDefaults.standard.followerDataSourceType = .calendar
            UserDefaults.standard.calendarFollowCalendarId = "cal-1"
            UserDefaults.standard.followerPatientName = "Kid"
            UserDefaults.standard.postProcessingSourceContextIdentifier = nil
            manager.refreshSourceContext()
            XCTAssertEqual(UserDefaults.standard.postProcessingSourceContextIdentifier, "calendar|cal-1|Kid")
            XCTAssertEqual(manager.currentSourceDescriptionForPostProcessing(), FollowerDataSourceType.calendar.description)
            XCTAssertNil(manager.currentSensorForPostProcessing())
            XCTAssertTrue(manager.shouldAllowBgAdjustmentForCurrentSource())
            XCTAssertFalse(manager.shouldAllowNightscoutBgPostProcessingWrites())
            UserDefaults.standard.followerPatientName = nil
            manager.refreshSourceContext()
            XCTAssertEqual(UserDefaults.standard.postProcessingSourceContextIdentifier, "calendar|cal-1|unknown")
        }
    }

    // MARK: - Helpers

    private func makeManager() -> BgPostProcessingManager {
        BgPostProcessingManager(coreDataManager: CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName), nightscoutSyncManager: nil, healthKitManager: nil)
    }

    private func dates(count: Int, spacing: TimeInterval) -> [Date] {
        (0..<count).map { base.addingTimeInterval(Double($0) * spacing) }
    }

    private func insertReadings(core: CoreDataManager, sensor: Sensor, values: [Double], minutesBeforeNow: [Double]) -> [BgReading] {
        let reference = Date()
        let readings = zip(values, minutesBeforeNow).map { value, minutes -> BgReading in
            let reading = BgReading(timeStamp: reference.addingTimeInterval(-minutes * 60), sensor: sensor, calibration: nil, rawData: value, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = value
            return reading
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        return readings
    }

    @MainActor
    private func apply(_ manager: BgPostProcessingManager, from start: Date, offset: Double, slope: Double = 1, glucose: Bool = true, curve: Bool = false, shape: BgAdjustmentShapeType = .neutral, smoothing: Bool = false, fiveMinute: Bool = false) -> Bool {
        manager.applyPostProcessing(enableGlucoseAdjustment: glucose, enableCurveAdjustment: curve, slope: slope, intercept: offset, adjustmentShapeType: shape, applyFromTimeStamp: start, isBasicAdjustment: false, enteredBgValue: nil, sourceCalculatedValue: nil, enableSmoothing: smoothing, useFiveMinuteReadings: fiveMinute, smoothingPeriodInMinutes: ConstantsBgSmoothing.defaultSmoothingPeriodInMinutes, smoothingStrength: 1, smoothingAlgorithm: .savitzkyGolay)
    }

    @MainActor
    private func withManager(master: Bool = true, transmitter: CGMTransmitterType = .dexcomG7, _ body: (BgPostProcessingManager, CoreDataManager, Sensor) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys: [UserDefaults.Key] = [.isMaster, .transmitterTypeAsString, .enableAdjustment, .enableGlucoseAdjustment,
            .enableCurveAdjustment, .enableSmoothing, .bgSmoothingStrength, .bgSmoothingAlgorithm, .bgSmoothingPeriodInMinutes,
            .useFiveMinuteReadings, .postProcessingSourceContextIdentifier, .activeSensorStartDate, .postProcessingApplyFromTimeStamp,
            .postProcessingStartTimeStamp, .fiveMinuteReadingsStartTimeStamp, .activeSensorTransmitterId, .activeSensorDescription,
            .followerDataSourceType, .calendarFollowCalendarId, .followerPatientName]
        let original = keys.map { ($0.rawValue, defaults.object(forKey: $0.rawValue)) }
        defer { for (key, value) in original { defaults.set(value, forKey: key) } }
        keys.forEach { defaults.removeObject(forKey: $0.rawValue) }
        defaults.isMaster = master
        defaults.cgmTransmitterTypeAsString = transmitter.rawValue
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensor = Sensor(startDate: Date().addingTimeInterval(-2 * 3600), nsManagedObjectContext: core.mainManagedObjectContext)
        XCTAssertTrue(core.saveChangesSynchronously())
        let manager = BgPostProcessingManager(coreDataManager: core, nightscoutSyncManager: nil, healthKitManager: nil)
        manager.refreshSourceContext()
        try body(manager, core, sensor)
    }

    private func assertEqual(_ actual: [Double], _ expected: [Double], accuracy: Double = 0.000_000_1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(pair.0, pair.1, accuracy: accuracy, "index \(index)", file: file, line: line)
        }
    }
}
