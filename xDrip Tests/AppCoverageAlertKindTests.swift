//
//  AppCoverageAlertKindTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import SwiftUI
import UIKit
import XCTest
@testable import xdrip

final class AppCoverageAlertKindTests: XCTestCase {
    private var core: CoreDataManager!

    override func setUp() {
        super.setUp()
        appCoverageIsolateDefaults()
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = true
        core = AppCoverageFactory.coreData()
    }

    private func entry(_ kind: AlertKind, value: Int, trigger: Int = 0, start: Int = 0, enabled: Bool = true) -> AlertEntry {
        AppCoverageFactory.alertEntry(kind, value: value, trigger: trigger, start: start, type: AppCoverageFactory.alertType(core, enabled: enabled), core: core)
    }

    private func check(_ kind: AlertKind, entry: AlertEntry, next: AlertEntry? = nil, last: BgReading? = nil, previous: BgReading? = nil, calibration: Calibration? = nil, battery: TransmitterBatteryInfo? = nil, status: NotLoopingDeviceStatus? = nil) -> (alertNeeded: Bool, alertBody: String?, alertTitle: String?, delayInSeconds: Int?) {
        kind.alertNeeded(currentAlertEntry: entry, nextAlertEntry: next, lastBgReading: last, previous, lastCalibration: calibration, transmitterBatteryInfo: battery, deviceStatus: status)
    }

    // MARK: - Glucose threshold alerts

    func testLowAlertFiresOnlyBelowThresholdAndBuildsTitleAndBody() {
        let low = entry(.low, value: 70)
        let reading = AppCoverageFactory.reading(65, at: Date(), in: core)
        let result = check(.low, entry: low, last: reading)
        XCTAssertTrue(result.alertNeeded)
        XCTAssertEqual(result.alertTitle, Texts_Alerts.lowAlertTitle)
        XCTAssertTrue(result.alertBody?.contains("65") == true)
        XCTAssertNil(result.delayInSeconds)
        reading.calculatedValue = 70
        XCTAssertFalse(check(.low, entry: low, last: reading).alertNeeded)
        reading.calculatedValue = 69.6
        XCTAssertFalse(check(.low, entry: low, last: reading).alertNeeded, "A value that rounds to the threshold must not fire")
    }

    func testVeryLowUsesItsOwnTitle() {
        let reading = AppCoverageFactory.reading(40, at: Date(), in: core)
        XCTAssertEqual(check(.verylow, entry: entry(.verylow, value: 55), last: reading).alertTitle, Texts_Alerts.veryLowAlertTitle)
    }

    func testHighAndVeryHighFireOnlyAboveThreshold() {
        let reading = AppCoverageFactory.reading(251, at: Date(), in: core)
        let high = check(.high, entry: entry(.high, value: 250), last: reading)
        XCTAssertTrue(high.alertNeeded)
        XCTAssertEqual(high.alertTitle, Texts_Alerts.highAlertTitle)
        XCTAssertEqual(check(.veryhigh, entry: entry(.veryhigh, value: 200), last: reading).alertTitle, Texts_Alerts.veryHighAlertTitle)
        reading.calculatedValue = 250
        XCTAssertFalse(check(.high, entry: entry(.high, value: 250), last: reading).alertNeeded)
    }

    func testThresholdAlertsIgnoreDisabledTypesMissingAndZeroReadings() {
        let reading = AppCoverageFactory.reading(40, at: Date(), in: core)
        XCTAssertFalse(check(.low, entry: entry(.low, value: 70, enabled: false), last: reading).alertNeeded)
        XCTAssertFalse(check(.high, entry: entry(.high, value: 30, enabled: false), last: reading).alertNeeded)
        XCTAssertFalse(check(.low, entry: entry(.low, value: 70)).alertNeeded)
        XCTAssertFalse(check(.high, entry: entry(.high, value: 30)).alertNeeded)
        reading.calculatedValue = 0
        XCTAssertFalse(check(.low, entry: entry(.low, value: 70), last: reading).alertNeeded)
        XCTAssertFalse(check(.high, entry: entry(.high, value: 0), last: reading).alertNeeded)
    }

    func testAlertBodyOmitsSlopeArrowWhenSlopeIsHidden() {
        let shown = AppCoverageFactory.reading(60, at: Date(), in: core, slope: -0.0002)
        let hidden = AppCoverageFactory.reading(60, at: Date(), in: core, slope: -0.0002, hideSlope: true)
        let shownBody = check(.low, entry: entry(.low, value: 70), last: shown).alertBody ?? ""
        let hiddenBody = check(.low, entry: entry(.low, value: 70), last: hidden).alertBody ?? ""
        XCTAssertEqual(hiddenBody, " 60")
        XCTAssertEqual(shownBody, " 60 " + shown.slopeArrow())
    }

