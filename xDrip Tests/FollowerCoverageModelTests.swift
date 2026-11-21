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

    func testFollowerDataSourceRawValuesAndListOrder() {
        XCTAssertEqual(FollowerDataSourceType.allCases.map(\.rawValue), Array(0...6))
        XCTAssertEqual(FollowerDataSourceType.allCasesForList, [.nightscout, .dexcomShare, .calendar, .careLink, .libreLinkUp, .libreLinkUpRussia, .medtrumEasyView])
        XCTAssertTrue(FollowerDataSourceType.allEnabledCases.contains(.nightscout))
        XCTAssertTrue(FollowerDataSourceType.nightscout.isEnabled)
    }

    func testFollowerDataSourceTextsAreConsistent() {
        for source in FollowerDataSourceType.allCases {
            XCTAssertFalse(source.description.isEmpty)
            XCTAssertFalse(source.shortDescription.isEmpty)
            XCTAssertFalse(source.abbreviation.isEmpty)
            XCTAssertEqual(source.descriptionForLogging(), source.description + " Follower")
            XCTAssertGreaterThan(source.secondsUntilFollowerDisconnectWarning, 0)
        }
        XCTAssertEqual(FollowerDataSourceType.libreLinkUp.shortDescription, FollowerDataSourceType.libreLinkUpRussia.shortDescription)
        XCTAssertEqual(FollowerDataSourceType.libreLinkUp.abbreviation, "LL")
        XCTAssertEqual(FollowerDataSourceType.careLink.secondsUntilFollowerDisconnectWarning, 20 * 60)
        XCTAssertEqual(FollowerDataSourceType.calendar.secondsUntilFollowerDisconnectWarning, FollowerDataSourceType.nightscout.secondsUntilFollowerDisconnectWarning)
    }

    func testValidatedSelectionFallsBackToFirstEnabledCase() {
        XCTAssertEqual(FollowerDataSourceType.validatedSelection(storedRawValue: 3, enabledCases: [.nightscout, .dexcomShare]), .dexcomShare)
        XCTAssertEqual(FollowerDataSourceType.validatedSelection(storedRawValue: 4, enabledCases: [.dexcomShare, .nightscout]), .dexcomShare)
        XCTAssertEqual(FollowerDataSourceType.validatedSelection(storedRawValue: 99, enabledCases: [.calendar]), .calendar)
        XCTAssertEqual(FollowerDataSourceType.validatedSelection(storedRawValue: nil, enabledCases: []), .nightscout)
    }

    func testOSAidSharingPolicy() {
        XCTAssertEqual(FollowerDataSourceType.medtrumEasyView.osAidSharingPolicy, .requiresExplicitConsent)
        XCTAssertEqual(FollowerDataSourceType.nightscout.osAidSharingPolicy, .allowed)
        XCTAssertTrue(OSAidSharingPolicy.allowed.permitsSharing(hasExplicitConsent: false))
        XCTAssertFalse(OSAidSharingPolicy.requiresExplicitConsent.permitsSharing(hasExplicitConsent: false))
        XCTAssertTrue(OSAidSharingPolicy.requiresExplicitConsent.permitsSharing(hasExplicitConsent: true))
        XCTAssertFalse(OSAidSharingPolicy.blocked.permitsSharing(hasExplicitConsent: true))
    }

    func testKeepAliveTypeRawValuesImagesAndDescriptions() {
        XCTAssertEqual(FollowerBackgroundKeepAliveType.allCases, [.disabled, .normal, .aggressive, .continuous, .heartbeat])
        XCTAssertEqual(FollowerBackgroundKeepAliveType.allCases.map(\.rawValue), [0, 1, 2, 4, 3])
        XCTAssertEqual(FollowerBackgroundKeepAliveType(rawValue: 3), .heartbeat)
        XCTAssertEqual(Set(FollowerBackgroundKeepAliveType.allCases.map(\.keepAliveImageString)).count, 5)
        XCTAssertEqual(Set(FollowerBackgroundKeepAliveType.allCases.map(\.description)).count, 5)
        XCTAssertEqual(FollowerBackgroundKeepAliveType.heartbeat.keepAliveImageString, "heart.circle")
    }

    func testSelectedFollowerActionsNoneIsInert() {
        SelectedFollowerActions.none.refresh()
        SelectedFollowerActions.none.logIn()
        SelectedFollowerActions.none.logOut()
        var calls: [String] = []
        let actions = SelectedFollowerActions(refresh: { calls.append("r") }, logIn: { calls.append("i") }, logOut: { calls.append("o") })
        actions.refresh(); actions.logIn(); actions.logOut()
        XCTAssertEqual(calls, ["r", "i", "o"])
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

    func testLibreLinkUpRegionParsingAndDescriptions() {
        XCTAssertEqual(LibreLinkUpRegion(), .notConfigured)
        let codes = ["ae", "ap", "au", "ca", "de", "eu", "eu2", "fr", "jp", "la", "us"]
        for (index, code) in codes.enumerated() {
            XCTAssertEqual(LibreLinkUpRegion(from: code.uppercased())?.rawValue, index + 1, code)
        }
        XCTAssertEqual(LibreLinkUpRegion(from: "mars"), .notConfigured)
        XCTAssertEqual(Set(LibreLinkUpRegion.allCases.map(\.description)).count, LibreLinkUpRegion.allCases.count)
        XCTAssertEqual(LibreLinkUpRegion.notConfigured.description, "Global")
        for region in LibreLinkUpRegion.allCases {
            XCTAssertEqual(LibreLinkUpRegion.libreLinkUpRegionRawValue(rawValue: region.rawValue), region.rawValue)
        }
    }

    func testLibreLinkUpRegionURLsForGlobalRegionalAndRussianSources() {
        let key = UserDefaults.Key.followerDataSourceType.rawValue
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.followerDataSourceType = .nightscout
        XCTAssertEqual(LibreLinkUpRegion.notConfigured.urlLogin, "https://api.libreview.io/llu/auth/login")
        XCTAssertEqual(LibreLinkUpRegion.eu.urlLogin, "https://api-eu.libreview.io/llu/auth/login")
        XCTAssertEqual(LibreLinkUpRegion.notConfigured.urlConnections, "https://api.libreview.io/llu/connections")
        XCTAssertEqual(LibreLinkUpRegion.us.urlConnections, "https://api-us.libreview.io/llu/connections")
        XCTAssertEqual(LibreLinkUpRegion.notConfigured.urlGraph(patientId: "p"), "https://api.libreview.io/llu/connections/p/graph")
        XCTAssertEqual(LibreLinkUpRegion.eu2.urlGraph(patientId: "p"), "https://api-eu2.libreview.io/llu/connections/p/graph")

        UserDefaults.standard.followerDataSourceType = .libreLinkUpRussia
        XCTAssertEqual(LibreLinkUpRegion.eu.urlLogin, "https://api.libreview.ru/llu/auth/login")
        XCTAssertEqual(LibreLinkUpRegion.eu.urlConnections, "https://api.libreview.ru/llu/connections")
        XCTAssertEqual(LibreLinkUpRegion.eu.urlGraph(patientId: "p"), "https://api.libreview.ru/llu/connections/p/graph")
    }

    func testLibreLinkUpResponsesDecode() throws {
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yyyy h:mm:ss a"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        decoder.dateDecodingStrategy = .formatted(formatter)

        let login = try decoder.decode(Response<RequestLoginResponse>.self, from: Data(#"{"status":0,"data":{"user":{"id":"u1","country":"BE"},"authTicket":{"token":"t","expires":1700000000}}}"#.utf8))
        XCTAssertEqual(login.data?.user?.id, "u1")
        XCTAssertEqual(login.data?.authTicket?.expires, 1_700_000_000)
        XCTAssertNil(login.data?.redirect)

        let redirect = try decoder.decode(Response<RequestLoginResponse>.self, from: Data(#"{"status":0,"data":{"redirect":true,"region":"eu"}}"#.utf8))
        XCTAssertEqual(redirect.data?.redirect, true)
        XCTAssertEqual(redirect.data?.region, "eu")

        let graph = try decoder.decode(Response<RequestGraphResponse>.self, from: Data("""
        {"status":0,"data":{"connection":{"glucoseMeasurement":{"FactoryTimestamp":"1/2/2026 3:04:05 PM","ValueInMgPerDl":101},"sensor":{"sn":"MH123","a":1700000000}},
        "activeSensors":[{"sensor":{"sn":"0DXYZ","a":1700000100}}],"graphData":[{"FactoryTimestamp":"1/2/2026 2:59:05 PM","ValueInMgPerDl":99}]}}
        """.utf8))
        XCTAssertEqual(graph.data?.connection?.glucoseMeasurement?.ValueInMgPerDl, 101)
        XCTAssertEqual(graph.data?.connection?.glucoseMeasurement?.FactoryTimestamp, ISO8601DateFormatter.withoutFractionalSeconds.date(from: "2026-01-02T15:04:05Z"))
        XCTAssertEqual(graph.data?.activeSensors?.first?.sensor?.sn, "0DXYZ")
        XCTAssertEqual(graph.data?.graphData?.count, 1)

        let invalidCredentials = try decoder.decode(Response<RequestLoginResponse>.self, from: Data(#"{"status":2}"#.utf8))
        XCTAssertEqual(invalidCredentials.status, 2)
        XCTAssertNil(invalidCredentials.data)
        XCTAssertThrowsError(try decoder.decode(Response<RequestLoginResponse>.self, from: Data(#"{"data":{}}"#.utf8)))
    }

    // MARK: - Dexcom Share models

    func testDexcomShareRegionMetadata() {
        XCTAssertEqual(DexcomShareRegion.allCases.map(\.regionServerNumber), ["", "1", "2", "3"])
        XCTAssertEqual(DexcomShareRegion.allCases.map(\.description), ["None", "US", "Global", "Japan"])
        XCTAssertEqual(DexcomShareRegion.none.regionCountriesDescription, "")
        XCTAssertTrue(DexcomShareRegion.global.regionCountriesDescription.contains("Europe"))
        XCTAssertEqual(DexcomShareRegion.us.baseURL.absoluteString, ConstantsDexcomShare.usBaseShareUrl)
        XCTAssertEqual(DexcomShareRegion.jp.baseURL.absoluteString, ConstantsDexcomShare.japanBaseShareUrl)
        XCTAssertEqual(DexcomShareRegion.global.baseURL.absoluteString, ConstantsDexcomShare.globalBaseShareUrl)
        XCTAssertEqual(DexcomShareRegion.jp.applicationID, ConstantsDexcomShare.applicationIdJapan)
        XCTAssertEqual(DexcomShareRegion.us.applicationID, ConstantsDexcomShare.applicationId)
        XCTAssertEqual(try JSONDecoder().decode(DexcomShareRegion.self, from: Data("3".utf8)), .jp)
    }

    func testDexcomShareModelsCode() throws {
        let login = DexcomShareLoginRequest(accountName: "a", applicationId: "b", password: "c")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(login)) as? [String: String]
        XCTAssertEqual(json, ["accountName": "a", "applicationId": "b", "password": "c"])
        let egv = try JSONDecoder().decode([DexcomEGV].self, from: Data(#"[{"DT":"/Date(1)/","ST":"/Date(2)/","WT":"Date(3)","Value":120,"Trend":"Flat"}]"#.utf8))
        XCTAssertEqual(egv.first?.Value, 120)
        XCTAssertEqual(egv.first?.WT, "Date(3)")
    }
}
