//
//  AppCoverageAlertManagerTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import UserNotifications
import XCTest
@testable import xdrip

@MainActor
final class AppCoverageAlertManagerTests: XCTestCase {
    private var core: CoreDataManager!
    private var center: AppCoverageNotificationCenter!
    private var manager: AlertManager!

    override func setUp() async throws {
        try await super.setUp()
        appCoverageIsolateDefaults()
        let defaults = UserDefaults.standard
        defaults.isMaster = true
        defaults.snoozeAllAlertsUntilDate = nil
        defaults.bloodGlucoseUnitIsMgDl = true
        defaults.transmitterBatteryInfo = nil
        core = AppCoverageFactory.coreData()
        center = AppCoverageNotificationCenter()
    }

    override func tearDown() async throws {
        manager = nil
        try await super.tearDown()
    }

    /// Enables only the given kinds with the given values; all other kinds are disabled.
    private func configure(_ values: [AlertKind: (value: Int, trigger: Int)], snooze: Bool = true, sound: String? = "") -> AlertManager {
        let types = AlertTypesAccessor(coreDataManager: core)
        let entries = AlertEntriesAccessor(coreDataManager: core).getAllEntries(forAlertKind: nil, alertTypesAccessor: types)
        let alertType = AppCoverageFactory.alertType(core, snooze: snooze, snoozePeriod: 60, sound: sound)
        for entry in entries {
            guard let kind = AlertKind(rawValue: Int(entry.alertkind)), let setting = values[kind] else {
                entry.isDisabled = true
                continue
            }
            entry.isDisabled = false
            entry.value = Int16(setting.value)
            entry.triggerValue = Int16(setting.trigger)
            entry.alertType = alertType
        }
        let manager = AlertManager(coreDataManager: core, soundPlayer: nil, notificationCenter: center)
        self.manager = manager
        return manager
    }

    private func readings(_ values: [Double], interval: TimeInterval = 300, newestAge: TimeInterval = 0) {
        for (index, value) in values.enumerated() {
            AppCoverageFactory.reading(value, at: Date().addingTimeInterval(-newestAge - Double(values.count - 1 - index) * interval), in: core)
        }
    }

    // MARK: - checkAlerts