    func testMmolModeComparesStoredValuesWithDecimalPrecision() {
        // Describes the current behaviour, not a requirement: in mmol/L mode the stored mg/dL value is
        // rounded to one decimal without converting it, so 69.6 mg/dL is below a 70 mg/dL low limit for
        // mmol/L users but not for mg/dL users, although both are shown at the limit.
        let reading = AppCoverageFactory.reading(69.6, at: Date(), in: core)
        XCTAssertFalse(check(.low, entry: entry(.low, value: 70), last: reading).alertNeeded)
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = false
        XCTAssertTrue(check(.low, entry: entry(.low, value: 70), last: reading).alertNeeded)
        reading.calculatedValue = 69.96
        XCTAssertFalse(check(.low, entry: entry(.low, value: 70), last: reading).alertNeeded)
    }

    // MARK: - Rate of change alerts

    func testFastDropNeedsDropAboveValueAndLastBelowTrigger() {
        let now = Date()
        let previous = AppCoverageFactory.reading(110, at: now.addingTimeInterval(-300), in: core)
        let last = AppCoverageFactory.reading(85, at: now, in: core)
        let drop = entry(.fastdrop, value: 15, trigger: 90)
        let result = check(.fastdrop, entry: drop, last: last, previous: previous)
        XCTAssertTrue(result.alertNeeded)
        XCTAssertEqual(result.alertTitle, Texts_Alerts.fastDropTitle)
        last.calculatedValue = 95
        XCTAssertFalse(check(.fastdrop, entry: drop, last: last, previous: previous).alertNeeded, "Above the trigger value")
        last.calculatedValue = 100
        XCTAssertFalse(check(.fastdrop, entry: entry(.fastdrop, value: 15, trigger: 200), last: last, previous: previous).alertNeeded, "Drop too small")
    }

    func testFastRiseNeedsRiseAboveValueAndLastAboveTrigger() {
        let now = Date()
        let previous = AppCoverageFactory.reading(150, at: now.addingTimeInterval(-300), in: core)
        let last = AppCoverageFactory.reading(175, at: now, in: core)
        let rise = entry(.fastrise, value: 15, trigger: 160)
        let result = check(.fastrise, entry: rise, last: last, previous: previous)
        XCTAssertTrue(result.alertNeeded)
        XCTAssertEqual(result.alertTitle, Texts_Alerts.fastRiseTitle)
        XCTAssertFalse(check(.fastrise, entry: entry(.fastrise, value: 15, trigger: 180), last: last, previous: previous).alertNeeded)
        XCTAssertFalse(check(.fastrise, entry: entry(.fastrise, value: 30, trigger: 160), last: last, previous: previous).alertNeeded)
    }

    func testRateAlertsRequireTwoCloseNonZeroReadings() {
        let now = Date()
        let farPrevious = AppCoverageFactory.reading(150, at: now.addingTimeInterval(-311), in: core)
        let closePrevious = AppCoverageFactory.reading(150, at: now.addingTimeInterval(-309), in: core)
        let last = AppCoverageFactory.reading(190, at: now, in: core)
        let rise = entry(.fastrise, value: 10, trigger: 100)
        XCTAssertFalse(check(.fastrise, entry: rise, last: last, previous: farPrevious).alertNeeded)
        XCTAssertTrue(check(.fastrise, entry: rise, last: last, previous: closePrevious).alertNeeded)
        XCTAssertFalse(check(.fastrise, entry: rise, last: last).alertNeeded)
        closePrevious.calculatedValue = 0
        XCTAssertFalse(check(.fastrise, entry: rise, last: last, previous: closePrevious).alertNeeded)
        let drop = entry(.fastdrop, value: 10, trigger: 300)
        let dropPrevious = AppCoverageFactory.reading(220, at: now.addingTimeInterval(-311), in: core)
        XCTAssertFalse(check(.fastdrop, entry: drop, last: last, previous: dropPrevious).alertNeeded)
        XCTAssertFalse(check(.fastdrop, entry: drop, last: last).alertNeeded)
        XCTAssertFalse(check(.fastdrop, entry: entry(.fastdrop, value: 10, trigger: 300, enabled: false), last: last, previous: dropPrevious).alertNeeded)
        XCTAssertFalse(check(.fastrise, entry: entry(.fastrise, value: 10, trigger: 100, enabled: false), last: last, previous: closePrevious).alertNeeded)
    }

    // MARK: - Missed reading

    func testMissedReadingSchedulesRemainingDelayFromLastReading() throws {
        let reading = AppCoverageFactory.reading(120, at: Date().addingTimeInterval(-10 * 60), in: core)
        let result = check(.missedreading, entry: entry(.missedreading, value: 30), last: reading)
        XCTAssertTrue(result.alertNeeded)
        XCTAssertEqual(result.alertTitle, Texts_Alerts.missedReadingAlertTitle)
        XCTAssertEqual(result.alertBody, "")
        XCTAssertEqual(try XCTUnwrap(result.delayInSeconds), 20 * 60)
    }

