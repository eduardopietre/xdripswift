//
//  DataCoverageCoreDataClassTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

final class DataCoverageCoreDataClassTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
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

    // MARK: - BgReading

    func testNewReadingHasNeutralDefaultsAndUniqueId() {
        let first = reading(100)
        let second = reading(100)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(first.id.isEmpty)
        XCTAssertEqual([first.a, first.b, first.c, first.ra, first.rb, first.rc, first.ageAdjustedRawValue, first.calculatedValueSlope], [0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertFalse(first.calibrationFlag)
        XCTAssertFalse(first.hideSlope)
        XCTAssertFalse(first.valueIsFromWatch)
        XCTAssertNil(first.adjustedValue)
        XCTAssertNil(first.smoothedValue)
        XCTAssertNil(first.backfilledAt)
        XCTAssertNil(first.watchReceivedAt)
    }

    func testFinalValuePrefersSmoothedThenAdjustedThenCalculated() {
        let item = reading(100)
        XCTAssertEqual(item.finalValue, 100)
        item.adjustedValue = 110
        XCTAssertEqual(item.finalValue, 110)
        item.smoothedValue = 105
        XCTAssertEqual(item.finalValue, 105)
        item.adjustedValue = nil
        XCTAssertEqual(item.finalValue, 105)
        item.smoothedValue = nil
        XCTAssertEqual(item.finalValue, 100)
    }

    func testSlopeArrowOrdinalAndNameForEveryBand() {
        let cases: [(Double, String, Int, String)] = [
            (-4, "\u{2193}\u{2193}", 7, "DoubleDown"), (-3, "\u{2193}", 6, "SingleDown"), (-1.5, "\u{2198}", 5, "FortyFiveDown"),
            (0, "\u{2192}", 4, "Flat"), (1.5, "\u{2197}", 3, "FortyFiveUp"), (3, "\u{2191}", 2, "SingleUp"), (4, "\u{2191}\u{2191}", 1, "DoubleUp")
        ]
        for (perMinute, arrow, ordinal, name) in cases {
            let item = reading(100)
            item.calculatedValueSlope = perMinute / 60_000
            XCTAssertEqual(item.slopeArrow(), arrow, "\(perMinute)")
            XCTAssertEqual(item.slopeOrdinal(), ordinal, "\(perMinute)")
            XCTAssertEqual(item.slopeName, name, "\(perMinute)")
            item.hideSlope = true
            XCTAssertEqual(item.slopeOrdinal(), 0)
            XCTAssertEqual(item.slopeName, "NOT COMPUTABLE")
            XCTAssertEqual(item.slopeArrow(), arrow)
        }
    }

    func testSlopeBoundariesAreInclusiveAndExtremeRiseHasNoName() {
        let item = reading(100)
        for (perMinute, ordinal) in [(-3.5, 7), (-2.0, 6), (-1.0, 5), (1.0, 4), (2.0, 3), (3.5, 2)] {
            item.calculatedValueSlope = perMinute / 60_000
            XCTAssertEqual(item.slopeOrdinal(), ordinal, "\(perMinute)")
        }
        item.calculatedValueSlope = 41.0 / 60_000
        XCTAssertEqual(item.slopeName, "NONE")
        XCTAssertEqual(item.slopeOrdinal(), 1)
    }

    func testUnitizedStringCoversRangesAndErrorCodes() {
        XCTAssertEqual(reading(400).unitizedString(unitIsMgDl: true), Texts_Common.HIGH)
        XCTAssertEqual(reading(180).unitizedString(unitIsMgDl: true), "180")
        XCTAssertEqual(reading(180).unitizedString(unitIsMgDl: false), "10.0")
        XCTAssertEqual(reading(40).unitizedString(unitIsMgDl: true), "40")
        XCTAssertEqual(reading(39).unitizedString(unitIsMgDl: true), Texts_Common.LOW)
        XCTAssertEqual(reading(13).unitizedString(unitIsMgDl: true), Texts_Common.LOW)
        let codes: [(Double, String)] = [(0, "??0"), (1, "?SN"), (2, "??2"), (3, "?NA"), (4, "???"), (5, "?NC"), (6, "?CD"), (7, "???"), (9, "?AD"), (12, "?RF")]
        for (value, expected) in codes {
            XCTAssertEqual(reading(value).unitizedString(unitIsMgDl: true), expected, "\(value)")
        }
    }

    func testUnitizedDeltaStringInMgDl() {
        let previous = reading(100, minutesAgo: 5)
        XCTAssertEqual(reading(110).unitizedDeltaString(previousBgReading: previous, showUnit: false, highGranularity: false, mgDl: true), "+10")
        XCTAssertEqual(reading(110).unitizedDeltaString(previousBgReading: previous, showUnit: true, highGranularity: false, mgDl: true), "+10 " + Texts_Common.mgdl)
        XCTAssertEqual(reading(92).unitizedDeltaString(previousBgReading: previous, showUnit: false, highGranularity: false, mgDl: true), "-8")
        XCTAssertEqual(reading(100).unitizedDeltaString(previousBgReading: previous, showUnit: false, highGranularity: false, mgDl: true), "+0")
        XCTAssertEqual(reading(100).unitizedDeltaString(previousBgReading: previous, showUnit: true, highGranularity: false, mgDl: true), "+0 " + Texts_Common.mgdl)
        XCTAssertEqual(reading(250).unitizedDeltaString(previousBgReading: previous, showUnit: true, highGranularity: false, mgDl: true), "ERR")
    }

    func testUnitizedDeltaStringInMmolRoundsBothValuesFirst() {
        let previous = reading(90, minutesAgo: 5)
        XCTAssertEqual(reading(108).unitizedDeltaString(previousBgReading: previous, showUnit: false, highGranularity: true, mgDl: false), "+1.0")
        XCTAssertEqual(reading(108).unitizedDeltaString(previousBgReading: previous, showUnit: true, highGranularity: true, mgDl: false), "+1.0 " + Texts_Common.mmol)
        XCTAssertEqual(reading(96).unitizedDeltaString(previousBgReading: reading(95, minutesAgo: 5), showUnit: false, highGranularity: true, mgDl: false), "+0.0")
        XCTAssertEqual(reading(72).unitizedDeltaString(previousBgReading: previous, showUnit: false, highGranularity: true, mgDl: false), "-1.0")
    }

    func testUnitizedDeltaStringNeedsARecentPreviousReading() {
        XCTAssertEqual(reading(110).unitizedDeltaString(previousBgReading: nil, showUnit: true, highGranularity: false, mgDl: true), "???")
        XCTAssertEqual(reading(110).unitizedDeltaString(previousBgReading: reading(100, minutesAgo: 22), showUnit: true, highGranularity: false, mgDl: true), "???")
        XCTAssertEqual(reading(110).unitizedDeltaString(previousBgReading: reading(100, minutesAgo: 21), showUnit: false, highGranularity: false, mgDl: true), "+10")
    }

    func testSlopeCalculationRequiresFourToTwentyOneMinutes() {
        let current = reading(110)
        XCTAssertEqual(current.currentSlope(previousBgReading: nil), 0)
        XCTAssertEqual(current.currentSlope(previousBgReading: reading(100, minutesAgo: 5)) * 60_000, 2, accuracy: 0.000_001)
        let tooClose = current.calculateSlope(lastBgReading: reading(100, minutesAgo: 3))
        XCTAssertEqual(tooClose.0, 0)
        XCTAssertTrue(tooClose.1)
        XCTAssertTrue(current.calculateSlope(lastBgReading: reading(100, minutesAgo: 22)).1)
        XCTAssertTrue(current.calculateSlope(lastBgReading: reading(100, minutesAgo: -5)).1)
        XCTAssertFalse(current.calculateSlope(lastBgReading: reading(100, minutesAgo: 4)).1)
        XCTAssertFalse(current.calculateSlope(lastBgReading: reading(100, minutesAgo: 21)).1)
        XCTAssertTrue(current.calculateSlope(lastBgReadings: []).1)
    }

    func testSlopeUsesFinalValuesOfBothReadings() {
        let current = reading(100)
        current.smoothedValue = 130
        let previous = reading(100, minutesAgo: 10)
        previous.adjustedValue = 110
        XCTAssertEqual(current.calculateSlope(lastBgReading: previous).0 * 60_000, 2, accuracy: 0.000_001)
    }

    func testBgRangeDescriptionUsesConfiguredMarksInBothUnits() {
        withMarks {
            XCTAssertEqual(reading(300).bgRangeDescription(), .urgent)
            XCTAssertEqual(reading(250).bgRangeDescription(), .urgent)
            XCTAssertEqual(reading(200).bgRangeDescription(), .notUrgent)
            XCTAssertEqual(reading(180).bgRangeDescription(), .notUrgent)
            XCTAssertEqual(reading(120).bgRangeDescription(), .inRange)
            XCTAssertEqual(reading(70).bgRangeDescription(), .notUrgent)
            XCTAssertEqual(reading(55).bgRangeDescription(), .urgent)
            UserDefaults.standard.bloodGlucoseUnitIsMgDl = false
            XCTAssertEqual(reading(120).bgRangeDescription(), .inRange)
            XCTAssertEqual(reading(300).bgRangeDescription(), .urgent)
            XCTAssertEqual(reading(65).bgRangeDescription(), .notUrgent)
        }
    }

    func testSnapshotPresentationMatchesManagedReading() {
        withMarks {
            for (perMinute, value, hidden) in [(-4.0, 50.0, false), (-1.5, 120.0, false), (0.5, 200.0, true), (3.0, 300.0, false), (5.0, 100.0, false)] {
                let item = reading(value)
                item.calculatedValueSlope = perMinute / 60_000
                item.hideSlope = hidden
                let snapshot = BgReadingSnapshot(timeStamp: item.timeStamp, calculatedValue: value, rawData: value, finalValue: item.finalValue, adjustedValue: nil, smoothedValue: nil, backfilledAt: nil, valueIsFromWatch: false, watchReceivedAt: nil, wasAlsoCollectedByWatch: false, calculatedValueSlope: item.calculatedValueSlope, hideSlope: hidden, id: item.id, deviceName: nil, calibrationSnapshot: nil, sensorID: nil, objectID: item.objectID)
                XCTAssertEqual(snapshot.slopeArrow(), item.slopeArrow())
                XCTAssertEqual(snapshot.slopeOrdinal(), item.slopeOrdinal())
                XCTAssertEqual(snapshot.bgRangeDescription(), item.bgRangeDescription())
            }
        }
    }

    func testWatchCollectionKeepsFirstReceiptAndMarksLiveCollection() {
        let item = reading(100)
        XCTAssertFalse(item.wasAlsoCollectedByWatch)
        item.recordWatchCollection(at: now, collectedAt: now.addingTimeInterval(-10))
        item.recordWatchCollection(at: now.addingTimeInterval(60), collectedAt: now.addingTimeInterval(50))
        XCTAssertEqual(item.watchReceivedAt, now)
        XCTAssertEqual(item.watchCollectedAt, now.addingTimeInterval(-10))
        XCTAssertEqual(item.watchCollectedLive?.boolValue, true)
        XCTAssertFalse(item.valueIsFromWatch)
        XCTAssertTrue(item.wasAlsoCollectedByWatch)
    }

    func testWatchBackfillDoesNotClaimLiveCollection() {
        let item = reading(100)
        item.recordWatchCollection(at: now, isBackfill: true)
        XCTAssertEqual(item.watchCollectedLive?.boolValue, false)
        XCTAssertNil(item.watchCollectedAt)
        XCTAssertFalse(item.wasAlsoCollectedByWatch)
        item.recordWatchCollection(at: now, isBackfill: true)
        XCTAssertEqual(item.watchCollectedLive?.boolValue, false)
        item.recordWatchCollection(at: now)
        XCTAssertEqual(item.watchCollectedLive?.boolValue, true)
    }

    func testLiveWatchCollectionReplacesPhoneBackfill() {
        let item = reading(100)
        item.phoneCollectedLive = false
        item.backfilledAt = now
        item.recordWatchCollection(at: now)
        XCTAssertTrue(item.valueIsFromWatch)
        XCTAssertNil(item.backfilledAt)
        XCTAssertFalse(item.wasAlsoCollectedByWatch)
    }

    func testPhoneCollectionReportsChangesOnlyOnce() {
        let item = reading(100)
        XCTAssertFalse(item.recordPhoneCollection(isBackfill: true))
        XCTAssertNil(item.phoneCollectedLive)
        XCTAssertTrue(item.recordPhoneCollection())
        XCTAssertEqual(item.phoneCollectedLive?.boolValue, true)
        XCTAssertFalse(item.recordPhoneCollection())
        item.valueIsFromWatch = true
        item.backfilledAt = now
        XCTAssertTrue(item.recordPhoneCollection())
        XCTAssertFalse(item.valueIsFromWatch)
        XCTAssertNil(item.backfilledAt)
    }

    func testReadingLogIncludesValuesCalibrationAndSensor() {
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let calibration = makeCalibration(sensor: sensor)
        let item = BgReading(timeStamp: now, sensor: sensor, calibration: calibration, rawData: 99, deviceName: "dev", nsManagedObjectContext: context)
        item.calculatedValue = 123
        item.smoothedValue = 120
        let text = item.log("  ")
        XCTAssertTrue(text.hasPrefix("bgreading = "))
        XCTAssertTrue(text.contains("calculatedValue = 123.0"))
        XCTAssertTrue(text.contains("smoothedValue = 120"))
        XCTAssertTrue(text.contains("adjustedValue = nil"))
        XCTAssertTrue(text.contains("finalValue = 120.0"))
        XCTAssertTrue(text.contains("rawData = 99.0"))
        XCTAssertTrue(text.contains("calibration = "))
        XCTAssertTrue(text.contains("uniqueid = " + sensor.id))
        XCTAssertFalse(reading(1).log("").contains("sensor = "))
    }

    // MARK: - Calibration and Sensor

    func testCalibrationInitialiserAndSensorAge() {
        let sensor = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: context)
        let calibration = makeCalibration(sensor: sensor)
        XCTAssertFalse(calibration.possibleBad)
        XCTAssertFalse(calibration.sentToTransmitter)
        XCTAssertFalse(calibration.id.isEmpty)
        XCTAssertEqual(calibration.sensorAgeAtTimeOfEstimation, 3_600_000)
        XCTAssertEqual(calibration.bg, 120)
        XCTAssertEqual(calibration.slope, 1.1)
        XCTAssertEqual(calibration.intercept, -5)
        XCTAssertEqual(calibration.deviceName, "G6")
        let text = calibration.log(" ")
        XCTAssertTrue(text.contains("bg = 120.0"))
        XCTAssertTrue(text.contains("possibleBad = false"))
        XCTAssertTrue(text.contains("rawTimestamp = "))
        XCTAssertTrue(text.contains("sensorAgeAtTimeOfEstimation = 3600000.0"))
        XCTAssertTrue(text.contains("acceptedByTransmitter = "))
    }

    func testSensorInitialiserAndLog() {
        let sensor = Sensor(startDate: now, nsManagedObjectContext: context)
        XCTAssertFalse(sensor.id.isEmpty)
        XCTAssertNil(sensor.endDate)
        XCTAssertFalse(sensor.log(indentation: "").contains("stoppedAt"))
        sensor.endDate = now.addingTimeInterval(60)
        let text = sensor.log(indentation: "  ")
        XCTAssertTrue(text.contains("uniqueid = " + sensor.id))
        XCTAssertTrue(text.contains("startedAt = " + now.description))
        XCTAssertTrue(text.contains("stoppedAt = " + now.addingTimeInterval(60).description))
        XCTAssertNotEqual(Sensor(startDate: now, nsManagedObjectContext: context).id, sensor.id)
    }

    func testPersistenceRoundTripKeepsRelationships() throws {
        let sensor = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: context)
        let calibration = makeCalibration(sensor: sensor)
        let item = BgReading(timeStamp: now, sensor: sensor, calibration: calibration, rawData: 99, deviceName: "dev", nsManagedObjectContext: context)
        item.calculatedValue = 101
        item.adjustedValue = 103
        XCTAssertTrue(core.saveChangesSynchronously())
        let fetched = try XCTUnwrap(context.fetch(BgReading.fetchRequest()).first)
        XCTAssertEqual(fetched.sensor?.id, sensor.id)
        XCTAssertEqual(fetched.calibration?.id, calibration.id)
        XCTAssertEqual(fetched.finalValue, 103)
        XCTAssertEqual(calibration.bgreadings.count, 1)
    }

    // MARK: - TreatmentType and TreatmentEntry

    func testTreatmentTypeTextsUnitsAndNightscoutFields() {
        let all: [TreatmentType] = [.Insulin, .Carbs, .Exercise, .BgCheck, .Basal, .SiteChange, .SensorStart, .PumpBatteryChange, .Note, .AutomaticBasal, .BasalInjection]
        XCTAssertEqual(Set(all.map { $0.asString() }).count, all.count)
        XCTAssertEqual(TreatmentType.Insulin.unit(), Texts_TreatmentsView.insulinUnit)
        XCTAssertEqual(TreatmentType.AutomaticBasal.unit(), Texts_TreatmentsView.insulinUnit)
        XCTAssertEqual(TreatmentType.BasalInjection.unit(), "U")
        XCTAssertEqual(TreatmentType.Carbs.unit(), Texts_TreatmentsView.carbsUnit)
        XCTAssertEqual(TreatmentType.Exercise.unit(), Texts_TreatmentsView.exerciseUnit)
        XCTAssertEqual(TreatmentType.Basal.unit(), Texts_TreatmentsView.basalRateUnit)
        for type in [TreatmentType.SiteChange, .SensorStart, .PumpBatteryChange, .Note] {
            XCTAssertEqual(type.unit(), "")
        }
        XCTAssertEqual(TreatmentType.Insulin.idExtension(), "-insulin")
        XCTAssertEqual(TreatmentType.Carbs.idExtension(), "-carbs")
        XCTAssertEqual(TreatmentType.BgCheck.nightscoutFieldname(), "glucose")
        XCTAssertEqual(TreatmentType.Basal.nightscoutFieldname(), "rate")
        XCTAssertEqual(TreatmentType.AutomaticBasal.nightscoutFieldname(), "rate")
        XCTAssertEqual(TreatmentType.Note.idExtension(), "-note")
        XCTAssertEqual(TreatmentType.BasalInjection.idExtension(), "-note")
        XCTAssertEqual(TreatmentType.SiteChange.idExtension(), "-")
        XCTAssertEqual(TreatmentType.AutomaticBasal.rawValue, 9)
        XCTAssertEqual(TreatmentType.BasalInjection.rawValue, 10)
    }

    func testBgCheckUnitFollowsUserUnit() {
        let saved = UserDefaults.standard.bloodGlucoseUnitIsMgDl
        defer { UserDefaults.standard.bloodGlucoseUnitIsMgDl = saved }
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = true
        XCTAssertEqual(TreatmentType.BgCheck.unit(), Texts_Common.mgdl)
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = false
        XCTAssertEqual(TreatmentType.BgCheck.unit(), Texts_Common.mmol)
    }

    func testTreatmentInitialisersDeriveUploadedFromId() {
        let local = TreatmentEntry(date: now, value: 2, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
        XCTAssertEqual(local.id, TreatmentEntry.EmptyId)
        XCTAssertFalse(local.uploaded)
        XCTAssertEqual(local.valueSecondary, 0)
        let remote = TreatmentEntry(id: "abc-insulin", date: now, value: 2, treatmentType: .Insulin, nightscoutEventType: "Bolus", enteredBy: "x", nsManagedObjectContext: context)
        XCTAssertTrue(remote.uploaded)
        let explicit = TreatmentEntry(id: "", date: now, value: 1, valueSecondary: nil, treatmentType: .Basal, uploaded: true, nightscoutEventType: nil, enteredBy: nil, notes: "n", nsManagedObjectContext: context)
        XCTAssertTrue(explicit.uploaded)
        XCTAssertEqual(explicit.valueSecondary, 0)
        XCTAssertEqual(explicit.notes, "n")
    }

    func testTreatmentsSortByDate() {
        let late = treatment(.Carbs, 10, minutesAgo: 0)
        let early = treatment(.Carbs, 10, minutesAgo: 30)
        XCTAssertTrue(early < late)
        XCTAssertFalse(late < early)
        XCTAssertEqual([late, early].sorted().map(\.date), [early.date, late.date])
    }

    func testNightscoutDictionaryForBolusCarbsAndExercise() {
        let bolus = TreatmentEntry(id: "abc123-insulin", date: now, value: 2.5, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context).dictionaryRepresentationForNightscoutUpload()
        XCTAssertEqual(bolus["eventType"] as? String, "Bolus")
        XCTAssertEqual(bolus["insulin"] as? Double, 2.5)
        XCTAssertEqual(bolus["_id"] as? Substring, "abc123")
        XCTAssertEqual(bolus["enteredBy"] as? String, ConstantsHomeView.applicationName)
        XCTAssertEqual(bolus["eventTime"] as? String, now.ISOStringFromDate())
        let carbs = treatment(.Carbs, 30).dictionaryRepresentationForNightscoutUpload(reuseDateFormatter: Date.ISODateFormatter())
        XCTAssertEqual(carbs["eventType"] as? String, "Carbs")
        XCTAssertEqual(carbs["carbs"] as? Double, 30)
        XCTAssertNil(carbs["_id"])
        let exercise = treatment(.Exercise, 45).dictionaryRepresentationForNightscoutUpload()
        XCTAssertEqual(exercise["eventType"] as? String, "Exercise")
        XCTAssertEqual(exercise["duration"] as? Double, 45)
    }

    func testNightscoutDictionaryForBasalTypes() {
        let basal = TreatmentEntry(date: now, value: 0.8, valueSecondary: 30, treatmentType: .Basal, nightscoutEventType: nil, enteredBy: "pump", nsManagedObjectContext: context).dictionaryRepresentationForNightscoutUpload()
        XCTAssertEqual(basal["eventType"] as? String, "Temp Basal")
        XCTAssertEqual(basal["rate"] as? Double, 0.8)
        XCTAssertEqual(basal["duration"] as? Double, 30)
        XCTAssertEqual(basal["enteredBy"] as? String, "pump")
        let automatic = TreatmentEntry(date: now, value: 0.5, valueSecondary: 5, treatmentType: .AutomaticBasal, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context).dictionaryRepresentationForNightscoutUpload()
        XCTAssertEqual(automatic["eventType"] as? String, "Temp Basal")
        XCTAssertEqual(automatic["rate"] as? Double ?? 0, 6, accuracy: 0.000_001)
        XCTAssertEqual(automatic["duration"] as? Double, 5)
        let invalid = TreatmentEntry(date: now, value: 0.5, valueSecondary: 0, treatmentType: .AutomaticBasal, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context).dictionaryRepresentationForNightscoutUpload()
        XCTAssertEqual(invalid["rate"] as? Double, 0)
    }

    func testNightscoutDictionaryForEventsNotesAndOverriddenEventType() {
        XCTAssertEqual(treatment(.SiteChange, 0).dictionaryRepresentationForNightscoutUpload()["eventType"] as? String, "Site Change")
        XCTAssertEqual(treatment(.SensorStart, 0).dictionaryRepresentationForNightscoutUpload()["eventType"] as? String, "Sensor Start")
        XCTAssertEqual(treatment(.PumpBatteryChange, 0).dictionaryRepresentationForNightscoutUpload()["eventType"] as? String, "Pump Battery Change")
        let note = TreatmentEntry(date: now, value: 0, treatmentType: .Note, nightscoutEventType: nil, enteredBy: nil, notes: "hello", nsManagedObjectContext: context).dictionaryRepresentationForNightscoutUpload()
        XCTAssertEqual(note["eventType"] as? String, ConstantsNightscout.noteEventType)
        XCTAssertEqual(note["notes"] as? String, "hello")
        XCTAssertEqual(treatment(.Note, 0).dictionaryRepresentationForNightscoutUpload()["notes"] as? String, "")
        let downloaded = TreatmentEntry(date: now, value: 3, treatmentType: .Insulin, nightscoutEventType: "Correction Bolus", enteredBy: nil, nsManagedObjectContext: context).dictionaryRepresentationForNightscoutUpload()
        XCTAssertEqual(downloaded["eventType"] as? String, "Correction Bolus")
    }

    func testNightscoutDictionaryForBgCheckInBothUnits() {
        let saved = UserDefaults.standard.bloodGlucoseUnitIsMgDl
        defer { UserDefaults.standard.bloodGlucoseUnitIsMgDl = saved }
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = true
        let mgDl = treatment(.BgCheck, 180).dictionaryRepresentationForNightscoutUpload()
        XCTAssertEqual(mgDl["eventType"] as? String, "BG Check")
        XCTAssertEqual(mgDl["glucose"] as? Double, 180)
        XCTAssertEqual(mgDl["glucoseType"] as? String, "Finger")
        XCTAssertEqual(mgDl["units"] as? String, ConstantsNightscout.mgDlNightscoutUnitString)
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = false
        let mmol = treatment(.BgCheck, 180).dictionaryRepresentationForNightscoutUpload()
        XCTAssertEqual(mmol["glucoseType"] as? String, "Finger: 10.0 " + Texts_Common.mmol)
        XCTAssertEqual(mmol["glucose"] as? Double, 180)
    }

    func testBasalInjectionUploadsOnlyAsEncodedNote() throws {
        let entry = TreatmentEntry(id: "xyz-note", date: now, value: 12.5, treatmentType: .BasalInjection, nightscoutEventType: "Something", enteredBy: nil, notes: "Lantus", nsManagedObjectContext: context)
        let dictionary = entry.dictionaryRepresentationForNightscoutUpload()
        XCTAssertEqual(dictionary["eventType"] as? String, ConstantsNightscout.noteEventType)
        XCTAssertNil(dictionary["insulin"])
        XCTAssertEqual(dictionary["created_at"] as? String, now.ISOStringFromDate())
        let payload = try XCTUnwrap(BasalInjectionPayload.decode(from: dictionary["notes"] as? String))
        XCTAssertEqual(payload.units, 12.5)
        XCTAssertEqual(payload.insulinDescription, "Lantus")
    }

    func testAutomaticBasalRateMath() {
        XCTAssertEqual(AutomaticBasalTreatmentMath.rate(amount: 0.5, durationSeconds: 300) ?? 0, 6, accuracy: 0.000_001)
        XCTAssertEqual(AutomaticBasalTreatmentMath.rate(amount: 0, durationSeconds: 300), 0)
        XCTAssertNil(AutomaticBasalTreatmentMath.rate(amount: -1, durationSeconds: 300))
        XCTAssertNil(AutomaticBasalTreatmentMath.rate(amount: 1, durationSeconds: 0))
        XCTAssertNil(AutomaticBasalTreatmentMath.rate(amount: .nan, durationSeconds: 60))
        XCTAssertNil(AutomaticBasalTreatmentMath.rate(amount: 1, durationSeconds: .infinity))
    }

    // MARK: - TreatmentNSResponse

    func testNightscoutResponseSplitsCombinedTreatments() throws {
        let responses = TreatmentNSResponse.fromNightscout(dictionary: ["_id": "n1", "created_at": "2022-01-12T23:04:17.190Z", "eventType": "Snack Bolus", "carbs": 20.0, "insulin": 1.5, "enteredBy": "loop"])
        XCTAssertEqual(responses.map(\.id), ["n1-carbs", "n1-insulin"])
        XCTAssertEqual(responses.map(\.eventType), [.Carbs, .Insulin])
        XCTAssertEqual(responses.map(\.value), [20, 1.5])
        XCTAssertEqual(responses.first?.enteredBy, "loop")
        XCTAssertEqual(responses.first?.nightscoutEventType, "Snack Bolus")
        XCTAssertEqual(try XCTUnwrap(responses.first).createdAt.timeIntervalSince1970, 1_642_028_657.19, accuracy: 0.001)
    }

    func testNightscoutResponseParsesDatesWithoutMilliseconds() throws {
        let responses = TreatmentNSResponse.fromNightscout(dictionary: ["_id": "n2", "created_at": "2022-01-12T23:04:17Z", "insulin": 1.0])
        XCTAssertEqual(try XCTUnwrap(responses.first).createdAt.timeIntervalSince1970, 1_642_028_657, accuracy: 0.001)
        XCTAssertNil(responses.first?.nightscoutEventType)
        XCTAssertTrue(TreatmentNSResponse.fromNightscout(dictionary: ["_id": "n3", "created_at": "not a date", "insulin": 1.0]).isEmpty)
        XCTAssertTrue(TreatmentNSResponse.fromNightscout(dictionary: ["created_at": "2022-01-12T23:04:17Z", "insulin": 1.0]).isEmpty)
        XCTAssertTrue(TreatmentNSResponse.fromNightscout(dictionary: ["_id": "n4", "insulin": 1.0]).isEmpty)
    }

    func testNightscoutResponseEventSpecificTypes() {
        let date = "2022-01-12T23:04:17Z"
        let exercise = TreatmentNSResponse.fromNightscout(dictionary: ["_id": "e", "created_at": date, "eventType": "Exercise", "duration": 30.0])
        XCTAssertEqual(exercise.map(\.eventType), [.Exercise])
        XCTAssertEqual(exercise.first?.value, 30)
        let mgdl = TreatmentNSResponse.fromNightscout(dictionary: ["_id": "g", "created_at": date, "glucose": 100.0, "units": "mg/dl"])
        XCTAssertEqual(mgdl.first?.eventType, .BgCheck)
        XCTAssertEqual(mgdl.first?.value, 100)
        XCTAssertEqual(mgdl.first?.id, "g-glucose")
        let mmol = TreatmentNSResponse.fromNightscout(dictionary: ["_id": "g", "created_at": date, "glucose": 5.5, "units": "mmol"])
        XCTAssertEqual(mmol.first?.value ?? 0, 5.5 * ConstantsBloodGlucose.mmollToMgdl, accuracy: 0.000_001)
        XCTAssertTrue(TreatmentNSResponse.fromNightscout(dictionary: ["_id": "g", "created_at": date, "glucose": 5.5]).isEmpty)
        let basal = TreatmentNSResponse.fromNightscout(dictionary: ["_id": "b", "created_at": date, "eventType": "Temp Basal", "rate": 0.7, "duration": 30.0])
        XCTAssertEqual(basal.map(\.eventType), [.Basal])
        XCTAssertEqual(basal.first?.valueSecondary, 30)
        XCTAssertEqual(basal.first?.id, "b-rate")
        for (eventType, type) in [("Site Change", TreatmentType.SiteChange), ("Sensor Start", .SensorStart), ("Pump Battery Change", .PumpBatteryChange)] {
            let response = TreatmentNSResponse.fromNightscout(dictionary: ["_id": "x", "created_at": date, "eventType": eventType])
            XCTAssertEqual(response.map(\.eventType), [type])
            XCTAssertEqual(response.first?.value, 0)
        }
        XCTAssertTrue(TreatmentNSResponse.fromNightscout(dictionary: ["_id": "x", "created_at": date, "eventType": "Unknown"]).isEmpty)
    }

    func testNightscoutResponseNotesAndBasalInjectionEnvelope() throws {
        let date = "2022-01-12T23:04:17Z"
        let note = TreatmentNSResponse.fromNightscout(dictionary: ["_id": "n", "created_at": date, "eventType": ConstantsNightscout.noteEventType, "notes": "remember"])
        XCTAssertEqual(note.map(\.eventType), [.Note])
        XCTAssertEqual(note.first?.notes, "remember")
        XCTAssertTrue(TreatmentNSResponse.fromNightscout(dictionary: ["_id": "n", "created_at": date, "eventType": ConstantsNightscout.noteEventType, "notes": ""]).isEmpty)
        let encoded = try XCTUnwrap(BasalInjectionPayload(units: 8, insulinDescription: "Tresiba")?.encodedNotes())
        let injection = TreatmentNSResponse.fromNightscout(dictionary: ["_id": "i", "created_at": date, "eventType": ConstantsNightscout.noteEventType, "notes": encoded, "insulin": 8.0])
        XCTAssertEqual(injection.count, 1)
        XCTAssertEqual(injection.first?.eventType, .BasalInjection)
        XCTAssertEqual(injection.first?.value, 8)
        XCTAssertEqual(injection.first?.notes, "Tresiba")
        XCTAssertEqual(injection.first?.id, "i-note")
    }

    func testNightscoutResponseArraysAndData() throws {
        let array: NSArray = [["_id": "a", "created_at": "2022-01-12T23:04:17Z", "carbs": 10.0], "not a dictionary", ["_id": "b", "created_at": "2022-01-12T23:04:17Z", "insulin": 1.0]]
        XCTAssertEqual(TreatmentNSResponse.arrayFromNSArray(array).map(\.id), ["a-carbs", "b-insulin"])
        let data = try JSONSerialization.data(withJSONObject: [["_id": "c", "created_at": "2022-01-12T23:04:17Z", "carbs": 5.0]])
        XCTAssertEqual(try TreatmentNSResponse.arrayFromData(data)?.map(\.id), ["c-carbs"])
        XCTAssertNil(try TreatmentNSResponse.arrayFromData(nil))
        XCTAssertNil(try TreatmentNSResponse.arrayFromData(try JSONSerialization.data(withJSONObject: ["a": 1])))
        XCTAssertThrowsError(try TreatmentNSResponse.arrayFromData(Data("{".utf8)))
    }

    func testNightscoutResponseMatchesAndCreatesTreatmentEntries() throws {
        let response = try XCTUnwrap(TreatmentNSResponse.fromNightscout(dictionary: ["_id": "r", "created_at": "2022-01-12T23:04:17.190Z", "eventType": "Temp Basal", "rate": 0.7, "duration": 30.0, "enteredBy": "aaps"]).first)
        let entry = try XCTUnwrap(response.asNewTreatmentEntry(nsManagedObjectContext: context))
        XCTAssertEqual(entry.id, "r-rate")
        XCTAssertTrue(entry.uploaded)
        XCTAssertEqual(entry.valueSecondary, 30)
        XCTAssertEqual(entry.enteredBy, "aaps")
        XCTAssertEqual(entry.nightscoutEventType, "Temp Basal")
        XCTAssertTrue(response.matchesTreatmentEntry(entry))
        entry.value = 0.8
        XCTAssertFalse(response.matchesTreatmentEntry(entry))
        entry.value = 0.7
        entry.notes = "changed"
        XCTAssertFalse(response.matchesTreatmentEntry(entry))
        entry.notes = nil
        entry.date = entry.date.addingTimeInterval(1)
        XCTAssertFalse(response.matchesTreatmentEntry(entry))
    }

    // MARK: - TreatmentCollection and DateOnly

    func testDateOnlyIgnoresTimeOfDay() throws {
        let morning = try localDate(day: 10, hour: 8)
        let evening = try localDate(day: 10, hour: 22)
        let nextDay = try localDate(day: 11, hour: 1)
        XCTAssertEqual(DateOnly(date: morning), DateOnly(date: evening))
        XCTAssertEqual(DateOnly(date: morning).hashValue, DateOnly(date: evening).hashValue)
        XCTAssertLessThan(DateOnly(date: evening), DateOnly(date: nextDay))
        XCTAssertEqual(DateOnly(date: evening).date, Calendar.current.startOfDay(for: evening))
        XCTAssertEqual(Set([DateOnly(date: morning), DateOnly(date: evening), DateOnly(date: nextDay)]).count, 2)
    }

    func testTreatmentCollectionGroupsByDayNewestFirst() throws {
        let a = TreatmentEntry(date: try localDate(day: 10, hour: 8), value: 1, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
        let b = TreatmentEntry(date: try localDate(day: 12, hour: 9), value: 2, treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
        let c = TreatmentEntry(date: try localDate(day: 10, hour: 20), value: 3, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
        let d = TreatmentEntry(date: try localDate(day: 11, hour: 12), value: 4, treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
        let collection = TreatmentCollection(treatments: [a, b, c, d])
        XCTAssertEqual(collection.dateOnlys().map(\.date), [12, 11, 10].map { Calendar.current.startOfDay(for: try! localDate(day: $0, hour: 12)) })
        XCTAssertEqual(collection.treatmentsForDateOnlyAt(2).map(\.value), [3, 1])
        XCTAssertEqual(collection.getTreatment(dateIndex: 0, treatmentIndex: 0).value, 2)
        XCTAssertEqual(collection.getTreatment(dateIndex: 2, treatmentIndex: 1).value, 1)
        XCTAssertEqual(collection.dateOnlyAt(1), DateOnly(date: d.date))
        XCTAssertEqual(collection.getTreatmentsFor(date: DateOnly(date: try localDate(day: 1, hour: 1))), [])
        XCTAssertTrue(TreatmentCollection(treatments: []).dateOnlys().isEmpty)
    }

    // MARK: - Helpers

    private func reading(_ value: Double, minutesAgo: Double = 0) -> BgReading {
        let item = BgReading(timeStamp: now.addingTimeInterval(-minutesAgo * 60), sensor: nil, calibration: nil, rawData: value, deviceName: nil, nsManagedObjectContext: context)
        item.calculatedValue = value
        return item
    }

    private func treatment(_ type: TreatmentType, _ value: Double, minutesAgo: Double = 0) -> TreatmentEntry {
        TreatmentEntry(date: now.addingTimeInterval(-minutesAgo * 60), value: value, treatmentType: type, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
    }

    private func makeCalibration(sensor: Sensor) -> Calibration {
        Calibration(timeStamp: now, sensor: sensor, bg: 120, rawValue: 110, adjustedRawValue: 112, sensorConfidence: 0.8, rawTimeStamp: now, slope: 1.1, intercept: -5, distanceFromEstimate: 2, estimateRawAtTimeOfCalibration: 111, slopeConfidence: 0.5, deviceName: "G6", nsManagedObjectContext: context)
    }

    private func localDate(day: Int, hour: Int) throws -> Date {
        try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour)))
    }

    private func withMarks(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let keys: [UserDefaults.Key] = [.urgentHighMarkValue, .highMarkValue, .lowMarkValue, .urgentLowMarkValue]
        let saved = keys.map { ($0.rawValue, defaults.object(forKey: $0.rawValue)) }
        let savedUnit = defaults.bloodGlucoseUnitIsMgDl
        defer {
            for (key, value) in saved { defaults.set(value, forKey: key) }
            defaults.bloodGlucoseUnitIsMgDl = savedUnit
        }
        defaults.bloodGlucoseUnitIsMgDl = true
        for (key, value) in zip(keys, [250.0, 180.0, 70.0, 55.0]) { defaults.set(value, forKey: key.rawValue) }
        body()
    }
}
