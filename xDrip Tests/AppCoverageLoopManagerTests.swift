//
//  AppCoverageLoopManagerTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

final class AppCoverageLoopManagerTests: XCTestCase {
    private var now: Date!

    override func setUp() {
        super.setUp()
        appCoverageIsolateDefaults()
        now = Date()
        let defaults = UserDefaults.standard
        defaults.isMaster = false
        defaults.followerDataSourceType = .nightscout
        defaults.activeSensorStartDate = nil
        defaults.activeSensorDescription = nil
        defaults.activeSensorSerialNumber = nil
        defaults.activeSensorMaxSensorAgeInDays = 0
        defaults.transmitterBatteryInfo = nil
        defaults.loopDelaySchedule = nil
        defaults.loopDelayValueInMinutes = nil
        defaults.loopShareSmoothedData = false
    }

    private func context(sensor: Sensor? = nil, issue: SensorHealthIssue? = nil, dexcom: DexcomAlgorithmState? = nil, libre: LibreSensorState? = nil) -> XDripCGMMetadataContext {
        XDripCGMMetadataContext(activeSensor: sensor, transmitter: nil, sensorHealthIssue: issue, hasInitialCalibration: nil, lastCalibrationAt: nil, dexcomAlgorithmState: dexcom, libreSensorState: libre)
    }

    private func build(_ context: XDripCGMMetadataContext, glucoseAt: Date? = nil, override: String? = nil) -> XDripCGMMetadataEnvelope {
        XDripCGMMetadataBuilder.build(context: context, latestSharedGlucoseAt: glucoseAt, lastCommunicationAt: now.addingTimeInterval(-30), sensorStateOverride: override, now: now)
    }

    private func issue(_ reason: SensorHealthReason, severity: SensorHealthSeverity = .caution) -> SensorHealthIssue {
        SensorHealthIssue(id: "i", kind: .persistentNoise, severity: severity, source: .calculatedNoise, reason: reason, firstSeen: now, sensorSessionID: "s", destination: .sensorManagement)
    }

    private func startSensor(daysAgo: Double, maxDays: Double = 10, description: String? = nil) {
        UserDefaults.standard.activeSensorStartDate = now.addingTimeInterval(-daysAgo * 86_400)
        UserDefaults.standard.activeSensorMaxSensorAgeInDays = maxDays
        UserDefaults.standard.activeSensorDescription = description
    }

    // MARK: - Metadata envelope

    func testFollowerEnvelopeDescribesSourceAndProducer() throws {
        let envelope = build(context())
        XCTAssertEqual(envelope.schemaVersion, XDripCGMMetadataEnvelope.schemaVersion)
        XCTAssertEqual(envelope.generatedAt, now.timeIntervalSince1970)
        XCTAssertNotNil(envelope.producer?.appName)
        XCTAssertEqual(envelope.source?.mode, "follower")
        XCTAssertEqual(envelope.source?.kind, "nightscout")
        XCTAssertEqual(envelope.source?.expectedReadingIntervalSeconds, 300)
        XCTAssertEqual(try XCTUnwrap(envelope.source?.lastCommunicationAt), now.timeIntervalSince1970 - 30, accuracy: 0.001)
        XCTAssertNil(envelope.sensor, "Nothing is known about a follower sensor")
        XCTAssertNil(envelope.latestData)
        XCTAssertNil(envelope.transmitter)
        XCTAssertNil(envelope.calibration)
    }

    func testFollowerSourceKindsAndIntervals() {
        let expected: [(FollowerDataSourceType, String, Double)] = [
            (.nightscout, "nightscout", 300), (.libreLinkUp, "libre_link_up", 60), (.libreLinkUpRussia, "libre_link_up_russia", 60),
            (.dexcomShare, "dexcom_share", 300), (.medtrumEasyView, "medtrum_easyview", 60), (.calendar, "shared_calendar", 300), (.careLink, "carelink", 300)
        ]
        for (type, kind, interval) in expected {
            UserDefaults.standard.followerDataSourceType = type
            let source = build(context()).source
            XCTAssertEqual(source?.kind, kind)
            XCTAssertEqual(source?.expectedReadingIntervalSeconds, interval)
        }
    }

