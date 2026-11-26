//
//  FollowerCoverageModelTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

final class FollowerCoverageModelTests: XCTestCase {
    private func policy(
        isMaster: Bool = false,
        source: FollowerDataSourceType = .nightscout,
        therapy: TherapyDataSourceType = .automatic,
        nightscoutEnabled: Bool = true,
        masterUploads: Bool = true,
        followerUploads: Bool = true,
        followType: NightscoutFollowType = .loop
    ) -> DataFlowPolicy {
        DataFlowPolicy(
            isMaster: isMaster,
            followerDataSource: source,
            therapyDataSourceSelection: therapy,
            nightscoutEnabled: nightscoutEnabled,
            masterUploadsGlucoseToNightscout: masterUploads,
            followerUploadsGlucoseToNightscout: followerUploads,
            nightscoutFollowType: followType
        )
    }

    // MARK: - Follower data source type

    func testKeepAliveTypeRawValuesImagesAndDescriptions() {
        XCTAssertEqual(FollowerBackgroundKeepAliveType.allCases, [.disabled, .normal, .aggressive, .continuous, .heartbeat])
        XCTAssertEqual(FollowerBackgroundKeepAliveType.allCases.map(\.rawValue), [0, 1, 2, 4, 3])
        XCTAssertEqual(FollowerBackgroundKeepAliveType(rawValue: 3), .heartbeat)
        XCTAssertEqual(Set(FollowerBackgroundKeepAliveType.allCases.map(\.keepAliveImageString)).count, 5)
        XCTAssertEqual(Set(FollowerBackgroundKeepAliveType.allCases.map(\.description)).count, 5)
        XCTAssertEqual(FollowerBackgroundKeepAliveType.heartbeat.keepAliveImageString, "heart.circle")
    }

    // MARK: - Session state

    func testSessionStateDefaultsToLoggedOutAndUpdatesOnMainThread() {
        let state = FollowerSessionState()
        XCTAssertEqual(state.status(for: .dexcomShare), .loggedOut)
        state.update(.loggingIn, for: .dexcomShare)
        XCTAssertEqual(state.status(for: .dexcomShare), .loggingIn)
        XCTAssertEqual(state.status(for: .libreLinkUp), .loggedOut)

        let updated = expectation(description: "background update applied")
        DispatchQueue.global().async {
            state.update(.loggedIn, for: .libreLinkUp)
            DispatchQueue.main.async { updated.fulfill() }
        }
        wait(for: [updated], timeout: 2)
        XCTAssertEqual(state.status(for: .libreLinkUp), .loggedIn)
    }

    func testSessionStateDoesNotRepublishUnchangedStatus() {
        let state = FollowerSessionState()
        var publishCount = 0
        let cancellable = state.objectWillChange.sink { publishCount += 1 }
        state.update(.loggedIn, for: .nightscout)
        state.update(.loggedIn, for: .nightscout)
        state.update(.loggedOut, for: .nightscout)
        XCTAssertEqual(publishCount, 2)
        cancellable.cancel()
    }

    func testFollowerManualLogoutFlagsAreSourceSpecific() {
        let suite = "FollowerCoverageModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.libreLinkUpManuallyLoggedOut = true
        defaults.dexcomShareManuallyLoggedOut = false
        defaults.medtrumEasyViewManuallyLoggedOut = true
        XCTAssertTrue(defaults.followerWasManuallyLoggedOut(.libreLinkUp))
        XCTAssertTrue(defaults.followerWasManuallyLoggedOut(.libreLinkUpRussia))
        XCTAssertFalse(defaults.followerWasManuallyLoggedOut(.dexcomShare))
        XCTAssertTrue(defaults.followerWasManuallyLoggedOut(.medtrumEasyView))
        XCTAssertFalse(defaults.followerWasManuallyLoggedOut(.nightscout))
        XCTAssertFalse(defaults.followerWasManuallyLoggedOut(.calendar))
        XCTAssertFalse(defaults.followerWasManuallyLoggedOut(.careLink))
    }

    // MARK: - Data flow policy

    func testMasterExportDependsOnMasterUploadSetting() {
        XCTAssertTrue(policy(isMaster: true, masterUploads: true).exportsGlucoseToNightscout)
        XCTAssertFalse(policy(isMaster: true, masterUploads: false).exportsGlucoseToNightscout)
        XCTAssertFalse(policy(isMaster: true, nightscoutEnabled: false).exportsGlucoseToNightscout)
        XCTAssertFalse(policy(isMaster: true).importsGlucoseFromNightscout)
    }

    func testNightscoutStatusImportRequiresFollowType() {
        XCTAssertTrue(policy(followType: .openAPS).importsStatusFromNightscout)
        XCTAssertFalse(policy(followType: .none).importsStatusFromNightscout)
        XCTAssertTrue(policy(followType: .none).importsTreatmentsFromNightscout)
        XCTAssertEqual(policy(followType: .openAPS).aidAnalyticsSource, .nightscout(.openAPS))
        XCTAssertNil(policy(followType: .none).aidAnalyticsSource)
        XCTAssertFalse(policy(followType: .none).supportsAIDEnhancedAnalytics)
        XCTAssertTrue(policy(followType: .loop).showsTherapyStatus)
        XCTAssertTrue(policy(nightscoutEnabled: false).availableTherapyDataSources == [.automatic, .none])
        XCTAssertFalse(policy(nightscoutEnabled: false).exportsTreatmentsToNightscout)
    }

    func testExplicitCareLinkTherapyFallsBackOutsideCareLinkFollower() {
        XCTAssertEqual(policy(source: .careLink, therapy: .careLink).therapyDataSource, .careLink)
        XCTAssertEqual(policy(source: .dexcomShare, therapy: .careLink).therapyDataSource, .nightscout)
        XCTAssertEqual(policy(source: .dexcomShare, therapy: .careLink, nightscoutEnabled: false).therapyDataSource, .none)
        XCTAssertEqual(policy(source: .careLink).availableTherapyDataSources, [.automatic, .nightscout, .careLink, .none])
        XCTAssertTrue(policy(source: .careLink, therapy: .careLink).showsPumpData)
        XCTAssertFalse(policy(source: .careLink, therapy: .careLink).showsAIDData)
    }

    func testAIDAnalyticsSourceCapabilitiesAndOwnership() {
        let nightscout = AIDAnalyticsSource.nightscout(.loop)
        XCTAssertTrue(nightscout.supportsCOB)
        XCTAssertTrue(nightscout.supportsScheduledBasalAnalytics)
        XCTAssertFalse(AIDAnalyticsSource.careLink.supportsCOB)
        XCTAssertFalse(AIDAnalyticsSource.careLink.supportsScheduledBasalAnalytics)
        XCTAssertTrue(nightscout.ownsDeviceStatus(with: nil))
        XCTAssertTrue(nightscout.ownsDeviceStatus(with: "loop://phone"))
        XCTAssertFalse(nightscout.ownsDeviceStatus(with: "carelink://pump"))
        XCTAssertTrue(AIDAnalyticsSource.careLink.ownsDeviceStatus(with: "carelink://pump"))
        XCTAssertFalse(AIDAnalyticsSource.careLink.ownsDeviceStatus(with: nil))
        XCTAssertEqual(Set(TherapyDataSourceType.allCases.map(\.description)).count, 4)
    }

    // MARK: - LibreLinkUp models

    // MARK: - Dexcom Share models

}