    func testMissedReadingNeedsAReadingAndAnEnabledEntry() {
        XCTAssertFalse(check(.missedreading, entry: entry(.missedreading, value: 30)).alertNeeded)
        let reading = AppCoverageFactory.reading(120, at: Date(), in: core)
        XCTAssertFalse(check(.missedreading, entry: entry(.missedreading, value: 30, enabled: false), last: reading).alertNeeded)
        XCTAssertFalse(check(.missedreading, entry: entry(.missedreading, value: 30, enabled: false), next: entry(.missedreading, value: 30, start: 600, enabled: false), last: reading).alertNeeded)
    }

    func testMissedReadingIsNotPlannedIntoADisabledNextPeriod() throws {
        let minutes = Date().minutesSinceMidNightLocalTime()
        try XCTSkipIf(minutes > 1380, "Too close to midnight for a same-day next period")
        let reading = AppCoverageFactory.reading(120, at: Date(), in: core)
        let next = entry(.missedreading, value: 30, start: minutes + 10, enabled: false)
        XCTAssertFalse(check(.missedreading, entry: entry(.missedreading, value: 30), next: next, last: reading).alertNeeded)
        let later = entry(.missedreading, value: 30, start: minutes + 50, enabled: false)
        XCTAssertTrue(check(.missedreading, entry: entry(.missedreading, value: 30), next: later, last: reading).alertNeeded)
    }

    func testMissedReadingUsesLongerValueOfEnabledNextPeriod() throws {
        let minutes = Date().minutesSinceMidNightLocalTime()
        try XCTSkipIf(minutes > 1380, "Too close to midnight for a same-day next period")
        let reading = AppCoverageFactory.reading(120, at: Date(), in: core)
        let next = entry(.missedreading, value: 60, start: minutes + 10)
        XCTAssertEqual(check(.missedreading, entry: entry(.missedreading, value: 30), next: next, last: reading).delayInSeconds, 3600)
        let shorter = entry(.missedreading, value: 20, start: minutes + 10)
        XCTAssertEqual(check(.missedreading, entry: entry(.missedreading, value: 30), next: shorter, last: reading).delayInSeconds, 1800)
    }

    func testMissedReadingWaitsForStartOfEnabledNextPeriodWhenCurrentIsDisabled() throws {
        let minutes = Date().minutesSinceMidNightLocalTime()
        try XCTSkipIf(minutes > 1300, "Too close to midnight for a same-day next period")
        let reading = AppCoverageFactory.reading(120, at: Date(), in: core)
        let next = entry(.missedreading, value: 30, start: minutes + 120)
        let delay = try XCTUnwrap(check(.missedreading, entry: entry(.missedreading, value: 30, enabled: false), next: next, last: reading).delayInSeconds)
        XCTAssertEqual(Double(delay), 120 * 60, accuracy: 60)
    }

    // MARK: - Calibration and battery

    func testCalibrationAlertDependsOnAgeOfLastCalibration() {
        let sensor = Sensor(startDate: Date().addingTimeInterval(-86_400), nsManagedObjectContext: core.mainManagedObjectContext)
        let old = AppCoverageFactory.calibration(at: Date().addingTimeInterval(-5 * 3600), sensor: sensor, core: core)
        let recent = AppCoverageFactory.calibration(at: Date().addingTimeInterval(-3 * 3600), sensor: sensor, core: core)
        let result = check(.calibration, entry: entry(.calibration, value: 4), calibration: old)
        XCTAssertTrue(result.alertNeeded)
        XCTAssertEqual(result.alertTitle, Texts_Alerts.calibrationNeededAlertTitle)
        XCTAssertFalse(check(.calibration, entry: entry(.calibration, value: 4), calibration: recent).alertNeeded)
        XCTAssertFalse(check(.calibration, entry: entry(.calibration, value: 4)).alertNeeded)
        XCTAssertFalse(check(.calibration, entry: entry(.calibration, value: 4, enabled: false), calibration: old).alertNeeded)
    }

    func testBatteryAlertsOnlyFireForTheirOwnPayloadFamily() {
        let g5 = TransmitterBatteryInfo.dexcom(family: .g5, voltageA: 300, voltageB: 250, resist: 0, runtime: 0, temperature: 0)
        let g7 = TransmitterBatteryInfo.dexcom(family: .g7, voltageA: 300, voltageB: 250, resist: 0, runtime: 0, temperature: 0)
        let percent = TransmitterBatteryInfo.percentage(percentage: 10)
        XCTAssertTrue(check(.dexcomG5BatteryLow, entry: entry(.dexcomG5BatteryLow, value: 260), battery: g5).alertNeeded)
        XCTAssertFalse(check(.dexcomG5BatteryLow, entry: entry(.dexcomG5BatteryLow, value: 260), battery: g7).alertNeeded)
        XCTAssertTrue(check(.dexcomG7BatteryLow, entry: entry(.dexcomG7BatteryLow, value: 260), battery: g7).alertNeeded)
        XCTAssertFalse(check(.dexcomG7BatteryLow, entry: entry(.dexcomG7BatteryLow, value: 260), battery: percent).alertNeeded)
        let result = check(.batterylow, entry: entry(.batterylow, value: 20), battery: percent)
        XCTAssertTrue(result.alertNeeded)
        XCTAssertEqual(result.alertTitle, Texts_Alerts.batteryLowAlertTitle)
        XCTAssertFalse(check(.batterylow, entry: entry(.batterylow, value: 10), battery: percent).alertNeeded)
        XCTAssertFalse(check(.batterylow, entry: entry(.batterylow, value: 20), battery: g5).alertNeeded)
        XCTAssertFalse(check(.batterylow, entry: entry(.batterylow, value: 20)).alertNeeded)
        XCTAssertFalse(check(.batterylow, entry: entry(.batterylow, value: 20, enabled: false), battery: percent).alertNeeded)
    }