    func testMasterWithoutTransmitterReportsNotStarted() {
        UserDefaults.standard.isMaster = true
        let envelope = build(context())
        XCTAssertEqual(envelope.source?.mode, "direct")
        XCTAssertNil(envelope.source?.kind)
        XCTAssertNil(envelope.source?.expectedReadingIntervalSeconds)
        XCTAssertEqual(envelope.sensor?.state, "not_started")
    }

    func testSensorLifecycleStates() {
        startSensor(daysAgo: 10.0 / 1440)
        XCTAssertEqual(build(context()).sensor?.state, "warmup")
        startSensor(daysAgo: 2)
        XCTAssertEqual(build(context()).sensor?.state, "active")
        startSensor(daysAgo: 11)
        XCTAssertEqual(build(context()).sensor?.state, "expired")
        startSensor(daysAgo: 11, maxDays: 0)
        let unlimited = build(context()).sensor
        XCTAssertEqual(unlimited?.state, "active")
        XCTAssertNil(unlimited?.expiresAt)
    }

    func testSensorDatesAreDerivedFromStartAndMaximumAge() throws {
        startSensor(daysAgo: 2, maxDays: 10)
        let sensor = try XCTUnwrap(build(context()).sensor)
        let start = now.addingTimeInterval(-2 * 86_400).timeIntervalSince1970
        XCTAssertEqual(try XCTUnwrap(sensor.startedAt), start, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sensor.expiresAt), start + 10 * 86_400, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sensor.warmupEndsAt), start + ConstantsMaster.minimumSensorWarmUpRequiredInMinutes * 60, accuracy: 0.001)
        XCTAssertNil(sensor.graceEndsAt)
    }

    func testWarmupDurationFollowsSourceAndDescription() throws {
        startSensor(daysAgo: 1, description: "Dexcom G6")
        let dexcom = try XCTUnwrap(build(context()).sensor)
        XCTAssertEqual(try XCTUnwrap(dexcom.warmupEndsAt) - (try XCTUnwrap(dexcom.startedAt)), ConstantsMaster.minimumSensorWarmUpRequiredInMinutesDexcomG5G6 * 60, accuracy: 0.001)
        XCTAssertEqual(dexcom.type, "dexcom")
        UserDefaults.standard.followerDataSourceType = .libreLinkUp
        // start the sensor again for the new source
        startSensor(daysAgo: 1, description: "Dexcom G6")
        let libre = try XCTUnwrap(build(context()).sensor)
        XCTAssertEqual(try XCTUnwrap(libre.warmupEndsAt) - (try XCTUnwrap(libre.startedAt)), ConstantsLibreLinkUp.sensorWarmUpRequiredInMinutesForLibre * 60, accuracy: 0.001)
    }

    func testSensorTypeIsInferredFromDescription() {
        for (description, type) in [("Guardian 4", "guardian"), ("Dexcom G7", "dexcom"), ("FreeStyle Libre 3", "libre"), ("Medtrum Nano", "medtrum"), ("Unknown", nil)] as [(String, String?)] {
            startSensor(daysAgo: 1, description: description)
            XCTAssertEqual(build(context()).sensor?.type, type, description)
            XCTAssertEqual(build(context()).sensor?.model, description)
        }
    }

    func testSessionIdentifierPrefersSensorIDAndOtherwiseCombinesDefaults() throws {
        startSensor(daysAgo: 1, description: "Libre")
        UserDefaults.standard.activeSensorSerialNumber = "ABC123"
        let start = try XCTUnwrap(UserDefaults.standard.activeSensorStartDate)
        let fromDefaults = build(context()).sensor
        XCTAssertEqual(fromDefaults?.sessionIdentifier, "ABC123|Libre|\(Int(start.timeIntervalSince1970))")
        XCTAssertEqual(fromDefaults?.serialNumber, "ABC123")
        let core = AppCoverageFactory.coreData()
        let sensor = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: core.mainManagedObjectContext)
        let fromSensor = build(context(sensor: sensor)).sensor
        XCTAssertEqual(fromSensor?.sessionIdentifier, sensor.id)
        XCTAssertEqual(try XCTUnwrap(fromSensor?.startedAt), sensor.startDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testOverridesAndTerminalFailuresWinOverDates() {
        startSensor(daysAgo: 2)
        XCTAssertEqual(build(context(), override: "stopped").sensor?.state, "stopped")
        XCTAssertEqual(build(context(issue: issue(.dexcomSensorFailure, severity: .terminal)), override: "stopped").sensor?.state, "failed")
    }

    func testDexcomAndLibreStatesMapToSensorStates() {
        startSensor(daysAgo: 2)
        let dexcom: [(DexcomAlgorithmState, String)] = [(.SessionStopped, "stopped"), (.SensorWarmup, "warmup"), (.SessionExpired, "expired"), (.sensorFailed, "failed"), (.SensorFailedDueToRestart, "failed")]
        for (state, expected) in dexcom {
            XCTAssertEqual(build(context(dexcom: state)).sensor?.state, expected, "\(state)")
        }
        let libre: [(LibreSensorState, String)] = [(.notYetStarted, "not_started"), (.starting, "warmup"), (.expired, "expired"), (.shutdown, "stopped"), (.failure, "failed"), (.ready, "active"), (.unknown, "active")]
        for (state, expected) in libre {
            XCTAssertEqual(build(context(libre: state)).sensor?.state, expected, "\(state)")
        }
    }

    func testQualityCodes() {
        XCTAssertNil(build(context()).latestData)
        XCTAssertEqual(build(context(), glucoseAt: now).latestData?.qualityCode, "reliable")
        XCTAssertEqual(build(context(), glucoseAt: now).latestData?.glucoseAt, now.timeIntervalSince1970)
        let reasons: [(SensorHealthReason, String)] = [(.persistentNoise, "persistent_noise"), (.flatline, "flatline"), (.dexcomExcessNoise, "excess_noise"), (.dexcomQuestionMarks, "temporary_sensor_issue"), (.libreTemporarySensorIssue, "temporary_sensor_issue"), (.libreSensorFailure, "sensor_error"), (.dexcomTransmitterBatteryFailure, "sensor_error")]
        for (reason, code) in reasons {
            XCTAssertEqual(build(context(issue: issue(reason))).latestData?.qualityCode, code)
        }
        XCTAssertEqual(build(context(dexcom: .excessNoise)).latestData?.qualityCode, "excess_noise")
        XCTAssertEqual(build(context(dexcom: .questionMarks)).latestData?.qualityCode, "temporary_sensor_issue")
        XCTAssertEqual(build(context(dexcom: .SensorFailedDuetoCountsAberration)).latestData?.qualityCode, "sensor_error")
    }

    func testEnvelopeRoundTripsThroughJSON() throws {
        startSensor(daysAgo: 2, description: "Dexcom G7")
        let envelope = build(context(), glucoseAt: now)
        let decoded = try JSONDecoder().decode(XDripCGMMetadataEnvelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertEqual(decoded, envelope)
    }

    // MARK: - Loop delay

    func testLoopDelayIsZeroWithoutAValidSchedule() {
        XCTAssertEqual(LoopManager.loopDelay(), 0)
        UserDefaults.standard.loopDelaySchedule = "0-720"
        XCTAssertEqual(LoopManager.loopDelay(), 0)
        UserDefaults.standard.loopDelayValueInMinutes = "5"
        XCTAssertEqual(LoopManager.loopDelay(), 0, "Schedule and values must have the same length")
    }

    func testLoopDelayUsesValueForCurrentTimeOfDay() throws {
        UserDefaults.standard.loopDelaySchedule = "0"
        UserDefaults.standard.loopDelayValueInMinutes = "7"
        XCTAssertEqual(LoopManager.loopDelay(), 7 * 60)
        UserDefaults.standard.loopDelaySchedule = "0-720"
        UserDefaults.standard.loopDelayValueInMinutes = "5-10"
        // loopDelay() reads the clock itself; skip the rare run that crosses 12:00 while it does
        let before = Date().minutesSinceMidNightLocalTime()
        let delay = LoopManager.loopDelay()
        let after = Date().minutesSinceMidNightLocalTime()
        try XCTSkipIf((before < 720) != (after < 720), "crossed 12:00 during the check")
        XCTAssertEqual(delay, before < 720 ? 300 : 600)
    }

    // MARK: - Sharing

    func testLegacyEncodingKeepsTopLevelArray() throws {
        let data = try LoopManager.encodeLegacyReadings([["Value": 120.0], ["Value": 110.0]])
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array.first?["Value"] as? Double, 120)
        XCTAssertEqual(String(data: try LoopManager.encodeLegacyReadings([]), encoding: .utf8), "[]")
    }

    func testReadingShareValueUsesAdjustedValueUnlessSmoothedSharingIsEnabled() {
        let core = AppCoverageFactory.coreData()
        let reading = AppCoverageFactory.reading(120, at: now, in: core)
        XCTAssertEqual(reading.loopShareValue, 120)
        reading.adjustedValue = 125
        reading.smoothedValue = 130
        XCTAssertEqual(reading.loopShareValue, 125)
        UserDefaults.standard.loopShareType = .loop
        UserDefaults.standard.enableSmoothing = false
        UserDefaults.standard.loopShareSmoothedData = true
        XCTAssertEqual(reading.loopShareValue, 125, "Smoothed sharing requires smoothing to be enabled")
        UserDefaults.standard.enableSmoothing = true
        UserDefaults.standard.loopShareSmoothedData = true
        XCTAssertEqual(reading.loopShareValue, 130)
        UserDefaults.standard.loopShareType = .disabled
        XCTAssertEqual(reading.loopShareValue, 125)
    }

    func testLoopShareTypeSuiteNames() {
        XCTAssertEqual(LoopShareType.disabled.sharedUserDefaultsSuiteName, "")
        XCTAssertEqual(LoopShareType.loop.sharedUserDefaultsSuiteName, Bundle.main.appGroupSuiteName)
        XCTAssertEqual(LoopShareType.trio.sharedUserDefaultsSuiteName, Bundle.main.appGroupSuiteNameTrio)
        for type in LoopShareType.allCases { XCTAssertFalse(type.description.isEmpty) }
    }

    private func withSharedSuite(_ type: LoopShareType, _ body: (UserDefaults) throws -> Void) throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: type.sharedUserDefaultsSuiteName))
        let keys = ["latestReadings", XDripCGMMetadataEnvelope.appGroupKey]
        let previous = keys.map { ($0, suite.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { suite.set(value, forKey: key) } else { suite.removeObject(forKey: key) }
            }
        }
        suite.removeObject(forKey: "latestReadings")
        try body(suite)
    }

    private func loopManager(_ core: CoreDataManager) -> LoopManager {
        LoopManager(coreDataManager: core, activeSensorIsAnubisProvider: { false }, metadataContextProvider: { [unowned self] in self.context() })
    }

    func testShareWritesLatestReadingsForLoop() throws {
        let defaults = UserDefaults.standard
        defaults.loopShareType = .loop
        defaults.followerDataSourceType = .nightscout
        try withSharedSuite(.loop) { suite in
            let core = AppCoverageFactory.coreData()
            let manager = loopManager(core)
            defaults.timeStampLatestLoopSharedBgReading = nil
            manager.share()
            XCTAssertNotNil(defaults.timeStampLatestLoopSharedBgReading, "The first run only records the starting point")
            XCTAssertNil(suite.data(forKey: "latestReadings"))
            defaults.timeStampLatestLoopSharedBgReading = now.addingTimeInterval(-600)
            let reading = AppCoverageFactory.reading(120.4, at: now.addingTimeInterval(-60), in: core)
            AppCoverageFactory.reading(115, at: now.addingTimeInterval(-360), in: core)
            manager.share()
            let data = try XCTUnwrap(suite.data(forKey: "latestReadings"))
            let shared = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            XCTAssertEqual(shared.count, 2)
            XCTAssertEqual(shared.first?["Value"] as? Double, 120)
            XCTAssertEqual(shared.first?["from"] as? String, "xDrip")
            XCTAssertEqual(shared.first?["direction"] as? String, reading.slopeName)
            XCTAssertEqual(defaults.readingsStoredInSharedUserDefaultsAsDictionary?.count, 2)
            XCTAssertEqual(try XCTUnwrap(defaults.timeStampLatestLoopSharedBgReading).timeIntervalSince(reading.timeStamp), 5, accuracy: 0.001)
            manager.clearSharedLoopReadings()
            XCTAssertNil(suite.data(forKey: "latestReadings"))
            XCTAssertNil(defaults.readingsStoredInSharedUserDefaultsAsDictionary)
        }
    }

    func testShareDoesNothingWhenDisabled() throws {
        UserDefaults.standard.loopShareType = .disabled
        try withSharedSuite(.loop) { suite in
            let core = AppCoverageFactory.coreData()
            AppCoverageFactory.reading(120, at: now, in: core)
            UserDefaults.standard.timeStampLatestLoopSharedBgReading = now.addingTimeInterval(-600)
            loopManager(core).share()
            XCTAssertNil(suite.data(forKey: "latestReadings"))
        }
    }

    func testDelayedShareShiftsOlderGlucoseDataAndDropsTooRecentValues() throws {
        let defaults = UserDefaults.standard
        defaults.loopShareType = .loop
        defaults.loopDelaySchedule = "0"
        defaults.loopDelayValueInMinutes = "5"
        try withSharedSuite(.loop) { suite in
            let core = AppCoverageFactory.coreData()
            AppCoverageFactory.reading(120, at: now.addingTimeInterval(-60), in: core)
            defaults.timeStampLatestLoopSharedBgReading = now.addingTimeInterval(-3600)
            let manager = loopManager(core)
            manager.glucoseData = [
                GlucoseData(timeStamp: now.addingTimeInterval(-120), glucoseLevelRaw: 130),
                GlucoseData(timeStamp: now.addingTimeInterval(-600), glucoseLevelRaw: 110.4)
            ]
            manager.share()
            XCTAssertEqual(manager.glucoseData.count, 1, "Values younger than the delay are removed")
            let shared = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(suite.data(forKey: "latestReadings"))) as? [[String: Any]])
            XCTAssertEqual(shared.count, 1)
            XCTAssertEqual(shared.first?["Value"] as? Double, 110)
            let shiftedDate = try XCTUnwrap(defaults.timeStampLatestLoopSharedBgReading)
            XCTAssertEqual(shiftedDate.timeIntervalSince(now.addingTimeInterval(-300)), 0, accuracy: 1)
        }
    }

    func testDelayedShareWithOnlyRecentDataLeavesPreviousReadings() throws {
        let defaults = UserDefaults.standard
        defaults.loopShareType = .loop
        defaults.loopDelaySchedule = "0"
        defaults.loopDelayValueInMinutes = "10"
        try withSharedSuite(.loop) { suite in
            let core = AppCoverageFactory.coreData()
            defaults.timeStampLatestLoopSharedBgReading = now.addingTimeInterval(-3600)
            let manager = loopManager(core)
            manager.glucoseData = [GlucoseData(timeStamp: now.addingTimeInterval(-60), glucoseLevelRaw: 130)]
            suite.set(Data("previous".utf8), forKey: "latestReadings")
            manager.share()
            XCTAssertTrue(manager.glucoseData.isEmpty)
            XCTAssertEqual(suite.data(forKey: "latestReadings"), Data("previous".utf8))
        }
    }

    func testTrioMetadataReflectsExplicitSensorState() throws {
        let defaults = UserDefaults.standard
        defaults.loopShareType = .trio
        defaults.isMaster = true
        defaults.cgmTransmitterTypeAsString = CGMTransmitterType.dexcom.rawValue
        try withSharedSuite(.trio) { suite in
            let manager = loopManager(AppCoverageFactory.coreData())
            manager.shareMetadata(lastCommunicationAt: now, clearReadings: true, sensorState: "not_started")
            let data = try XCTUnwrap(suite.data(forKey: XDripCGMMetadataEnvelope.appGroupKey))
            let envelope = try JSONDecoder().decode(XDripCGMMetadataEnvelope.self, from: data)
            XCTAssertEqual(envelope.sensor?.state, "not_started")
            XCTAssertEqual(envelope.source?.mode, "direct")
            XCTAssertEqual(String(data: try XCTUnwrap(suite.data(forKey: "latestReadings")), encoding: .utf8), "[]")
            manager.shareMetadata(clearSensorState: true)
            let cleared = try JSONDecoder().decode(XDripCGMMetadataEnvelope.self, from: XCTUnwrap(suite.data(forKey: XDripCGMMetadataEnvelope.appGroupKey)))
            XCTAssertEqual(cleared.sensor?.state, "not_started", "Without a start date a direct source is still not started")
        }
    }
}
