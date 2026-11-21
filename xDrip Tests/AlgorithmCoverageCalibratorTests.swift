//
//  AlgorithmCoverageCalibratorTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

final class AlgorithmCoverageCalibratorTests: XCTestCase {
    private let now = Date()
    private var core: CoreDataManager!
    private var context: NSManagedObjectContext { core.mainManagedObjectContext }

    override func setUp() {
        super.setUp()
        core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
    }

    override func tearDown() {
        core = nil
        super.tearDown()
    }

    // MARK: - Calibrator identity and parameters

    func testCalibratorDescriptionsDividersAndAgeAdjustment() {
        let calibrators: [(Calibrator, String, Bool)] = [
            (DexcomCalibrator(), "DexcomCalibrator", true),
            (Libre1Calibrator(), "Libre1Calibrator", false),
            (Libre1NonFixedSlopeCalibrator(), "Libre1NonFixedSlopeCalibrator", false),
            (NoCalibrator(), "NoCalibrator", false)
        ]
        for (calibrator, name, ageAdjustment) in calibrators {
            XCTAssertEqual(calibrator.description(), name)
            XCTAssertEqual(calibrator.rawValueDivider, 1000)
            XCTAssertEqual(calibrator.ageAdjustMentNeeded, ageAdjustment, name)
            XCTAssertEqual(calibrator.sParams.DEFAULT_SLOPE, 1, name)
        }
    }

    func testSlopeParametersBoundTheExpectedRanges() {
        let dexcom = DexcomCalibrator().sParams
        XCTAssertLessThan(dexcom.LOW_SLOPE_2, dexcom.LOW_SLOPE_1)
        XCTAssertLessThan(dexcom.HIGH_SLOPE_1, dexcom.HIGH_SLOPE_2)
        XCTAssertEqual(dexcom.DEFAUL_HIGH_SLOPE_LOW, 1.2)
        XCTAssertEqual(dexcom.DEFAULT_HIGH_SLOPE_HIGH, 1.3)
        let nonFixed = Libre1NonFixedSlopeCalibrator().sParams
        XCTAssertEqual(nonFixed.LOW_SLOPE_1, 0.55)
        XCTAssertEqual(nonFixed.HIGH_SLOPE_2, 1.6)
        let libre = Libre1Calibrator().sParams
        XCTAssertEqual([libre.LOW_SLOPE_1, libre.LOW_SLOPE_2, libre.HIGH_SLOPE_1, libre.HIGH_SLOPE_2], [1, 1, 1, 1])
    }

    // MARK: - createNewBgReading (protocol extension)

    func testUncalibratedReadingDividesRawDataAndInitialisesCurves() {
        var last3 = [BgReading]()
        var calibrations = [Calibration]()
        let reading = Libre1Calibrator().createNewBgReading(rawData: 150_000, timeStamp: now, sensor: nil, last3Readings: &last3, lastCalibrationsForActiveSensorInLastXDays: &calibrations, firstCalibration: nil, lastCalibration: nil, deviceName: "dev", nsManagedObjectContext: context)
        XCTAssertEqual(reading.rawData, 150)
        XCTAssertEqual(reading.ageAdjustedRawValue, 150)
        XCTAssertEqual(reading.calculatedValue, 0)
        XCTAssertEqual(reading.deviceName, "dev")
        XCTAssertEqual([reading.a, reading.b, reading.c], [0, 0, 0])
        XCTAssertEqual([reading.ra, reading.rb, reading.rc], [0, 0, 105])
        XCTAssertTrue(reading.hideSlope)
        XCTAssertEqual(reading.calculatedValueSlope, 0)
    }

    func testReadingWithoutTimestampUsesCurrentDate() {
        var last3 = [BgReading]()
        var calibrations = [Calibration]()
        let before = Date()
        let reading = Libre1Calibrator().createNewBgReading(rawData: 1000, timeStamp: nil, sensor: nil, last3Readings: &last3, lastCalibrationsForActiveSensorInLastXDays: &calibrations, firstCalibration: nil, lastCalibration: nil, deviceName: nil, nsManagedObjectContext: context)
        XCTAssertGreaterThanOrEqual(reading.timeStamp, before)
        XCTAssertLessThanOrEqual(reading.timeStamp, Date())
    }