    func testMatchingBatteryLevelTreatsZeroAndNegativeVoltageAsUnknown() {
        for voltage in [0, -5] {
            let info = TransmitterBatteryInfo.dexcom(family: .g7, voltageA: 0, voltageB: voltage, resist: 0, runtime: 0, temperature: 0)
            XCTAssertNil(AlertKind.dexcomG7BatteryLow.matchingBatteryLevel(from: info))
        }
        let valid = TransmitterBatteryInfo.dexcom(family: .g5, voltageA: 0, voltageB: 280, resist: 0, runtime: 0, temperature: 0)
        XCTAssertEqual(AlertKind.dexcomG5BatteryLow.matchingBatteryLevel(from: valid), 280)
        XCTAssertNil(AlertKind.low.matchingBatteryLevel(from: valid))
        XCTAssertEqual(AlertKind.batterylow.matchingBatteryLevel(from: .percentage(percentage: 42)), 42)
        XCTAssertNil(AlertKind.phonebatterylow.matchingBatteryLevel(from: .percentage(percentage: 42)))
    }

    func testPhoneBatteryAlertIgnoresUnavailableSimulatorBatteryAndDisabledType() {
        XCTAssertFalse(check(.phonebatterylow, entry: entry(.phonebatterylow, value: 20, enabled: false)).alertNeeded)
        UIDevice.current.isBatteryMonitoringEnabled = true
        if UIDevice.current.batteryLevel < 0 {
            XCTAssertFalse(check(.phonebatterylow, entry: entry(.phonebatterylow, value: 100)).alertNeeded)
        }
    }

    // MARK: - Not looping

    func testNotLoopingFiresOnlyForFreshStatusWithStaleLoop() {
        let now = Date()
        let notLooping = entry(.notlooping, value: 15)
        let stale = NotLoopingDeviceStatus(createdAt: now, lastCheckedDate: now, lastLoopDate: now.addingTimeInterval(-20 * 60))
        let result = check(.notlooping, entry: notLooping, status: stale)
        XCTAssertTrue(result.alertNeeded)
        XCTAssertEqual(result.alertTitle, Texts_Alerts.notLoopingAlertTitle)
        let looping = NotLoopingDeviceStatus(createdAt: now, lastCheckedDate: now, lastLoopDate: now.addingTimeInterval(-5 * 60))
        XCTAssertFalse(check(.notlooping, entry: notLooping, status: looping).alertNeeded)
        let neverLooped = NotLoopingDeviceStatus(createdAt: now, lastCheckedDate: now, lastLoopDate: .distantPast)
        XCTAssertTrue(check(.notlooping, entry: notLooping, status: neverLooped).alertNeeded)
    }

    func testNotLoopingIgnoresOldDownloadsMissingStatusAndDisabledType() {
        let now = Date()
        let notLooping = entry(.notlooping, value: 15)
        let oldCheck = NotLoopingDeviceStatus(createdAt: now, lastCheckedDate: now.addingTimeInterval(-16 * 60), lastLoopDate: .distantPast)
        let oldCreated = NotLoopingDeviceStatus(createdAt: now.addingTimeInterval(-16 * 60), lastCheckedDate: now, lastLoopDate: .distantPast)
        XCTAssertFalse(check(.notlooping, entry: notLooping, status: oldCheck).alertNeeded)
        XCTAssertFalse(check(.notlooping, entry: notLooping, status: oldCreated).alertNeeded)
        XCTAssertFalse(check(.notlooping, entry: notLooping).alertNeeded)
        let fresh = NotLoopingDeviceStatus(createdAt: now, lastCheckedDate: now, lastLoopDate: .distantPast)
        XCTAssertFalse(check(.notlooping, entry: entry(.notlooping, value: 15, enabled: false), status: fresh).alertNeeded)
    }

    func testSanitizingFutureDatesReplacesOnlyDatesBeyondTolerance() {
        let reference = Date(timeIntervalSince1970: 1_000_000)
        let status = NotLoopingDeviceStatus(createdAt: reference.addingTimeInterval(21), lastCheckedDate: reference.addingTimeInterval(20), lastLoopDate: reference.addingTimeInterval(-60))
        let sanitized = status.sanitizingFutureDates(referenceDate: reference)
        XCTAssertEqual(sanitized.createdAt, .distantPast)
        XCTAssertEqual(sanitized.lastCheckedDate, reference.addingTimeInterval(20))
        XCTAssertEqual(sanitized.lastLoopDate, reference.addingTimeInterval(-60))
        let strict = status.sanitizingFutureDates(referenceDate: reference, futureTolerance: 0)
        XCTAssertEqual(strict.lastCheckedDate, .distantPast)
    }