    func testLowReadingRaisesImmediateGlucoseNotificationAndSelfSnoozes() throws {
        let manager = configure([.low: (70, 0)])
        readings([90, 62])
        XCTAssertTrue(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
        let request = try XCTUnwrap(center.request(for: .low))
        XCTAssertNil(request.trigger)
        XCTAssertTrue(request.content.title.contains(Texts_Alerts.lowAlertTitle.uppercased()))
        XCTAssertTrue(request.content.title.contains("62"))
        XCTAssertEqual(request.content.categoryIdentifier, "snoozeCategoryIdentifier")
        XCTAssertEqual(request.content.userInfo["alertUrgencyTypeRawValue"] as? Int, AlertUrgencyType.warning.rawValue)
        XCTAssertEqual(request.content.userInfo["isMgDl"] as? Bool, true)
        XCTAssertEqual(request.content.userInfo["deltaValueInUserUnit"] as? Double, -28)
        XCTAssertEqual((request.content.userInfo["bgReadingValues"] as? [Double])?.first, 62)
        let snooze = manager.getSnoozeParameters(alertKind: .low).getSnoozeValue()
        XCTAssertTrue(snooze.isSnoozed)
        XCTAssertEqual(Double(try XCTUnwrap(snooze.remainingSeconds)), Double(ConstantsAlerts.defaultDelayBetweenAlertsOfSameKindInMinutes * 60), accuracy: 2)
    }

    func testSelfSnoozedAlertDoesNotRepeatOnNextCheck() {
        let manager = configure([.low: (70, 0)])
        readings([90, 62])
        XCTAssertTrue(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
        XCTAssertFalse(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
        XCTAssertNil(center.request(for: .low))
    }

    func testSnoozedVeryLowAlsoBlocksLowInTheSameGroup() {
        let manager = configure([.verylow: (55, 0), .low: (70, 0)])
        readings([90, 65])
        manager.snooze(alertKind: .verylow, snoozePeriodInMinutes: 30, response: nil)
        XCTAssertFalse(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
        XCTAssertNil(center.request(for: .low))
    }

    func testOnlyFirstTrippedGroupIsRaised() {
        let manager = configure([.fastdrop: (10, 200), .low: (130, 0)])
        readings([150, 120])
        XCTAssertTrue(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
        XCTAssertNotNil(center.request(for: .fastdrop))
        XCTAssertNil(center.request(for: .low), "Lower priority groups are skipped once one group fires")
    }

    func testHighReadingUsesNotificationWithoutSoundWhenSoundIsEmpty() throws {
        let manager = configure([.high: (180, 0)])
        readings([200])
        XCTAssertTrue(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
        let request = try XCTUnwrap(center.request(for: .high))
        XCTAssertNil(request.content.sound)
        XCTAssertEqual(request.content.userInfo["deltaValueInUserUnit"] as? Double, 0)
        XCTAssertEqual(request.content.userInfo["slopeOrdinal"] as? Int, 0)
    }

    func testConfiguredSoundAndDefaultSoundAreAppliedWithoutOverrideMute() throws {
        let sound = try XCTUnwrap(ConstantsSounds.allCases.first?.rawValue.split(separator: "/").map(String.init))
        let manager = configure([.high: (180, 0)], sound: sound[0])
        readings([200])
        _ = manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60)
        XCTAssertNotNil(try XCTUnwrap(center.request(for: .high)).content.sound)
        let core2 = AppCoverageFactory.coreData()
        core = core2
        center = AppCoverageNotificationCenter()
        let defaultSound = configure([.high: (180, 0)], sound: nil)
        readings([200])
        _ = defaultSound.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60)
        XCTAssertNotNil(try XCTUnwrap(center.request(for: .high)).content.sound)
    }

    func testAlertTypeWithoutSnoozeUsesDismissCategory() throws {
        let manager = configure([.high: (180, 0)], snooze: false)
        readings([200])
        _ = manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60)
        XCTAssertEqual(try XCTUnwrap(center.request(for: .high)).content.categoryIdentifier, "dismissCategoryIdentifier")
    }

    func testStaleOrMissingReadingsRaiseNothingAndKeepPendingAlerts() {
        let manager = configure([.low: (70, 0), .missedreading: (30, 0)])
        XCTAssertFalse(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
        readings([50], newestAge: 600)
        XCTAssertFalse(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertFalse(center.removedPending.contains(AlertKind.missedreading.notificationIdentifier()))
        XCTAssertTrue(center.removedDelivered.contains(AlertKind.low.notificationIdentifier()))
    }

    func testDisabledEntryNeverFires() {
        let manager = configure([.high: (180, 0)])
        readings([50])
        XCTAssertFalse(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
        XCTAssertTrue(center.requests.isEmpty)
    }

    func testFollowerWithoutKeepAliveDoesNotRaiseAlerts() {
        UserDefaults.standard.isMaster = false
        UserDefaults.standard.followerBackgroundKeepAliveType = .disabled
        let manager = configure([.low: (70, 0)])
        readings([50])
        XCTAssertFalse(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
        XCTAssertNil(center.request(for: .low))
        UserDefaults.standard.followerBackgroundKeepAliveType = .normal
        XCTAssertTrue(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
    }

    func testSnoozeAllSuppressesConditionsAndClearsPendingAlerts() {
        UserDefaults.standard.snoozeAllAlertsUntilDate = Date().addingTimeInterval(3600)
        let manager = configure([.low: (70, 0)])
        readings([50])
        XCTAssertFalse(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
        XCTAssertNil(center.request(for: .low))
        XCTAssertTrue(center.removedPending.contains(AlertKind.low.notificationIdentifier()))
        XCTAssertEqual(manager.snoozeStatus(), .allSnoozed)
    }

    func testMissedReadingIsScheduledAsRepeatingFutureNotification() throws {
        let manager = configure([.missedreading: (30, 0)])
        readings([120])
        XCTAssertFalse(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
        let request = try XCTUnwrap(center.request(for: .missedreading))
        let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 1800, accuracy: 60)
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(request.content.categoryIdentifier, "textOnlySnoozeCategoryIdentifier")
        XCTAssertNil(request.content.userInfo["bgReadingValues"])
        XCTAssertFalse(manager.getSnoozeParameters(alertKind: .missedreading).getSnoozeValue().isSnoozed, "Delayed alerts are not self-snoozed")
    }

    func testCalibrationAlertIsTextOnly() throws {
        let manager = configure([.calibration: (4, 0)])
        let sensor = Sensor(startDate: Date().addingTimeInterval(-86_400), nsManagedObjectContext: core.mainManagedObjectContext)
        _ = AppCoverageFactory.calibration(at: Date().addingTimeInterval(-6 * 3600), sensor: sensor, core: core)
        readings([120])
        XCTAssertFalse(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60), "Calibration alerts do not include the reading")
        let request = try XCTUnwrap(center.request(for: .calibration))
        XCTAssertEqual(request.content.categoryIdentifier, "textOnlySnoozeCategoryIdentifier")
        XCTAssertTrue(request.content.title.contains(Texts_Alerts.calibrationNeededAlertTitle.uppercased()))
        XCTAssertNil(request.content.userInfo["bgReadingValues"])
    }

    func testPercentageBatteryAlertFiresButUnsettledDexcomBatteryIsSuppressed() {
        let manager = configure([.batterylow: (20, 0), .dexcomG5BatteryLow: (300, 0)])
        readings([120])
        UserDefaults.standard.transmitterBatteryInfo = .percentage(percentage: 10)
        _ = manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60)
        XCTAssertNotNil(center.request(for: .batterylow))
        UserDefaults.standard.transmitterBatteryInfo = .dexcom(family: .g5, voltageA: 300, voltageB: 250, resist: 0, runtime: 0, temperature: 0)
        _ = manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60)
        XCTAssertNil(center.request(for: .dexcomG5BatteryLow), "No saved Dexcom start date means the battery is still settling")
    }

    // MARK: - Snooze state

    func testSnoozeStatusReportsMostUrgentSnoozedKind() {
        let manager = configure([:])
        XCTAssertEqual(manager.snoozeStatus(), .inactive)
        manager.snooze(alertKind: .high, snoozePeriodInMinutes: 30, response: nil)
        XCTAssertEqual(manager.snoozeStatus(), .notUrgent)
        manager.snooze(alertKind: .veryhigh, snoozePeriodInMinutes: 30, response: nil)
        XCTAssertEqual(manager.snoozeStatus(), .urgent)
        manager.unSnooze(alertKind: .veryhigh)
        XCTAssertEqual(manager.snoozeStatus(), .notUrgent)
        manager.unSnooze(alertKind: .high)
        XCTAssertEqual(manager.snoozeStatus(), .inactive)
    }

    func testEnabledAlertKindsExcludeDisabledAndUnsnoozableKinds() {
        UserDefaults.standard.cgmTransmitterTypeAsString = CGMTransmitterType.dexcomG7.rawValue
        let manager = configure([.low: (70, 0), .high: (180, 0), .sensorTransmitterFailure: (0, 0), .dexcomG7BatteryLow: (250, 0), .batterylow: (20, 0)])
        XCTAssertEqual(manager.enabledAlertKinds(), [.low, .high, .dexcomG7BatteryLow])
    }

    func testPickerDataSelectsDefaultSnoozeAndSnoozesChosenPeriod() throws {
        let manager = configure([.high: (180, 0)])
        var actionCalled = false
        var cancelCalled = false
        let picker = manager.createPickerViewData(forAlertKind: .high, content: nil, actionHandler: { actionCalled = true }, cancelHandler: { cancelCalled = true })
        XCTAssertEqual(picker.mainTitle, AlertKind.high.configurationTitle())
        XCTAssertEqual(picker.largePresentationTitle, AlertKind.high.largeSnoozeTitle())
        XCTAssertEqual(picker.data, ConstantsAlerts.snoozeValueStrings)
        XCTAssertEqual(picker.priority, .high)
        XCTAssertEqual(picker.fullScreen, true)
        let expectedRow = try XCTUnwrap(ConstantsAlerts.snoozeValueMinutes.lastIndex { $0 <= 60 })
        XCTAssertEqual(picker.selectedRow, expectedRow)
        picker.actionHandler(0)
        XCTAssertTrue(actionCalled)
        XCTAssertEqual(Int(manager.getSnoozeParameters(alertKind: .high).snoozePeriodInMinutes), ConstantsAlerts.snoozeValueMinutes[0])
        picker.cancelHandler?()
        XCTAssertTrue(cancelCalled)
    }

    func testUnsnoozingMissedReadingReschedulesFromLatestReading() throws {
        let manager = configure([.missedreading: (30, 0)])
        readings([120], newestAge: 40 * 60)
        manager.snooze(alertKind: .missedreading, snoozePeriodInMinutes: 60, response: nil)
        let snoozed = try XCTUnwrap(center.request(for: .missedreading)?.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(snoozed.timeInterval, 3600, accuracy: 2)
        manager.unSnooze(alertKind: .missedreading)
        let overdue = try XCTUnwrap(center.request(for: .missedreading)?.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(overdue.timeInterval, 60, "Overdue alerts repeat at the minimum interval")
    }

    // MARK: - Sounds and one-off alarms

    func testResolvedSoundFileNameMapsUserFacingNames() throws {
        let manager = configure([:])
        let first = try XCTUnwrap(ConstantsSounds.allCases.first?.rawValue.split(separator: "/").map(String.init))
        XCTAssertNil(manager.resolvedSoundFileName(for: AppCoverageFactory.alertType(core, sound: nil)))
        XCTAssertEqual(manager.resolvedSoundFileName(for: AppCoverageFactory.alertType(core, sound: "")), "")
        XCTAssertEqual(manager.resolvedSoundFileName(for: AppCoverageFactory.alertType(core, sound: first[0])), first[1])
        XCTAssertEqual(manager.resolvedSoundFileName(for: AppCoverageFactory.alertType(core, sound: "no such sound")), "xdripalert.aif")
    }

    func testOneOffSensorFailureAlarmRespectsEnabledStateAndCanBeCleared() throws {
        let issue = SensorHealthIssue(id: "issue-1", kind: .terminalFailure, severity: .terminal, source: .dexcom, reason: .dexcomSensorFailure, firstSeen: Date(), sensorSessionID: "s", destination: .sensorManagement)
        let identifier = SensorHealthIssueManager.notificationIdentifierPrefix + issue.id
        let disabled = configure([:])
        disabled.raiseOneOffSensorFailureAlarm(issue)
        XCTAssertNil(center.requests[identifier])
        let enabled = configure([.sensorTransmitterFailure: (0, 0)])
        enabled.raiseOneOffSensorFailureAlarm(issue)
        let request = try XCTUnwrap(center.requests[identifier])
        XCTAssertEqual(request.content.title, issue.title)
        XCTAssertEqual(request.content.body, issue.guidance)
        XCTAssertEqual(request.content.threadIdentifier, "sensorHealth")
        XCTAssertEqual(request.content.userInfo[SensorHealthIssueManager.notificationIsTerminalUserInfoKey] as? Bool, true)
        enabled.clearOneOffSensorFailureAlarm(notificationIdentifier: identifier)
        XCTAssertNil(center.requests[identifier])
        XCTAssertTrue(center.removedDelivered.contains(identifier))
    }

    func testFailedNotificationSubmissionStillReportsRaisedAlert() {
        center.failure = NSError(domain: "test", code: 1)
        let manager = configure([.high: (180, 0)])
        readings([200])
        XCTAssertTrue(manager.checkAlerts(maxAgeOfLastBgReadingInSeconds: 60))
        XCTAssertTrue(center.requests.isEmpty)
    }

    // MARK: - Not looping

    private func enableAIDStatus() {
        let defaults = UserDefaults.standard
        defaults.nightscoutEnabled = true
        defaults.therapyDataSourceType = .nightscout
        defaults.nightscoutFollowType = .loop
    }

    func testNotLoopingAlertFiresOnceAndThrottlesRepeats() throws {
        enableAIDStatus()
        let manager = configure([.notlooping: (15, 0)])
        XCTAssertTrue(UserDefaults.standard.dataFlowPolicy.showsAIDData)
        let now = Date()
        let status = NotLoopingDeviceStatus(createdAt: now, lastCheckedDate: now, lastLoopDate: now.addingTimeInterval(-30 * 60))
        XCTAssertTrue(manager.checkNotLoopingAlert(deviceStatus: status))
        let request = try XCTUnwrap(center.request(for: .notlooping))
        XCTAssertEqual(request.content.title, Texts_Alerts.notLoopingAlertTitle)
        XCTAssertFalse(manager.checkNotLoopingAlert(deviceStatus: status), "Repeat is throttled")
        XCTAssertFalse(manager.getSnoozeParameters(alertKind: .notlooping).getSnoozeValue().isSnoozed)
    }

    func testNotLoopingAlertClearsWhenLoopRecoversOrDataUnavailable() {
        enableAIDStatus()
        let manager = configure([.notlooping: (15, 0)])
        let now = Date()
        let recovered = NotLoopingDeviceStatus(createdAt: now, lastCheckedDate: now, lastLoopDate: now.addingTimeInterval(-60))
        XCTAssertFalse(manager.checkNotLoopingAlert(deviceStatus: recovered))
        XCTAssertTrue(center.removedPending.contains(AlertKind.notlooping.notificationIdentifier()))
        XCTAssertFalse(manager.checkNotLoopingAlert(deviceStatus: nil))
        let staleDownload = NotLoopingDeviceStatus(createdAt: now.addingTimeInterval(-3600), lastCheckedDate: now.addingTimeInterval(-3600), lastLoopDate: .distantPast)
        XCTAssertFalse(manager.checkNotLoopingAlert(deviceStatus: staleDownload))
        let futureLoop = NotLoopingDeviceStatus(createdAt: now, lastCheckedDate: now, lastLoopDate: now.addingTimeInterval(3600))
        XCTAssertTrue(manager.checkNotLoopingAlert(deviceStatus: futureLoop), "A loop date from the future is treated as missing")
    }

    func testNotLoopingIsSkippedWithoutAIDImportOrDuringSnoozeAll() {
        UserDefaults.standard.nightscoutEnabled = false
        let manager = configure([.notlooping: (15, 0)])
        let now = Date()
        let status = NotLoopingDeviceStatus(createdAt: now, lastCheckedDate: now, lastLoopDate: .distantPast)
        XCTAssertFalse(manager.checkNotLoopingAlert(deviceStatus: status))
        enableAIDStatus()
        UserDefaults.standard.snoozeAllAlertsUntilDate = Date().addingTimeInterval(600)
        XCTAssertFalse(manager.checkNotLoopingAlert(deviceStatus: status))
        XCTAssertNil(center.request(for: .notlooping))
    }

    func testNotLoopingChangeFlagResetsItself() {
        let manager = configure([.notlooping: (15, 0)])
        UserDefaults.standard.notLoopingAlertChanged = true
        XCTAssertFalse(UserDefaults.standard.notLoopingAlertChanged)
        UserDefaults.standard.missedReadingAlertChanged = true
        XCTAssertFalse(UserDefaults.standard.missedReadingAlertChanged)
        withExtendedLifetime(manager) {}
    }
}
