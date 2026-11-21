//
//  DataCoverageUserDefaultsTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

final class DataCoverageUserDefaultsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DataCoverageUserDefaults-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testInvertedBooleansDefaultToTrueAndRoundTrip() {
        let properties: [ReferenceWritableKeyPath<UserDefaults, Bool>] = [
            \.isMaster, \.masterUploadDataToNightscout, \.showReadingInNotification, \.multipleAppBadgeValueWith10,
            \.showTarget, \.allowScreenRotation, \.showClockWhenScreenIsLocked, \.showOriginalBGReadings, \.showSensorNoise,
            \.showTreatmentsOnChart, \.showBolusTreatmentsInList, \.showCarbsTreatmentsInList, \.showBgCheckTreatmentsInList,
            \.showBasalInjectionTreatmentsInList, \.showNoteTreatmentsInList, \.allowStandByHighContrast, \.showStatisticsOnLandscapeChart
        ]
        for property in properties {
            XCTAssertTrue(defaults[keyPath: property], "\(property)")
            defaults[keyPath: property] = false
            XCTAssertFalse(defaults[keyPath: property], "\(property)")
            defaults[keyPath: property] = true
            XCTAssertTrue(defaults[keyPath: property], "\(property)")
        }
        defaults.isMaster = false
        XCTAssertTrue(defaults.bool(forKey: UserDefaults.Key.isMaster.rawValue))
    }

    func testPlainBooleansDefaultToFalseAndRoundTrip() {
        let properties: [ReferenceWritableKeyPath<UserDefaults, Bool>] = [
            \.showReadingInAppBadge, \.enableAdjustment, \.enableCurveAdjustment, \.showTreatmentsOnLandscapeChart,
            \.showSmallBolusTreatmentsInList, \.showBasalTreatmentsInList, \.useSmallDoseTreatmentScale, \.statisticsUseHbA1c,
            \.useIFCCA1C, \.tirChartHasDynamicYAxis, \.nightscoutEnabled, \.nightscoutUseSchedule, \.uploadSensorStartTimeToNS,
            \.uploadReadingstoDexcomShare, \.useUSDexcomShareurl, \.dexcomShareManuallyLoggedOut, \.dexcomShareUploadUseSchedule,
            \.storeReadingsInHealthkit, \.speakReadings, \.speakReadingsScheduleEnabled, \.speakTrend, \.speakDelta,
            \.followerUploadDataToNightscout, \.libreLinkUpReAcceptNeeded, \.libreLinkUpIs15DaySensor, \.libreLinkUpPreventLogin,
            \.libreLinkUpManuallyLoggedOut, \.medtrumEasyViewPreventLogin, \.medtrumEasyViewManuallyLoggedOut, \.medtrumEasyViewConnectionsFetchFailed
        ]
        for property in properties {
            XCTAssertFalse(defaults[keyPath: property], "\(property)")
            defaults[keyPath: property] = true
            XCTAssertTrue(defaults[keyPath: property], "\(property)")
        }
    }

    func testOptionalBooleansDefaultToTrueUntilStored() {
        let properties: [ReferenceWritableKeyPath<UserDefaults, Bool>] = [
            \.liveActivityShowIOBCOB, \.renderBasalDownwards, \.sensorHealthNotificationsEnabled, \.preferLargeSnoozeScreen,
            \.automaticHousekeepingEnabled, \.speakIntroduction, \.dexcomG7UseOtherApp
        ]
        for property in properties {
            XCTAssertTrue(defaults[keyPath: property], "\(property)")
            defaults[keyPath: property] = false
            XCTAssertFalse(defaults[keyPath: property], "\(property)")
        }
    }

    func testGlucoseAdjustmentFallsBackToLegacyFlag() {
        XCTAssertFalse(defaults.enableGlucoseAdjustment)
        defaults.enableAdjustment = true
        XCTAssertTrue(defaults.enableGlucoseAdjustment)
        defaults.enableGlucoseAdjustment = false
        XCTAssertFalse(defaults.enableGlucoseAdjustment)
        XCTAssertTrue(defaults.enableAdjustment)
    }

    func testSmoothingSettingsUseDefaultsUntilStored() {
        XCTAssertEqual(defaults.bgSmoothingPeriodInMinutes, ConstantsBgSmoothing.defaultSmoothingPeriodInMinutes)
        XCTAssertEqual(defaults.bgSmoothingStrength, ConstantsBgSmoothing.defaultSmoothingStrength)
        XCTAssertEqual(defaults.bgSmoothingAlgorithm, ConstantsBgSmoothing.defaultSmoothingAlgorithm)
        XCTAssertEqual(defaults.useFiveMinuteReadings, ConstantsBgSmoothing.defaultUseFiveMinuteReadings)
        XCTAssertEqual(defaults.postProcessingPreviewChartHoursToShow, ConstantsBgAdjustment.defaultPreviewChartHoursToShow)
        defaults.bgSmoothingPeriodInMinutes = 0
        XCTAssertEqual(defaults.bgSmoothingPeriodInMinutes, ConstantsBgSmoothing.defaultSmoothingPeriodInMinutes)
        defaults.bgSmoothingPeriodInMinutes = 45
        defaults.bgSmoothingStrength = 0
        defaults.bgSmoothingAlgorithm = .loess
        defaults.useFiveMinuteReadings = true
        defaults.postProcessingPreviewChartHoursToShow = 12
        XCTAssertEqual(defaults.bgSmoothingPeriodInMinutes, 45)
        XCTAssertEqual(defaults.bgSmoothingStrength, 0)
        XCTAssertEqual(defaults.bgSmoothingAlgorithm, .loess)
        XCTAssertTrue(defaults.useFiveMinuteReadings)
        XCTAssertEqual(defaults.postProcessingPreviewChartHoursToShow, 12)
        defaults.set("median", forKey: UserDefaults.Key.bgSmoothingAlgorithm.rawValue)
        XCTAssertEqual(defaults.bgSmoothingAlgorithm, ConstantsBgSmoothing.defaultSmoothingAlgorithm)
    }

    func testDisablingSmoothingAlsoDisablesSmoothedLoopSharing() {
        defaults.loopShareSmoothedData = true
        XCTAssertFalse(defaults.loopShareSmoothedData)
        defaults.loopShareType = .loop
        defaults.enableSmoothing = true
        defaults.loopShareSmoothedData = true
        XCTAssertTrue(defaults.loopShareSmoothedData)
        defaults.enableSmoothing = false
        XCTAssertFalse(defaults.loopShareSmoothedData)
        defaults.enableSmoothing = true
        defaults.loopShareSmoothedData = true
        defaults.loopShareType = .trio
        XCTAssertFalse(defaults.loopShareSmoothedData)
        XCTAssertEqual(defaults.loopShareType, .trio)
    }

    func testOSAidSharingPolicyDependsOnSource() {
        XCTAssertEqual(defaults.loopShareType, .disabled)
        XCTAssertFalse(defaults.canPublishOSAidData)
        defaults.loopShareType = .loop
        XCTAssertEqual(defaults.activeOSAidSharingPolicy, .allowed)
        XCTAssertTrue(defaults.canConfigureOSAidSharing)
        XCTAssertTrue(defaults.canPublishOSAidData)
        XCTAssertFalse(defaults.loopShareMedtrumNanoAvailable)
        defaults.cgmTransmitterTypeAsString = CGMTransmitterType.medtrumTouchCareNano.rawValue
        XCTAssertEqual(defaults.activeOSAidSharingPolicy, .blocked)
        XCTAssertFalse(defaults.canConfigureOSAidSharing)
        XCTAssertFalse(defaults.canPublishOSAidData)
        defaults.isMaster = false
        defaults.followerDataSourceType = .medtrumEasyView
        XCTAssertEqual(defaults.activeOSAidSharingPolicy, .requiresExplicitConsent)
        XCTAssertTrue(defaults.loopShareMedtrumNanoAvailable)
        XCTAssertFalse(defaults.canPublishOSAidData)
        defaults.loopShareMedtrumNano = true
        XCTAssertTrue(defaults.canPublishOSAidData)
        defaults.loopShareType = .disabled
        XCTAssertFalse(defaults.loopShareMedtrumNano)
        defaults.loopShareMedtrumNano = true
        XCTAssertFalse(defaults.loopShareMedtrumNano)
    }

    func testMarkValuesUseDefaultsAndConvertToMmol() {
        XCTAssertEqual(defaults.urgentHighMarkValueInUserChosenUnit, ConstantsBGGraphBuilder.defaultUrgentHighMarkInMgdl)
        XCTAssertEqual(defaults.highMarkValueInUserChosenUnit, ConstantsBGGraphBuilder.defaultHighMarkInMgdl)
        XCTAssertEqual(defaults.lowMarkValueInUserChosenUnit, ConstantsBGGraphBuilder.defaultLowMarkInMgdl)
        XCTAssertEqual(defaults.urgentLowMarkValueInUserChosenUnit, ConstantsBGGraphBuilder.defaultUrgentLowMarkInMgdl)
        XCTAssertEqual(defaults.targetMarkValueInUserChosenUnit, 0)
        XCTAssertEqual(defaults.highMarkValue, 0)
        defaults.set(200.0, forKey: UserDefaults.Key.highMarkValue.rawValue)
        defaults.set(60.0, forKey: UserDefaults.Key.lowMarkValue.rawValue)
        XCTAssertEqual(defaults.highMarkValueInUserChosenUnitRounded, "200")
        XCTAssertEqual(defaults.lowMarkValue, 60)
        defaults.set(true, forKey: UserDefaults.Key.bloodGlucoseUnitIsMgDl.rawValue)
        XCTAssertFalse(defaults.bloodGlucoseUnitIsMgDl)
        XCTAssertEqual(defaults.highMarkValueInUserChosenUnit, 200 * ConstantsBloodGlucose.mgDlToMmoll, accuracy: 0.000_001)
        XCTAssertEqual(defaults.highMarkValueInUserChosenUnitRounded, "11.1")
        XCTAssertEqual(defaults.lowMarkValueInUserChosenUnitRounded, "3.3")
        XCTAssertEqual(defaults.urgentHighMarkValueInUserChosenUnit, ConstantsBGGraphBuilder.defaultUrgentHighMarkInMgdl.mgDlToMmol(), accuracy: 0.000_001)
        XCTAssertEqual(defaults.urgentLowMarkValueInUserChosenUnitRounded, ConstantsBGGraphBuilder.defaultUrgentLowMarkInMgdl.mgDlToMmol().bgValueToString(mgDl: false))
        defaults.targetMarkValueInUserChosenUnitRounded = "5,5"
        XCTAssertEqual(defaults.double(forKey: UserDefaults.Key.targetMarkValue.rawValue), 5.5.mmolToMgdl(), accuracy: 0.000_001)
        XCTAssertEqual(defaults.targetMarkValueInUserChosenUnitRounded, "5.5")
        defaults.targetMarkValueInUserChosenUnit = 6
        XCTAssertEqual(defaults.targetMarkValueInUserChosenUnit, 6, accuracy: 0.000_001)
    }

    func testNumericSettingsWithFallbacks() {
        XCTAssertEqual(defaults.CAGEMaxHours, ConstantsHomeView.CAGEDefaultMaxHours)
        defaults.CAGEMaxHours = 96
        XCTAssertEqual(defaults.CAGEMaxHours, 96)
        XCTAssertEqual(defaults.forceComplicationUpdateInMinutes, ConstantsWidget.defaultForceComplicationRefreshTimeInMinutes)
        defaults.forceComplicationUpdateInMinutes = 15
        XCTAssertEqual(defaults.forceComplicationUpdateInMinutes, 15)
        XCTAssertEqual(defaults.smallBolusTreatmentThreshold, ConstantsGlucoseChart.defaultSmallBolusTreatmentThreshold)
        XCTAssertEqual(defaults.smallCarbTreatmentThreshold, ConstantsGlucoseChart.defaultSmallCarbTreatmentThreshold)
        defaults.smallBolusTreatmentThreshold = 0
        defaults.smallCarbTreatmentThreshold = 3
        XCTAssertEqual(defaults.smallBolusTreatmentThreshold, 0)
        XCTAssertEqual(defaults.smallCarbTreatmentThreshold, 3)
        XCTAssertEqual(defaults.calendarShareHistoryInMinutes, 60)
        defaults.calendarShareHistoryInMinutes = 0
        XCTAssertEqual(defaults.calendarShareHistoryInMinutes, 0)
        XCTAssertEqual(defaults.libreActiveSensorUnlockCode, 42)
        defaults.libreActiveSensorUnlockCode = 7
        XCTAssertEqual(defaults.libreActiveSensorUnlockCode, 7)
        defaults.libreActiveSensorUnlockCount = 3
        XCTAssertEqual(defaults.libreActiveSensorUnlockCount, 3)
    }

    func testLandscapeComparisonDaysAcceptsOnlyKnownOptions() {
        XCTAssertEqual(defaults.landscapeComparisonDays, 7)
        for value in [0, 3, 30, 60, 90] {
            defaults.landscapeComparisonDays = value
            XCTAssertEqual(defaults.landscapeComparisonDays, value)
        }
        defaults.landscapeComparisonDays = 5
        XCTAssertEqual(defaults.landscapeComparisonDays, 7)
        defaults.set(14, forKey: UserDefaults.Key.landscapeComparisonDays.rawValue)
        XCTAssertEqual(defaults.landscapeComparisonDays, 7)
    }

    func testRetentionPeriodSnapsToNearestSupportedValue() {
        XCTAssertEqual(defaults.retentionPeriodInDays, ConstantsHousekeeping.defaultRetentionPeriodInDays)
        for (input, expected) in [(1, 7), (20, 30), (18, 7), (60, 30), (61, 90), (200, 180), (1000, 365), (-5, 90)] {
            defaults.retentionPeriodInDays = input
            XCTAssertEqual(defaults.retentionPeriodInDays, expected, "\(input)")
        }
        defaults.set(100, forKey: UserDefaults.Key.retentionPeriodInDays.rawValue)
        XCTAssertEqual(defaults.retentionPeriodInDays, 90)
    }

    func testEnumSettingsFallBackForUnknownRawValues() {
        XCTAssertEqual(defaults.followerDataSourceType, .nightscout)
        XCTAssertEqual(defaults.timeInRangeType, .standardRange)
        XCTAssertEqual(defaults.nightscoutFollowType, NightscoutFollowType.none)
        XCTAssertEqual(defaults.dexcomShareRegion, DexcomShareRegion.none)
        XCTAssertEqual(defaults.screenLockDimmingType, .disabled)
        XCTAssertEqual(defaults.carPlayLiveActivityType, .chart)
        XCTAssertEqual(defaults.automaticBasalRenderingStyle, .deliveredDoses)
        XCTAssertEqual(defaults.sensorNoiseSensitivity, .normal)
        for key in [UserDefaults.Key.followerDataSourceType, .timeInRangeType, .nightscoutFollowType, .dexcomShareRegion, .screenLockDimmingType, .sensorNoiseSensitivity] {
            defaults.set(999, forKey: key.rawValue)
        }
        XCTAssertEqual(defaults.followerDataSourceType, .nightscout)
        XCTAssertEqual(defaults.timeInRangeType, .standardRange)
        XCTAssertEqual(defaults.dexcomShareRegion, DexcomShareRegion.none)
        XCTAssertEqual(defaults.sensorNoiseSensitivity, .normal)
        defaults.followerDataSourceType = .careLink
        defaults.timeInRangeType = .tightRange
        defaults.dexcomShareRegion = .jp
        defaults.sensorNoiseSensitivity = .permissive
        XCTAssertEqual(defaults.followerDataSourceType, .careLink)
        XCTAssertEqual(defaults.timeInRangeType, .tightRange)
        XCTAssertEqual(defaults.dexcomShareRegion, .jp)
        XCTAssertEqual(defaults.sensorNoiseSensitivity, .permissive)
    }

    func testLiveActivityMigrationTurnsLegacyDisabledIntoNormalStyle() {
        XCTAssertFalse(defaults.liveActivitiesEnabled)
        XCTAssertEqual(defaults.liveActivityType, .normal)
        let legacyEnabledName = "\(suiteName)-legacy"
        let legacy = UserDefaults(suiteName: legacyEnabledName)!
        defer { legacy.removePersistentDomain(forName: legacyEnabledName) }
        legacy.set(LiveActivityType.large.rawValue, forKey: UserDefaults.Key.liveActivityType.rawValue)
        XCTAssertEqual(legacy.liveActivityType, .large)
        XCTAssertTrue(legacy.liveActivitiesEnabled)
        legacy.liveActivityType = .disabled
        XCTAssertEqual(legacy.liveActivityType, .normal)
    }

    func testTransmitterTypeParsesStoredString() {
        XCTAssertNil(defaults.cgmTransmitterType)
        defaults.cgmTransmitterTypeAsString = CGMTransmitterType.dexcomG7.rawValue
        XCTAssertEqual(defaults.cgmTransmitterType, .dexcomG7)
        defaults.cgmTransmitterTypeAsString = "unknown"
        XCTAssertNil(defaults.cgmTransmitterType)
        defaults.cgmTransmitterTypeAsString = nil
        XCTAssertNil(defaults.cgmTransmitterTypeAsString)
    }

    func testSpeechScheduleHandlesNormalAndOvernightWindows() throws {
        func time(_ hour: Int, _ minute: Int = 0) throws -> Date {
            try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour, minute: minute)))
        }
        XCTAssertFalse(defaults.shouldSpeakReadings(at: try time(12)))
        defaults.speakReadings = true
        XCTAssertTrue(defaults.shouldSpeakReadings(at: try time(3)))
        defaults.speakReadingsScheduleEnabled = true
        XCTAssertEqual(defaults.speakReadingsStartMinute, 540)
        XCTAssertEqual(defaults.speakReadingsEndMinute, 1320)
        XCTAssertFalse(defaults.shouldSpeakReadings(at: try time(8, 59)))
        XCTAssertTrue(defaults.shouldSpeakReadings(at: try time(9)))
        XCTAssertTrue(defaults.shouldSpeakReadings(at: try time(21, 59)))
        XCTAssertFalse(defaults.shouldSpeakReadings(at: try time(22)))
        defaults.speakReadingsStartMinute = 22 * 60
        defaults.speakReadingsEndMinute = 6 * 60
        XCTAssertTrue(defaults.shouldSpeakReadings(at: try time(23)))
        XCTAssertTrue(defaults.shouldSpeakReadings(at: try time(5, 59)))
        XCTAssertFalse(defaults.shouldSpeakReadings(at: try time(12)))
        defaults.speakReadingsEndMinute = 22 * 60
        XCTAssertFalse(defaults.shouldSpeakReadings(at: try time(22)))
        defaults.speakReadingsEndMinute = 1440
        XCTAssertFalse(defaults.shouldSpeakReadings(at: try time(23)))
    }

    func testCareLinkDeviceOffsetsAreValidatedPerAccountAndPatient() {
        XCTAssertNil(defaults.careLinkDeviceOffset(region: .unitedStates, account: "a", patientID: "p"))
        defaults.storeCareLinkDeviceOffset(3600, region: .unitedStates, account: "a", patientID: "p")
        defaults.storeCareLinkDeviceOffset(0, region: .unitedStates, account: "a", patientID: "q")
        defaults.storeCareLinkDeviceOffset(-7200, region: .outsideUnitedStates, account: "a", patientID: "p")
        XCTAssertEqual(defaults.careLinkDeviceOffset(region: .unitedStates, account: "a", patientID: "p"), 3600)
        XCTAssertEqual(defaults.careLinkDeviceOffset(region: .unitedStates, account: "a", patientID: "q"), 0)
        XCTAssertEqual(defaults.careLinkDeviceOffset(region: .outsideUnitedStates, account: "a", patientID: "p"), -7200)
        XCTAssertNil(defaults.careLinkDeviceOffset(region: .unitedStates, account: "b", patientID: "p"))
        XCTAssertNil(defaults.careLinkDeviceOffset(region: .unitedStates, account: nil, patientID: "p"))
        XCTAssertNil(defaults.careLinkDeviceOffset(region: .unitedStates, account: "", patientID: "p"))
        defaults.storeCareLinkDeviceOffset(nil, region: .unitedStates, account: "a", patientID: "p")
        defaults.storeCareLinkDeviceOffset(15 * 3600, region: .unitedStates, account: "a", patientID: "p")
        defaults.storeCareLinkDeviceOffset(.nan, region: .unitedStates, account: "a", patientID: "p")
        defaults.storeCareLinkDeviceOffset(60, region: .unitedStates, account: nil, patientID: "p")
        XCTAssertEqual(defaults.careLinkDeviceOffset(region: .unitedStates, account: "a", patientID: "p"), 3600)
        defaults.storeCareLinkDeviceOffset(-14 * 3600, region: .unitedStates, account: "a", patientID: "p")
        XCTAssertEqual(defaults.careLinkDeviceOffset(region: .unitedStates, account: "a", patientID: "p"), -14 * 3600)
    }

    func testDexcomG7PairingCodesAndSlotsArePerTransmitter() {
        XCTAssertNil(defaults.dexcomG7PairingCode(for: "ABC"))
        defaults.setDexcomG7PairingCode("1234", for: "ABC")
        defaults.setDexcomG7PairingCode("12a4", for: "BAD")
        defaults.setDexcomG7PairingCode("12345", for: "LONG")
        defaults.setDexcomG7PairingCode("9999", for: nil)
        defaults.setDexcomG7PairingCode("9999", for: "")
        XCTAssertEqual(defaults.dexcomG7PairingCode(for: "ABC"), "1234")
        XCTAssertNil(defaults.dexcomG7PairingCode(for: "BAD"))
        XCTAssertNil(defaults.dexcomG7PairingCode(for: "LONG"))
        XCTAssertNil(defaults.dexcomG7PairingCode(for: nil))
        XCTAssertNil(defaults.dexcomG7PairingCode(for: "DEF"))
        XCTAssertEqual(defaults.dexcomG7BluetoothSlot(for: "ABC"), .defaultSlot)
        defaults.setDexcomG7BluetoothSlot(.smartWatch, for: "ABC")
        defaults.setDexcomG7BluetoothSlot(.medicalDevice, for: nil)
        XCTAssertEqual(defaults.dexcomG7BluetoothSlot(for: "ABC"), .smartWatch)
        XCTAssertEqual(defaults.dexcomG7BluetoothSlot(for: nil), .defaultSlot)
        XCTAssertEqual(defaults.dexcomG7BluetoothSlot(for: "DEF"), .defaultSlot)
        defaults.set(999, forKey: UserDefaults.Key.dexcomG7BluetoothSlot.rawValue + "-XYZ")
        XCTAssertEqual(defaults.dexcomG7BluetoothSlot(for: "XYZ"), .defaultSlot)
    }

    func testStoredCollectionsAndDataValues() {
        XCTAssertEqual(defaults.previousRawLibreValues, [])
        defaults.previousRawLibreValues = [1.5, 2.5]
        XCTAssertEqual(defaults.previousRawLibreValues, [1.5, 2.5])
        XCTAssertNil(defaults.previousRawGlucoseValues)
        defaults.previousRawGlucoseValues = [1, 2]
        defaults.previousRawTemperatureValues = [3]
        defaults.previousTemperatureAdjustmentValues = [4]
        XCTAssertEqual(defaults.previousRawGlucoseValues, [1, 2])
        XCTAssertEqual(defaults.previousRawTemperatureValues, [3])
        XCTAssertEqual(defaults.previousTemperatureAdjustmentValues, [4])
        XCTAssertNil(defaults.libreSensorUID)
        defaults.libreSensorUID = Data([1, 2])
        defaults.librePatchInfo = Data([3])
        XCTAssertEqual(defaults.libreSensorUID, Data([1, 2]))
        XCTAssertEqual(defaults.librePatchInfo, Data([3]))
        XCTAssertNil(defaults.nightscoutProfile)
        defaults.nightscoutProfile = Data([9])
        XCTAssertEqual(defaults.nightscoutProfile, Data([9]))
        defaults.nightscoutDeviceStatus = Data([8])
        XCTAssertEqual(defaults.nightscoutDeviceStatus, Data([8]))
        XCTAssertEqual(defaults.lastBasalInjectionInsulinDescription, "")
        defaults.lastBasalInjectionUnits = 12.5
        defaults.lastBasalInjectionInsulinDescription = "Lantus"
        XCTAssertEqual(defaults.lastBasalInjectionUnits, 12.5)
        XCTAssertEqual(defaults.lastBasalInjectionInsulinDescription, "Lantus")
    }

    func testCalendarAliasAndLibreLinkUpVersionDefaults() {
        XCTAssertFalse(defaults.calendarShareAlias.isEmpty)
        defaults.calendarShareAlias = ""
        XCTAssertFalse(defaults.calendarShareAlias.isEmpty)
        defaults.calendarShareAlias = "Kid"
        XCTAssertEqual(defaults.calendarShareAlias, "Kid")
        XCTAssertEqual(defaults.libreLinkUpVersion, ConstantsLibreLinkUp.libreLinkUpVersionDefault)
        defaults.libreLinkUpVersion = "9.9.9"
        XCTAssertEqual(defaults.libreLinkUpVersion, "9.9.9")
        XCTAssertEqual(defaults.careLinkVersion, ConstantsCareLink.carePartnerAppVersionDefault)
    }

    func testLibre1DerivedParametersRoundTripAsJSON() throws {
        XCTAssertNil(defaults.libre1DerivedAlgorithmParameters)
        defaults.set("{not json", forKey: UserDefaults.Key.libre1DerivedAlgorithmParameters.rawValue)
        XCTAssertNil(defaults.libre1DerivedAlgorithmParameters)
    }

    func testDataFlowPolicyCapturesCurrentSettings() {
        defaults.isMaster = false
        defaults.followerDataSourceType = .dexcomShare
        defaults.nightscoutEnabled = true
        defaults.followerUploadDataToNightscout = true
        let policy = defaults.dataFlowPolicy
        XCTAssertFalse(policy.isMaster)
        XCTAssertEqual(policy.followerDataSource, .dexcomShare)
        XCTAssertTrue(policy.nightscoutEnabled)
        XCTAssertTrue(policy.followerUploadsGlucoseToNightscout)
        XCTAssertTrue(policy.masterUploadsGlucoseToNightscout)
    }
}

extension DataCoverageUserDefaultsTests {
    func testDeviceStatusUpdatedFlagDoesNotShareStorageWithSyncRequired() {
        defaults.nightscoutSyncRequired = true
        defaults.nightscoutDeviceStatusWasUpdated = false
        XCTAssertTrue(defaults.nightscoutSyncRequired)
        defaults.nightscoutDeviceStatusWasUpdated = true
        XCTAssertTrue(defaults.bool(forKey: UserDefaults.Key.nightscoutDeviceStatusWasUpdated.rawValue))
        defaults.nightscoutSyncRequired = false
        XCTAssertTrue(defaults.nightscoutDeviceStatusWasUpdated)
    }
}