    func testEventDrivenKindsNeverFireFromPeriodicChecks() {
        let reading = AppCoverageFactory.reading(40, at: Date(), in: core)
        for kind in [AlertKind.sensorTransmitterFailure, .sensorEndingSoon, .sensorExpectedExpiry] {
            XCTAssertFalse(check(kind, entry: entry(kind, value: 1), last: reading, battery: .percentage(percentage: 1)).alertNeeded)
        }
    }

    // MARK: - Dexcom battery settling policy

    func testDexcomBatterySuppressionOnlyAppliesToDexcomBatteryKindsDuringSettling() {
        let now = Date()
        let period = TimeInterval(ConstantsAlerts.dexcomBatteryAlertSuppressionPeriodInHours * 3600)
        XCTAssertTrue(DexcomBatteryAlertPolicy.shouldSuppress(alertKind: .dexcomG5BatteryLow, hardwareStartDate: nil, now: now))
        XCTAssertTrue(DexcomBatteryAlertPolicy.shouldSuppress(alertKind: .dexcomG7BatteryLow, hardwareStartDate: now.addingTimeInterval(-period + 60), now: now))
        XCTAssertFalse(DexcomBatteryAlertPolicy.shouldSuppress(alertKind: .dexcomG7BatteryLow, hardwareStartDate: now.addingTimeInterval(-period), now: now))
        XCTAssertFalse(DexcomBatteryAlertPolicy.shouldSuppress(alertKind: .batterylow, hardwareStartDate: nil, now: now))
        XCTAssertFalse(DexcomBatteryAlertPolicy.shouldSuppress(alertKind: .low, hardwareStartDate: nil, now: now))
    }

    // MARK: - Static descriptions and configuration

    func testBatteryAlertKindResolutionForTransmitterTypesAndPayloads() {
        XCTAssertEqual(AlertKind.batteryAlertKind(for: CGMTransmitterType.dexcom), .dexcomG5BatteryLow)
        XCTAssertEqual(AlertKind.batteryAlertKind(for: CGMTransmitterType.dexcomG7), .dexcomG7BatteryLow)
        for type in [CGMTransmitterType.miaomiao, .Bubble, .Libre2] {
            XCTAssertEqual(AlertKind.batteryAlertKind(for: type), .batterylow)
        }
        for type in [CGMTransmitterType.Libre3, .medtrumTouchCareNano] {
            XCTAssertNil(AlertKind.batteryAlertKind(for: type))
        }
        XCTAssertNil(AlertKind.batteryAlertKind(for: nil as CGMTransmitterType?))
        XCTAssertEqual(AlertKind.batteryAlertKind(for: TransmitterBatteryInfo.percentage(percentage: 5)), .batterylow)
        XCTAssertEqual(AlertKind.batteryAlertKind(for: TransmitterBatteryInfo.dexcom(family: .g7, voltageA: 1, voltageB: 1, resist: 0, runtime: 0, temperature: 0)), .dexcomG7BatteryLow)
        XCTAssertEqual(AlertKind.batteryAlertKind(for: TransmitterBatteryInfo.dexcom(family: .g5, voltageA: 1, voltageB: 1, resist: 0, runtime: 0, temperature: 0)), .dexcomG5BatteryLow)
        XCTAssertNil(AlertKind.batteryAlertKind(for: nil as TransmitterBatteryInfo?))
    }

    func testVisibleAlertKindsShowExactlyOneBatteryAlarmBeforePhoneBattery() {
        for type in [CGMTransmitterType.dexcom, .dexcomG7, .Libre2, .Libre3, nil] {
            let kinds = AlertKind.visibleAlertKinds(for: type)
            XCTAssertEqual(kinds.first, .verylow)
            XCTAssertEqual(kinds.last, .phonebatterylow)
            XCTAssertEqual(Set(kinds).count, kinds.count)
            let batteries = kinds.filter(\.isTransmitterBatteryAlert)
            XCTAssertEqual(batteries, AlertKind.batteryAlertKind(for: type).map { [$0] } ?? [])
            if SensorExpirySnapshot.supportsCurrentSource {
                XCTAssertEqual(kinds.firstIndex(of: .sensorExpectedExpiry).map { $0 + 1 }, kinds.firstIndex(of: .sensorTransmitterFailure))
            } else {
                XCTAssertFalse(kinds.contains(.sensorEndingSoon))
            }
        }
    }