    func testDexcomAgeAdjustmentScalesYoungSensorRawValues() {
        let youngSensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let reading = newReading(DexcomCalibrator(), raw: 150_000, sensor: youngSensor)
        let adjustFor = ConstantsCalibrationAlgorithms.ageAdjustmentTime - 86_400_000
        let expected = ConstantsCalibrationAlgorithms.ageAdjustmentFactor * (adjustFor / ConstantsCalibrationAlgorithms.ageAdjustmentTime) * 150 + 150
        XCTAssertEqual(reading.ageAdjustedRawValue, expected, accuracy: 0.000_01)
        XCTAssertEqual(reading.ageAdjustedRawValue, 150 * (1 + 0.45 * 0.9 / 1.9), accuracy: 0.000_01)
    }

    func testAgeAdjustmentIsSkippedForOldSensorsLibreAndMissingSensor() {
        let oldSensor = Sensor(startDate: now.addingTimeInterval(-3 * 86_400), nsManagedObjectContext: context)
        let youngSensor = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: context)
        XCTAssertEqual(newReading(DexcomCalibrator(), raw: 150_000, sensor: oldSensor).ageAdjustedRawValue, 150)
        XCTAssertEqual(newReading(DexcomCalibrator(), raw: 150_000, sensor: nil).ageAdjustedRawValue, 150)
        XCTAssertEqual(newReading(Libre1Calibrator(), raw: 150_000, sensor: youngSensor).ageAdjustedRawValue, 150)
    }

    func testCalibratedReadingUsesLastCalibrationSlopeAndIntercept() {
        let sensor = Sensor(startDate: now.addingTimeInterval(-3 * 86_400), nsManagedObjectContext: context)
        let calibration = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-3600), bg: 120, raw: 100, slope: 1.2, intercept: -10)
        let previous = reading(at: now.addingTimeInterval(-5 * 60), calculated: 160, raw: 140, sensor: sensor)
        let created = newReading(DexcomCalibrator(), raw: 150_000, sensor: sensor, last3: [previous], first: calibration, last: calibration)
        XCTAssertEqual(created.calculatedValue, 170, accuracy: 0.000_001)
        XCTAssertEqual(created.c, 170, accuracy: 0.000_001)
        XCTAssertFalse(created.hideSlope)
        XCTAssertEqual(created.calculatedValueSlope * 60_000, 2, accuracy: 0.000_001)
        XCTAssertTrue(created.calibration === calibration)
    }

    func testCalibratedReadingIsClampedToTheSupportedRange() {
        let sensor = Sensor(startDate: now.addingTimeInterval(-3 * 86_400), nsManagedObjectContext: context)
        let previous = reading(at: now.addingTimeInterval(-5 * 60), calculated: 100, raw: 100, sensor: sensor)
        let cases: [(Double, Double)] = [(3, 400), (0.2, 39), (0.01, 38)]
        for (slope, expected) in cases {
            let calibration = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-3600), bg: 100, raw: 100, slope: slope, intercept: 0)
            let created = newReading(DexcomCalibrator(), raw: 150_000, sensor: sensor, last3: [previous], first: calibration, last: calibration)
            XCTAssertEqual(created.calculatedValue, expected, "slope \(slope)")
        }
    }

    func testCalibrationWithoutPreviousReadingsProducesErrorValue() {
        let sensor = Sensor(startDate: now.addingTimeInterval(-3 * 86_400), nsManagedObjectContext: context)
        let calibration = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-3600), bg: 100, raw: 100, slope: 1, intercept: 0)
        let created = newReading(DexcomCalibrator(), raw: 150_000, sensor: sensor, last3: [], first: calibration, last: calibration)
        XCTAssertEqual(created.calculatedValue, ConstantsCalibrationAlgorithms.bgReadingErrorValue)
        XCTAssertTrue(created.hideSlope)
    }

    func testRecentCalibrationReadingOverridesEstimatedRawWithWeightedAverage() {
        let sensor = Sensor(startDate: now.addingTimeInterval(-3 * 86_400), nsManagedObjectContext: context)
        let calibration = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-150), bg: 120, raw: 100, slope: 2, intercept: 0)
        let latest = reading(at: now.addingTimeInterval(-300), calculated: 120, raw: 100, sensor: sensor)
        latest.calibration = calibration
        latest.calibrationFlag = true
        let created = newReading(Libre1Calibrator(), raw: 110_000, sensor: sensor, last3: [latest], first: calibration, last: calibration)
        XCTAssertEqual(calibration.estimateRawAtTimeOfCalibration, 105, accuracy: 0.000_001)
        XCTAssertEqual(calibration.slope, 1)
        XCTAssertEqual(calibration.intercept, 20)
        XCTAssertEqual(created.calculatedValue, 130, accuracy: 0.000_001)
    }

    func testOldCalibrationReadingDoesNotOverrideCalibration() {
        let sensor = Sensor(startDate: now.addingTimeInterval(-3 * 86_400), nsManagedObjectContext: context)
        let calibration = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-30 * 60), bg: 120, raw: 100, slope: 2, intercept: 0)
        let latest = reading(at: now.addingTimeInterval(-300), calculated: 120, raw: 100, sensor: sensor)
        latest.calibration = calibration
        latest.calibrationFlag = true
        let created = newReading(Libre1Calibrator(), raw: 110_000, sensor: sensor, last3: [latest], first: calibration, last: calibration)
        XCTAssertEqual(calibration.slope, 2)
        XCTAssertEqual(calibration.estimateRawAtTimeOfCalibration, 100)
        XCTAssertEqual(created.calculatedValue, 220, accuracy: 0.000_001)
    }

    func testTwoPreviousReadingsProduceLinearCurves() {
        let sensor = Sensor(startDate: now.addingTimeInterval(-3 * 86_400), nsManagedObjectContext: context)
        let calibration = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-3600), bg: 100, raw: 100, slope: 1, intercept: 0)
        let latest = reading(at: now.addingTimeInterval(-300), calculated: 120, raw: 120, sensor: sensor)
        let older = reading(at: now.addingTimeInterval(-600), calculated: 110, raw: 110, sensor: sensor)
        let created = newReading(Libre1Calibrator(), raw: 125_000, sensor: sensor, last3: [latest, older], first: calibration, last: calibration)
        XCTAssertEqual(created.a, 0)
        XCTAssertEqual(created.b * 300_000, 10, accuracy: 0.000_001)
        XCTAssertEqual(created.c, 110, accuracy: 0.000_001)
        XCTAssertEqual(created.ra, 0)
        XCTAssertEqual(created.rb * 300_000, 10, accuracy: 0.000_001)
        XCTAssertEqual(created.rc, 110, accuracy: 0.000_001)
        XCTAssertEqual(created.calculatedValueSlope * 60_000, 1, accuracy: 0.000_001)
    }

    func testEqualPreviousValuesProduceFlatLinearCurve() {
        let sensor = Sensor(startDate: now.addingTimeInterval(-3 * 86_400), nsManagedObjectContext: context)
        let latest = reading(at: now.addingTimeInterval(-300), calculated: 110, raw: 110, sensor: sensor)
        let older = reading(at: now.addingTimeInterval(-600), calculated: 110, raw: 110, sensor: sensor)
        let created = newReading(Libre1Calibrator(), raw: 125_000, sensor: sensor, last3: [latest, older])
        XCTAssertEqual(created.b, 0)
        XCTAssertEqual(created.rb, 0)
        XCTAssertEqual(created.c, 110)
        XCTAssertEqual(created.rc, 110)
    }

    func testThreePreviousReadingsProduceQuadraticCoefficients() {
        let sensor = Sensor(startDate: now.addingTimeInterval(-3 * 86_400), nsManagedObjectContext: context)
        let readings = [(300.0, 120.0), (600.0, 110.0), (900.0, 100.0)].map { reading(at: now.addingTimeInterval(-$0.0), calculated: $0.1, raw: $0.1, sensor: sensor) }
        let created = newReading(Libre1Calibrator(), raw: 125_000, sensor: sensor, last3: readings)
        XCTAssertEqual(created.a, 0, accuracy: 1e-15)
        XCTAssertEqual(created.b * 300_000, 10, accuracy: 0.000_1)
        XCTAssertEqual(created.ra, 0, accuracy: 1e-15)
        XCTAssertEqual(created.rb * 300_000, 10, accuracy: 0.000_1)
        let curved = [(300.0, 130.0), (600.0, 110.0), (900.0, 100.0)].map { reading(at: now.addingTimeInterval(-$0.0), calculated: $0.1, raw: $0.1, sensor: sensor) }
        XCTAssertGreaterThan(newReading(Libre1Calibrator(), raw: 125_000, sensor: sensor, last3: curved).a, 0)
    }

    func testFindSlopeHidesTrendWithoutPreviousReadings() {
        let item = reading(at: now, calculated: 100, raw: 100, sensor: nil)
        item.calculatedValueSlope = 5
        var empty = [BgReading]()
        DexcomCalibrator().findSlope(for: item, last2Readings: &empty)
        XCTAssertTrue(item.hideSlope)
        XCTAssertEqual(item.calculatedValueSlope, 0)
        var previous = [reading(at: now.addingTimeInterval(-300), calculated: 110, raw: 100, sensor: nil)]
        DexcomCalibrator().findSlope(for: item, last2Readings: &previous)
        XCTAssertFalse(item.hideSlope)
        XCTAssertEqual(item.calculatedValueSlope * 60_000, -2, accuracy: 0.000_001)
    }

    // MARK: - initialCalibration (protocol extension)

    func testInitialCalibrationRequiresAtLeastTwoReadings() {
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        var readings = [reading(at: now, calculated: 0, raw: 100, sensor: sensor)]
        let result = DexcomCalibrator().initialCalibration(firstCalibrationBgValue: 100, firstCalibrationTimeStamp: now, secondCalibrationBgValue: 100, sensor: sensor, lastBgReadingsWithCalculatedValue0AndForSensor: &readings, deviceName: nil, nsManagedObjectContext: context)
        XCTAssertNil(result.firstCalibration)
        XCTAssertNil(result.secondCalibration)
        XCTAssertEqual(try context.count(for: Calibration.fetchRequest()), 0)
    }

    func testInitialCalibrationCreatesTwoCalibrationsWithExactLine() throws {
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let first = reading(at: now, calculated: 0, raw: 100, sensor: sensor)
        let second = reading(at: now.addingTimeInterval(-300), calculated: 0, raw: 110, sensor: sensor)
        let third = reading(at: now.addingTimeInterval(-600), calculated: 95, raw: 105, sensor: sensor)
        var readings = [first, second, third]
        let start = now.addingTimeInterval(-300)
        let result = DexcomCalibrator().initialCalibration(firstCalibrationBgValue: 100, firstCalibrationTimeStamp: start, secondCalibrationBgValue: 111, sensor: sensor, lastBgReadingsWithCalculatedValue0AndForSensor: &readings, deviceName: "G6", nsManagedObjectContext: context)
        let calibration1 = try XCTUnwrap(result.firstCalibration)
        let calibration2 = try XCTUnwrap(result.secondCalibration)
        XCTAssertEqual(calibration1.timeStamp, start)
        XCTAssertEqual(calibration2.timeStamp, start.addingTimeInterval(300))
        XCTAssertEqual(calibration1.slope, 1)
        XCTAssertEqual(calibration1.intercept, 0, accuracy: 0.000_001)
        XCTAssertEqual(calibration1.sensorConfidence, 0.853205, accuracy: 0.000_001)
        XCTAssertEqual(calibration2.sensorConfidence, 0.884654, accuracy: 0.000_001)
        XCTAssertEqual(calibration2.slope, 1.1, accuracy: 0.000_001)
        XCTAssertEqual(calibration2.intercept, -10, accuracy: 0.000_01)
        XCTAssertEqual(calibration1.deviceName, "G6")
        XCTAssertEqual(calibration2.estimateRawAtTimeOfCalibration, 110)
        XCTAssertFalse(calibration2.possibleBad)
        XCTAssertTrue(first.calibration === calibration1)
        XCTAssertTrue(second.calibration === calibration2)
        XCTAssertTrue(first.calibrationFlag)
        XCTAssertTrue(second.calibrationFlag)
        XCTAssertEqual(first.calculatedValue, 100, accuracy: 0.000_01)
        XCTAssertNotEqual(second.calculatedValue, 0)
        XCTAssertEqual(third.calculatedValue, 95)
    }

    func testLibre1CalibratorPinsTheSecondInitialCalibrationSlopeToOne() throws {
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        var readings = [reading(at: now, calculated: 0, raw: 120, sensor: sensor), reading(at: now.addingTimeInterval(-300), calculated: 0, raw: 110, sensor: sensor)]
        let result = Libre1Calibrator().initialCalibration(firstCalibrationBgValue: 130, firstCalibrationTimeStamp: now.addingTimeInterval(-300), secondCalibrationBgValue: 140, sensor: sensor, lastBgReadingsWithCalculatedValue0AndForSensor: &readings, deviceName: nil, nsManagedObjectContext: context)
        let second = try XCTUnwrap(result.secondCalibration)
        XCTAssertEqual(second.slope, 1)
        XCTAssertEqual(second.intercept, 30, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(result.firstCalibration).intercept, 10, accuracy: 0.000_001)
    }

    // MARK: - createNewCalibration (protocol extension)

    func testCreateNewCalibrationWithoutReadingReturnsNil() {
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let first = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-7200), bg: 100, raw: 100, slope: 1, intercept: 0)
        var list = [first]
        XCTAssertNil(DexcomCalibrator().createNewCalibration(bgValue: 100, lastBgReading: nil, sensor: sensor, lastCalibrationsForActiveSensorInLastXDays: &list, firstCalibration: first, deviceName: nil, nsManagedObjectContext: context))
    }

    func testCreateNewCalibrationClampsHighSlopeWithTwoCalibrations() throws {
        let fixture = twoCalibrationFixture(rawCurveIntercept: 105)
        var list = [fixture.previous]
        let calibration = try XCTUnwrap(DexcomCalibrator().createNewCalibration(bgValue: 110, lastBgReading: fixture.reading, sensor: fixture.sensor, lastCalibrationsForActiveSensorInLastXDays: &list, firstCalibration: fixture.first, deviceName: "dev", nsManagedObjectContext: context))
        XCTAssertEqual(calibration.estimateRawAtTimeOfCalibration, 105)
        XCTAssertEqual(calibration.rawValue, 100)
        XCTAssertEqual(calibration.adjustedRawValue, 100)
        XCTAssertEqual(calibration.distanceFromEstimate, 5)
        XCTAssertEqual(calibration.slopeConfidence, 1)
        XCTAssertEqual(calibration.sensorConfidence, 0.881975, accuracy: 0.000_001)
        XCTAssertEqual(calibration.slope, 1.2, accuracy: 0.000_001)
        XCTAssertEqual(calibration.intercept, -16, accuracy: 0.000_01)
        XCTAssertFalse(calibration.possibleBad)
        XCTAssertTrue(fixture.reading.calibration === calibration)
        XCTAssertTrue(fixture.reading.calibrationFlag)
        XCTAssertEqual(fixture.reading.calculatedValue, 104, accuracy: 0.000_01)
        XCTAssertTrue(list.first === calibration)
    }

    func testCreateNewCalibrationClampsLowSlopeWithTwoCalibrations() throws {
        let fixture = twoCalibrationFixture(rawCurveIntercept: 105)
        var list = [fixture.previous]
        let calibration = try XCTUnwrap(DexcomCalibrator().createNewCalibration(bgValue: 100.5, lastBgReading: fixture.reading, sensor: fixture.sensor, lastCalibrationsForActiveSensorInLastXDays: &list, firstCalibration: fixture.first, deviceName: nil, nsManagedObjectContext: context))
        XCTAssertEqual(calibration.slope, 1.15, accuracy: 0.000_001)
        XCTAssertEqual(calibration.intercept, 100.5 - 105 * 1.15, accuracy: 0.000_01)
        XCTAssertEqual(fixture.reading.calculatedValue, 100 * 1.15 + 100.5 - 105 * 1.15, accuracy: 0.000_01)
    }

    func testCreateNewCalibrationUsesRawValueWhenEstimateIsFarOff() throws {
        let fixture = twoCalibrationFixture(rawCurveIntercept: 200)
        fixture.reading.calculatedValueSlope = 2.0 / 60_000
        fixture.previous.estimateRawAtTimeOfCalibration = 90
        var list = [fixture.previous]
        let calibration = try XCTUnwrap(Libre1NonFixedSlopeCalibrator().createNewCalibration(bgValue: 500, lastBgReading: fixture.reading, sensor: fixture.sensor, lastCalibrationsForActiveSensorInLastXDays: &list, firstCalibration: fixture.first, deviceName: nil, nsManagedObjectContext: context))
        XCTAssertEqual(calibration.estimateRawAtTimeOfCalibration, 100)
        XCTAssertEqual(calibration.slopeConfidence, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(calibration.sensorConfidence, 0)
        XCTAssertEqual(calibration.distanceFromEstimate, 395)
        XCTAssertEqual(calibration.slope, 1.4, accuracy: 0.000_001)
    }

    func testThirdCalibrationWithSteepSlopeIsMarkedPossiblyBad() throws {
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let c1 = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-7200), bg: 100, raw: 100, slope: 1, intercept: 0, estimate: 100)
        let c2 = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-3600), bg: 120, raw: 110, slope: 1, intercept: 0, estimate: 110)
        let last = reading(at: now.addingTimeInterval(-60), calculated: 110, raw: 100, sensor: sensor)
        last.rc = 120
        var list = [c2, c1]
        let calibration = try XCTUnwrap(DexcomCalibrator().createNewCalibration(bgValue: 140, lastBgReading: last, sensor: sensor, lastCalibrationsForActiveSensorInLastXDays: &list, firstCalibration: c1, deviceName: nil, nsManagedObjectContext: context))
        XCTAssertEqual(calibration.estimateRawAtTimeOfCalibration, 120)
        XCTAssertTrue(calibration.possibleBad)
        XCTAssertEqual(calibration.slope, 1.3, accuracy: 0.000_001)
        XCTAssertEqual(calibration.intercept, -16, accuracy: 0.000_01)
        XCTAssertEqual(last.calculatedValue, 114, accuracy: 0.000_01)
        XCTAssertTrue(list.first === calibration)
        XCTAssertTrue(list.contains { $0 === c1 } && list.contains { $0 === c2 })
    }

    func testThirdCalibrationWithShallowSlopeUsesDefaultLowSlope() throws {
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let c1 = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-7200), bg: 100, raw: 100, slope: 1, intercept: 0, estimate: 100)
        let c2 = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-3600), bg: 105, raw: 110, slope: 1, intercept: 0, estimate: 110)
        let last = reading(at: now.addingTimeInterval(-60), calculated: 110, raw: 100, sensor: sensor)
        last.rc = 120
        var list = [c2, c1]
        let calibration = try XCTUnwrap(DexcomCalibrator().createNewCalibration(bgValue: 110, lastBgReading: last, sensor: sensor, lastCalibrationsForActiveSensorInLastXDays: &list, firstCalibration: c1, deviceName: nil, nsManagedObjectContext: context))
        XCTAssertTrue(calibration.possibleBad)
        XCTAssertEqual(calibration.slope, 1.08, accuracy: 0.000_001)
        XCTAssertEqual(calibration.intercept, 110 - 120 * 1.08, accuracy: 0.000_01)
    }

    // MARK: - NoCalibrator

    func testNoCalibratorUsesRawValueDirectlyAndCapsAt600() {
        let calibrator = NoCalibrator()
        var last3 = [BgReading]()
        var calibrations = [Calibration]()
        let normal = calibrator.createNewBgReading(rawData: 123, timeStamp: now, sensor: nil, last3Readings: &last3, lastCalibrationsForActiveSensorInLastXDays: &calibrations, firstCalibration: nil, lastCalibration: nil, deviceName: "libre", nsManagedObjectContext: context)
        XCTAssertEqual(normal.calculatedValue, 123)
        XCTAssertEqual(normal.rawData, 123)
        XCTAssertTrue(normal.hideSlope)
        let excessive = calibrator.createNewBgReading(rawData: 5000, timeStamp: nil, sensor: nil, last3Readings: &last3, lastCalibrationsForActiveSensorInLastXDays: &calibrations, firstCalibration: nil, lastCalibration: nil, deviceName: nil, nsManagedObjectContext: context)
        XCTAssertEqual(excessive.calculatedValue, ConstantsCalibrationAlgorithms.maximumBgReadingCalculatedValueLimit)
    }

    func testNoCalibratorComputesSlopeFromPreviousReading() {
        var last3 = [reading(at: now.addingTimeInterval(-300), calculated: 100, raw: 100, sensor: nil)]
        var calibrations = [Calibration]()
        let created = NoCalibrator().createNewBgReading(rawData: 115, timeStamp: now, sensor: nil, last3Readings: &last3, lastCalibrationsForActiveSensorInLastXDays: &calibrations, firstCalibration: nil, lastCalibration: nil, deviceName: nil, nsManagedObjectContext: context)
        XCTAssertFalse(created.hideSlope)
        XCTAssertEqual(created.calculatedValueSlope * 60_000, 3, accuracy: 0.000_001)
        XCTAssertEqual(created.slopeArrow(), "\u{2191}")
    }

    func testNoCalibratorCalibrationsStoreTheEnteredValue() throws {
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        var list = [Calibration]()
        let first = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-60), bg: 1, raw: 1, slope: 1, intercept: 0)
        let calibration = try XCTUnwrap(NoCalibrator().createNewCalibration(bgValue: 123, lastBgReading: nil, sensor: sensor, lastCalibrationsForActiveSensorInLastXDays: &list, firstCalibration: first, deviceName: "x", nsManagedObjectContext: context))
        XCTAssertEqual(calibration.bg, 123)
        XCTAssertEqual(calibration.rawValue, 123)
        XCTAssertEqual(calibration.adjustedRawValue, 123)
        XCTAssertEqual(calibration.slope, 0)
        XCTAssertEqual(calibration.deviceName, "x")
        var readings = [BgReading]()
        let initial = NoCalibrator().initialCalibration(firstCalibrationBgValue: 99, firstCalibrationTimeStamp: now, secondCalibrationBgValue: 150, sensor: sensor, lastBgReadingsWithCalculatedValue0AndForSensor: &readings, deviceName: nil, nsManagedObjectContext: context)
        let initialCalibration = try XCTUnwrap(initial.firstCalibration)
        XCTAssertNil(initial.secondCalibration)
        XCTAssertEqual(initialCalibration.timeStamp, now.addingTimeInterval(300))
        XCTAssertEqual(initialCalibration.bg, 99)
        XCTAssertEqual(initialCalibration.estimateRawAtTimeOfCalibration, 99)
        XCTAssertFalse(initialCalibration.possibleBad)
        XCTAssertFalse(initialCalibration.sentToTransmitter)
    }

    // MARK: - Helpers

    private func newReading(_ calibrator: Calibrator, raw: Double, sensor: Sensor?, last3: [BgReading] = [], first: Calibration? = nil, last: Calibration? = nil) -> BgReading {
        var readings = last3
        var calibrations = [Calibration]()
        return calibrator.createNewBgReading(rawData: raw, timeStamp: now, sensor: sensor, last3Readings: &readings, lastCalibrationsForActiveSensorInLastXDays: &calibrations, firstCalibration: first, lastCalibration: last, deviceName: nil, nsManagedObjectContext: context)
    }

    private func reading(at date: Date, calculated: Double, raw: Double, sensor: Sensor?) -> BgReading {
        let item = BgReading(timeStamp: date, sensor: sensor, calibration: nil, rawData: raw, deviceName: nil, nsManagedObjectContext: context)
        item.calculatedValue = calculated
        item.ageAdjustedRawValue = raw
        return item
    }

    private func makeCalibration(sensor: Sensor, at date: Date, bg: Double, raw: Double, slope: Double, intercept: Double, estimate: Double? = nil) -> Calibration {
        Calibration(timeStamp: date, sensor: sensor, bg: bg, rawValue: raw, adjustedRawValue: raw, sensorConfidence: 0.8, rawTimeStamp: date, slope: slope, intercept: intercept, distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: estimate ?? raw, slopeConfidence: 0.5, deviceName: nil, nsManagedObjectContext: context)
    }

    private func twoCalibrationFixture(rawCurveIntercept: Double) -> (sensor: Sensor, first: Calibration, previous: Calibration, reading: BgReading) {
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let first = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-7200), bg: 90, raw: 90, slope: 1, intercept: 0)
        let previous = makeCalibration(sensor: sensor, at: now.addingTimeInterval(-3600), bg: 100, raw: 100, slope: 1, intercept: 0, estimate: 100)
        let last = reading(at: now.addingTimeInterval(-60), calculated: 105, raw: 100, sensor: sensor)
        last.rc = rawCurveIntercept
        return (sensor, first, previous, last)
    }
}