    func testCapabilityFlagsPerKind() {
        let glucoseKinds: Set<AlertKind> = [.low, .high, .verylow, .veryhigh, .fastdrop, .fastrise]
        for kind in AlertKind.allCases {
            XCTAssertEqual(kind.createsImmediateNotificationWithBGReading(), glucoseKinds.contains(kind))
            XCTAssertEqual(kind.valueIsABgValue(), glucoseKinds.contains(kind))
            XCTAssertEqual(kind.needsAlertTriggerValue(), kind == .fastdrop || kind == .fastrise)
            XCTAssertEqual(kind.triggervalueIsABgValue(), kind.needsAlertTriggerValue())
            XCTAssertEqual(kind.needsAlertValue(), kind != .sensorTransmitterFailure && kind != .sensorExpectedExpiry)
            XCTAssertEqual(kind.supportsSnooze(), kind.supportsAlertSchedules())
            XCTAssertEqual(kind.supportsSnooze(), kind != .sensorTransmitterFailure && !kind.isSensorExpiryReminder)
            XCTAssertEqual(kind.isTransmitterBatteryAlert, [.batterylow, .dexcomG5BatteryLow, .dexcomG7BatteryLow].contains(kind))
            XCTAssertEqual(kind.defaultIsDisabled(), [.notlooping, .sensorEndingSoon, .sensorExpectedExpiry].contains(kind))
        }
    }

    func testDefaultValuesComeFromConstants() {
        XCTAssertEqual(AlertKind.low.defaultAlertValue(), ConstantsDefaultAlertLevels.low)
        XCTAssertEqual(AlertKind.high.defaultAlertValue(), ConstantsDefaultAlertLevels.high)
        XCTAssertEqual(AlertKind.verylow.defaultAlertValue(), ConstantsDefaultAlertLevels.veryLow)
        XCTAssertEqual(AlertKind.veryhigh.defaultAlertValue(), ConstantsDefaultAlertLevels.veryHigh)
        XCTAssertEqual(AlertKind.missedreading.defaultAlertValue(), ConstantsDefaultAlertLevels.missedReading)
        XCTAssertEqual(AlertKind.calibration.defaultAlertValue(), ConstantsDefaultAlertLevels.calibration)
        XCTAssertEqual(AlertKind.dexcomG5BatteryLow.defaultAlertValue(), ConstantsDefaultAlertLevels.defaultBatteryAlertLevelDexcomG5)
        XCTAssertEqual(AlertKind.dexcomG7BatteryLow.defaultAlertValue(), ConstantsDefaultAlertLevels.defaultBatteryAlertLevelDexcomG7)
        XCTAssertEqual(AlertKind.fastdrop.defaultAlertValue(), ConstantsDefaultAlertLevels.fastdrop)
        XCTAssertEqual(AlertKind.fastrise.defaultAlertValue(), ConstantsDefaultAlertLevels.fastrise)
        XCTAssertEqual(AlertKind.phonebatterylow.defaultAlertValue(), ConstantsDefaultAlertLevels.defaultBatteryAlertLevelPhone)
        XCTAssertEqual(AlertKind.notlooping.defaultAlertValue(), ConstantsDefaultAlertLevels.notLooping)
        XCTAssertEqual(AlertKind.sensorEndingSoon.defaultAlertValue(), 24)
        XCTAssertEqual(AlertKind.sensorExpectedExpiry.defaultAlertValue(), 0)
        XCTAssertEqual(AlertKind.fastdrop.defaultAlertTriggerValue(), ConstantsDefaultAlertLevels.fastdropTriggerValue)
        XCTAssertEqual(AlertKind.fastrise.defaultAlertTriggerValue(), ConstantsDefaultAlertLevels.fastriseTriggerValue)
        XCTAssertEqual(AlertKind.low.defaultAlertTriggerValue(), 0)
    }

    func testBatteryLowDefaultFollowsConfiguredTransmitter() {
        UserDefaults.standard.cgmTransmitterTypeAsString = nil
        XCTAssertEqual(AlertKind.batterylow.defaultAlertValue(), ConstantsDefaultAlertLevels.defaultBatteryAlertLevelMiaoMiao)
        UserDefaults.standard.cgmTransmitterTypeAsString = CGMTransmitterType.Bubble.rawValue
        XCTAssertEqual(AlertKind.batterylow.defaultAlertValue(), CGMTransmitterType.Bubble.defaultBatteryAlertLevel())
    }

    func testIdentifiersAndLogDescriptionsAreUnique() {
        let identifiers = AlertKind.allCases.map { $0.notificationIdentifier() }
        let descriptions = AlertKind.allCases.map { $0.descriptionForLogging() }
        XCTAssertEqual(Set(identifiers).count, AlertKind.allCases.count)
        XCTAssertEqual(Set(descriptions).count, AlertKind.allCases.count)
        XCTAssertEqual(AlertKind.sensorEndingSoon.notificationIdentifier(), "sensorExpiry.endingSoon")
        XCTAssertEqual(AlertKind.calibration.notificationIdentifier(), ConstantsNotifications.NotificationIdentifiersForCalibration.subsequentCalibrationRequest)
        XCTAssertEqual(AlertKind.dexcomG7BatteryLow.descriptionForLogging(), "dexcomG7BatteryLow")
    }

    func testTitlesAndConfigurationSuffixes() {
        for kind in AlertKind.allCases {
            XCTAssertFalse(kind.alertTitle().isEmpty)
            XCTAssertFalse(kind.largeSnoozeTitle().isEmpty)
            XCTAssertEqual(kind.configurationTitle(), kind.alertTitle() + kind.configurationFamilySuffix())
        }
        XCTAssertEqual(AlertKind.dexcomG5BatteryLow.configurationFamilySuffix(), " (G6)")
        XCTAssertEqual(AlertKind.dexcomG7BatteryLow.configurationFamilySuffix(), " (G7)")
        XCTAssertEqual(AlertKind.batterylow.configurationFamilySuffix(), "")
        XCTAssertEqual(AlertKind.low.largeSnoozeTitle(), Texts_Alerts.lowSnoozeTitle)
        XCTAssertEqual(AlertKind.fastrise.largeSnoozeTitle(), Texts_Alerts.fastRiseSnoozeTitle)
        XCTAssertEqual(AlertKind.missedreading.largeSnoozeTitle(), AlertKind.missedreading.alertTitle())
    }

    func testValueUnitTexts() {
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = true
        XCTAssertEqual(AlertKind.low.valueUnitText(transmitterType: nil), Texts_Common.mgdl)
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = false
        XCTAssertEqual(AlertKind.fastrise.valueUnitText(transmitterType: nil), Texts_Common.mmol)
        XCTAssertEqual(AlertKind.missedreading.valueUnitText(transmitterType: nil), Texts_Common.minutes)
        XCTAssertEqual(AlertKind.notlooping.valueUnitText(transmitterType: nil), Texts_Common.minutes)
        XCTAssertEqual(AlertKind.calibration.valueUnitText(transmitterType: nil), Texts_Common.hours)
        XCTAssertEqual(AlertKind.sensorEndingSoon.valueUnitText(transmitterType: nil), Texts_Common.hours)
        XCTAssertEqual(AlertKind.batterylow.valueUnitText(transmitterType: nil), "")
        XCTAssertEqual(AlertKind.batterylow.valueUnitText(transmitterType: .miaomiao), CGMTransmitterType.miaomiao.batteryUnit())
        XCTAssertEqual(AlertKind.dexcomG7BatteryLow.valueUnitText(transmitterType: .dexcomG7), "mV")
        XCTAssertEqual(AlertKind.phonebatterylow.valueUnitText(transmitterType: nil), "%")
        XCTAssertEqual(AlertKind.sensorTransmitterFailure.valueUnitText(transmitterType: nil), "")
    }

    func testDisplayedAndStoredValuesConvertDexcomTenMillivoltUnits() {
        XCTAssertEqual(AlertKind.dexcomG5BatteryLow.displayedAlertValue(fromStoredValue: 270), 2700)
        XCTAssertEqual(AlertKind.low.displayedAlertValue(fromStoredValue: 70), 70)
        XCTAssertEqual(AlertKind.dexcomG7BatteryLow.storedAlertValue(fromDisplayedValue: 2700), 270)
        XCTAssertNil(AlertKind.dexcomG7BatteryLow.storedAlertValue(fromDisplayedValue: 2705))
        XCTAssertNil(AlertKind.dexcomG7BatteryLow.storedAlertValue(fromDisplayedValue: 2700.5))
        XCTAssertNil(AlertKind.dexcomG5BatteryLow.storedAlertValue(fromDisplayedValue: 0))
        XCTAssertNil(AlertKind.dexcomG5BatteryLow.storedAlertValue(fromDisplayedValue: -10))
        XCTAssertNil(AlertKind.low.storedAlertValue(fromDisplayedValue: .nan))
        XCTAssertNil(AlertKind.low.storedAlertValue(fromDisplayedValue: .infinity))
        XCTAssertEqual(AlertKind.low.storedAlertValue(fromDisplayedValue: 70.9), 70)
    }

    func testSensorEndingSoonAcceptsOnlyWholeHoursFromOneToFortyEight() {
        XCTAssertEqual(AlertKind.sensorEndingSoon.storedAlertValue(fromDisplayedValue: 1), 1)
        XCTAssertEqual(AlertKind.sensorEndingSoon.storedAlertValue(fromDisplayedValue: 48), 48)
        XCTAssertNil(AlertKind.sensorEndingSoon.storedAlertValue(fromDisplayedValue: 0))
        XCTAssertNil(AlertKind.sensorEndingSoon.storedAlertValue(fromDisplayedValue: 49))
        XCTAssertNil(AlertKind.sensorEndingSoon.storedAlertValue(fromDisplayedValue: 12.5))
    }

    func testUrgencyClassification() {
        XCTAssertEqual(AlertKind.verylow.alertUrgencyType(), .urgent)
        XCTAssertEqual(AlertKind.veryhigh.alertUrgencyType(), .urgent)
        XCTAssertEqual(AlertKind.fastdrop.alertUrgencyType(), .urgent)
        for kind in [AlertKind.low, .high, .fastrise, .notlooping] {
            XCTAssertEqual(kind.alertUrgencyType(), .warning)
        }
        for kind in [AlertKind.missedreading, .calibration, .batterylow, .phonebatterylow, .sensorTransmitterFailure] {
            XCTAssertEqual(kind.alertUrgencyType(), .normal)
        }
    }

    // MARK: - Supporting alert types

    func testUrgencyRawValuesRoundTripAndUnknownBecomesNormal() {
        for type in [AlertUrgencyType.urgent, .warning, .normal] {
            XCTAssertEqual(AlertUrgencyType(rawValue: type.rawValue), type)
        }
        XCTAssertEqual(AlertUrgencyType(rawValue: 99), .normal)
        XCTAssertEqual(AlertUrgencyType(rawValue: -1), .normal)
        XCTAssertEqual(AlertUrgencyType.urgent.description, "Urgent")
        XCTAssertEqual(AlertUrgencyType.warning.description, "Warning")
        XCTAssertEqual(AlertUrgencyType.normal.description, "Normal")
        XCTAssertEqual(AlertUrgencyType.urgent.alertTitlePrefix, "‼️")
        XCTAssertEqual(AlertUrgencyType.warning.alertTitlePrefix, "")
        XCTAssertEqual(AlertUrgencyType.normal.alertTitlePrefix, "⚠️")
        XCTAssertEqual(AlertUrgencyType.warning.bannerTextColor, .black)
        XCTAssertEqual(AlertUrgencyType.urgent.bannerBackgroundColor, .red)
        XCTAssertEqual(AlertUrgencyType.warning.bannerBackgroundColor, .yellow)
        XCTAssertEqual(AlertUrgencyType.normal.bannerBackgroundColor, ConstantsAlerts.notificationBannerBackgroundColor)
        XCTAssertEqual(AlertUrgencyType.normal.bannerTextColor, .white.opacity(0.85))
    }

    func testSnoozeStatusDescriptions() {
        XCTAssertEqual(AlertSnoozeStatus.inactive.description, "inactive")
        XCTAssertEqual(AlertSnoozeStatus.urgent.description, "urgent")
        XCTAssertEqual(AlertSnoozeStatus.notUrgent.description, "non-urgent")
        XCTAssertEqual(AlertSnoozeStatus.allSnoozed.description, "all snoozed")
    }

    func testPickerViewDataDefaultsSelectedRowAndKeepsHandlers() {
        var selected: Int?
        let data = PickerViewData(withMainTitle: "Main", withSubTitle: nil, withData: ["a", "b"], selectedRow: nil, withPriority: .high, actionButtonText: "OK", cancelButtonText: nil, onActionClick: { selected = $0 }, onCancelClick: nil, didSelectRowHandler: nil)
        XCTAssertEqual(data.selectedRow, 0)
        XCTAssertEqual(data.fullScreen, false)
        XCTAssertNil(data.largePresentationTitle)
        data.actionHandler(1)
        XCTAssertEqual(selected, 1)
        XCTAssertEqual(PickerViewData(withMainTitle: nil, withSubTitle: nil, withData: [], selectedRow: 3, withPriority: nil, actionButtonText: nil, cancelButtonText: nil, isFullScreen: true, onActionClick: { _ in }, onCancelClick: nil, didSelectRowHandler: nil, largePresentationTitle: "L").selectedRow, 3)
    }

    func testAlertNotificationDictionaryEncodesOnlyPresentValues() throws {
        var dictionary = AlertNotificationDictionary()
        dictionary.alertTitle = "LOW"
        dictionary.bgReadingValues = [80, 75]
        dictionary.isMgDl = true
        dictionary.alertUrgencyTypeRawValue = 1
        let encoded = try XCTUnwrap(dictionary.asDictionary)
        XCTAssertEqual(encoded["alertTitle"] as? String, "LOW")
        XCTAssertEqual(encoded["bgReadingValues"] as? [Double], [80, 75])
        XCTAssertEqual(encoded["isMgDl"] as? Bool, true)
        XCTAssertEqual(encoded["alertUrgencyTypeRawValue"] as? Int, 1)
        XCTAssertNil(encoded["slopeOrdinal"])
        XCTAssertEqual(AlertNotificationDictionary().asDictionary?.count, 0)
    }

    func testSnoozeParametersExpireAndReportRemainingTime() throws {
        let parameters = SnoozeParametersAccessor(coreDataManager: core).getSnoozeParameters()[AlertKind.low.rawValue]
        XCTAssertFalse(parameters.getSnoozeValue().isSnoozed)
        parameters.snooze(snoozePeriodInMinutes: 10)
        let value = parameters.getSnoozeValue()
        XCTAssertTrue(value.isSnoozed)
        XCTAssertEqual(Double(try XCTUnwrap(value.remainingSeconds)), 600, accuracy: 2)
        parameters.snoozeTimeStamp = Date().addingTimeInterval(-11 * 60)
        XCTAssertFalse(parameters.getSnoozeValue().isSnoozed)
        XCTAssertNil(parameters.snoozeTimeStamp, "Expired snoozes are cleared")
        XCTAssertEqual(parameters.snoozePeriodInMinutes, 0)
        parameters.snooze(snoozePeriodInMinutes: 5)
        parameters.unSnooze()
        XCTAssertNil(parameters.getSnoozeValue().remainingSeconds)
    }
}
