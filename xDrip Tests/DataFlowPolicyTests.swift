//
//  DataFlowPolicyTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the cross-service data-flow rules resolved by `DataFlowPolicy`.
///
/// The policy is the single place that decides which service owns glucose, treatments and AID
/// status. A wrong answer either creates an upload loop (a Nightscout follower writing the readings
/// it just downloaded back to Nightscout), mixes two patients (CareLink pump data shown next to
/// glucose from another source) or imports treatments twice. Besides scenario tests, every
/// combination of inputs is checked against the invariants the managers rely on.
final class DataFlowPolicyTests: XCTestCase {

    // MARK: - helpers

    /// Builds a policy with the most common follower configuration as defaults, so each test only
    /// spells out the inputs it is about.
    private func policy(
        isMaster: Bool = false,
        source: FollowerDataSourceType = .nightscout,
        therapy: TherapyDataSourceType = .automatic,
        nightscoutEnabled: Bool = true,
        masterUploads: Bool = false,
        followerUploads: Bool = false,
        followType: NightscoutFollowType = .none
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

    /// Every possible input combination (2 * 7 * 4 * 2 * 2 * 2 * 3 = 1344 policies).
    private var allPolicies: [DataFlowPolicy] {
        var result: [DataFlowPolicy] = []
        for isMaster in [false, true] {
            for source in FollowerDataSourceType.allCases {
                for therapy in TherapyDataSourceType.allCases {
                    for nightscoutEnabled in [false, true] {
                        for masterUploads in [false, true] {
                            for followerUploads in [false, true] {
                                for followType in NightscoutFollowType.allCases {
                                    result.append(policy(
                                        isMaster: isMaster,
                                        source: source,
                                        therapy: therapy,
                                        nightscoutEnabled: nightscoutEnabled,
                                        masterUploads: masterUploads,
                                        followerUploads: followerUploads,
                                        followType: followType
                                    ))
                                }
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    // MARK: - invariants over every combination

    func testEveryCombinationIsCovered() {
        XCTAssertEqual(allPolicies.count, 2 * FollowerDataSourceType.allCases.count * TherapyDataSourceType.allCases.count * 2 * 2 * 2 * NightscoutFollowType.allCases.count)
    }

    /// The resolved source must always be one the settings picker can show, otherwise the picker
    /// would show no checkmark while imports run for a hidden source.
    func testResolvedTherapySourceIsAlwaysAnAvailableChoice() {
        for policy in allPolicies {
            XCTAssertTrue(policy.availableTherapyDataSources.contains(policy.therapyDataSource), "\(policy)")
            XCTAssertNotEqual(policy.therapyDataSource, .automatic, "Automatic must always resolve to a concrete source: \(policy)")
            XCTAssertEqual(policy.availableTherapyDataSources.first, .automatic)
            XCTAssertEqual(policy.availableTherapyDataSources.last, TherapyDataSourceType.none)
            XCTAssertEqual(Set(policy.availableTherapyDataSources).count, policy.availableTherapyDataSources.count, "no duplicates: \(policy)")
        }
    }

    /// Downloading glucose from Nightscout and uploading glucose to Nightscout at the same time
    /// would write every downloaded reading back to the same site.
    func testGlucoseIsNeverImportedAndExportedThroughNightscoutAtTheSameTime() {
        for policy in allPolicies {
            XCTAssertFalse(policy.importsGlucoseFromNightscout && policy.exportsGlucoseToNightscout, "\(policy)")
        }
    }

    /// Only one remote service may own therapy imports, otherwise treatments are duplicated.
    func testTherapyIsImportedFromAtMostOneService() {
        for policy in allPolicies {
            XCTAssertFalse(policy.importsTherapyFromCareLink && policy.importsTreatmentsFromNightscout, "\(policy)")
            XCTAssertFalse(policy.importsTherapyFromCareLink && policy.importsStatusFromNightscout, "\(policy)")
        }
    }

    /// CareLink pump data refers to the patient whose CareLink glucose is followed, so it can never be
    /// used in master mode or with another glucose source.
    func testCareLinkTherapyRequiresCareLinkFollower() {
        for policy in allPolicies where policy.therapyDataSource == .careLink || policy.importsTherapyFromCareLink {
            XCTAssertFalse(policy.isMaster, "\(policy)")
            XCTAssertEqual(policy.followerDataSource, .careLink, "\(policy)")
        }
        for policy in allPolicies where policy.availableTherapyDataSources.contains(.careLink) {
            XCTAssertFalse(policy.isMaster, "\(policy)")
            XCTAssertEqual(policy.followerDataSource, .careLink, "\(policy)")
        }
    }

    /// With Nightscout disabled nothing may talk to Nightscout, whatever the other settings say.
    func testDisabledNightscoutTurnsOffEveryNightscoutFlow() {
        for policy in allPolicies where !policy.nightscoutEnabled {
            XCTAssertFalse(policy.importsGlucoseFromNightscout, "\(policy)")
            XCTAssertFalse(policy.exportsGlucoseToNightscout, "\(policy)")
            XCTAssertFalse(policy.importsTreatmentsFromNightscout, "\(policy)")
            XCTAssertFalse(policy.exportsTreatmentsToNightscout, "\(policy)")
            XCTAssertFalse(policy.importsStatusFromNightscout, "\(policy)")
            XCTAssertFalse(policy.showsAIDData, "\(policy)")
            XCTAssertNotEqual(policy.therapyDataSource, .nightscout, "\(policy)")
            XCTAssertFalse(policy.availableTherapyDataSources.contains(.nightscout), "\(policy)")
        }
    }

    /// The AID analytics source, the Home therapy strip and the pump surfaces are derived from the
    /// same import ownership, so they can never disagree with what the managers import.
    func testPresentationFlagsFollowImportOwnership() {
        for policy in allPolicies {
            XCTAssertEqual(policy.showsAIDData, policy.importsStatusFromNightscout, "\(policy)")
            XCTAssertEqual(policy.showsPumpData, policy.showsTherapyStatus, "\(policy)")
            XCTAssertEqual(policy.supportsAIDEnhancedAnalytics, policy.showsTherapyStatus, "\(policy)")

            switch policy.aidAnalyticsSource {
            case .careLink:
                XCTAssertTrue(policy.importsTherapyFromCareLink, "\(policy)")
            case .nightscout(let followType):
                XCTAssertTrue(policy.importsStatusFromNightscout, "\(policy)")
                XCTAssertEqual(followType, policy.nightscoutFollowType)
                XCTAssertNotEqual(followType, .none, "a basic Nightscout follower has no AID status: \(policy)")
            case nil:
                XCTAssertFalse(policy.showsTherapyStatus, "\(policy)")
            }

            // status import is an optional layer on top of treatment import
            if policy.importsStatusFromNightscout {
                XCTAssertTrue(policy.importsTreatmentsFromNightscout, "\(policy)")
            }
        }
    }

    /// Treatment export does not depend on who owns therapy imports.
    func testTreatmentExportOnlyDependsOnNightscoutBeingEnabled() {
        for policy in allPolicies {
            XCTAssertEqual(policy.exportsTreatmentsToNightscout, policy.nightscoutEnabled, "\(policy)")
        }
    }

    // MARK: - glucose direction

    func testOtherFollowerSourcesUploadGlucoseOnlyWhenEnabled() {
        for source in FollowerDataSourceType.allCases where source != .nightscout {
            XCTAssertTrue(policy(source: source, followerUploads: true).exportsGlucoseToNightscout, "\(source)")
            XCTAssertFalse(policy(source: source, followerUploads: false).exportsGlucoseToNightscout, "\(source)")
            XCTAssertFalse(policy(source: source, followerUploads: true).importsGlucoseFromNightscout, "\(source)")
            // the master setting is irrelevant in follower mode
            XCTAssertFalse(policy(source: source, masterUploads: true, followerUploads: false).exportsGlucoseToNightscout, "\(source)")
        }
    }

    /// A stored follower source must not matter in master mode: master readings come from the
    /// local sensor even when the last follower selection was Nightscout.
    func testMasterIgnoresStoredFollowerSource() {
        for source in FollowerDataSourceType.allCases {
            let master = policy(isMaster: true, source: source, masterUploads: true, followerUploads: false)
            XCTAssertTrue(master.exportsGlucoseToNightscout, "\(source)")
            XCTAssertFalse(master.importsGlucoseFromNightscout, "\(source)")
            XCTAssertEqual(master.therapyDataSource, .nightscout, "\(source)")
            XCTAssertEqual(master.availableTherapyDataSources, [.automatic, .nightscout, .none], "\(source)")
        }
    }

    // MARK: - therapy source resolution

    func testExplicitNightscoutWithNightscoutDisabledResolvesToNone() {
        let disabled = policy(source: .careLink, therapy: .nightscout, nightscoutEnabled: false)
        XCTAssertEqual(disabled.therapyDataSource, .none)
        XCTAssertFalse(disabled.importsTherapyFromCareLink, "an explicit Nightscout choice must not fall back to CareLink")
        XCTAssertEqual(disabled.availableTherapyDataSources, [.automatic, .careLink, .none])
    }

    func testAutomaticCareLinkFollowerWithoutNightscout() {
        let careLinkOnly = policy(source: .careLink, therapy: .automatic, nightscoutEnabled: false)
        XCTAssertEqual(careLinkOnly.therapyDataSource, .careLink)
        XCTAssertTrue(careLinkOnly.importsTherapyFromCareLink)
        XCTAssertEqual(careLinkOnly.aidAnalyticsSource, .careLink)
    }

    func testNoneDisablesTherapyImportsButKeepsExports() {
        for source in FollowerDataSourceType.allCases {
            let none = policy(source: source, therapy: .none, followerUploads: true, followType: .openAPS)
            XCTAssertEqual(none.therapyDataSource, .none, "\(source)")
            XCTAssertFalse(none.importsTreatmentsFromNightscout, "\(source)")
            XCTAssertFalse(none.importsStatusFromNightscout, "\(source)")
            XCTAssertFalse(none.importsTherapyFromCareLink, "\(source)")
            XCTAssertNil(none.aidAnalyticsSource, "\(source)")
            XCTAssertTrue(none.exportsTreatmentsToNightscout, "\(source)")
            XCTAssertEqual(none.importsGlucoseFromNightscout, source == .nightscout, "glucose ownership is separate: \(source)")
        }
    }

    func testNightscoutFollowTypeSelectsTheAIDAnalyticsSource() {
        XCTAssertEqual(policy(followType: .loop).aidAnalyticsSource, .nightscout(.loop))
        XCTAssertEqual(policy(followType: .openAPS).aidAnalyticsSource, .nightscout(.openAPS))
        XCTAssertNil(policy(followType: .none).aidAnalyticsSource)
        XCTAssertEqual(policy(isMaster: true, followType: .openAPS).aidAnalyticsSource, .nightscout(.openAPS), "a master can also follow its own loop's status")
    }

    // MARK: - AIDAnalyticsSource

    /// Every device-status identifier belongs to exactly one analytics source, so switching therapy
    /// source never shows the same stored record twice or loses one.
    func testDeviceStatusOwnershipPartitionsIdentifiers() {
        let identifiers: [String?] = [nil, "", "carelink://", "carelink://123456", "loop://iPhone", "openaps://samsung", "Trio", "xcarelink://1", " carelink://1"]
        for identifier in identifiers {
            let nightscoutOwns = AIDAnalyticsSource.nightscout(.loop).ownsDeviceStatus(with: identifier)
            let careLinkOwns = AIDAnalyticsSource.careLink.ownsDeviceStatus(with: identifier)
            XCTAssertNotEqual(nightscoutOwns, careLinkOwns, "\(String(describing: identifier))")
            XCTAssertEqual(careLinkOwns, identifier?.hasPrefix("carelink://") == true)
            // ownership does not depend on the Nightscout follow type
            XCTAssertEqual(AIDAnalyticsSource.nightscout(.openAPS).ownsDeviceStatus(with: identifier), nightscoutOwns)
        }
    }

    /// CareLink has no COB series and no scheduled basal profile, so reports resolved to CareLink
    /// must never offer those charts, whichever configuration produced the source.
    func testResolvedAnalyticsCapabilitiesMatchTheSourceData() {
        for policy in allPolicies {
            guard let source = policy.aidAnalyticsSource else { continue }
            XCTAssertEqual(source.supportsCOB, !policy.importsTherapyFromCareLink, "\(policy)")
            XCTAssertEqual(source.supportsScheduledBasalAnalytics, !policy.importsTherapyFromCareLink, "\(policy)")
        }
        XCTAssertTrue(AIDAnalyticsSource.nightscout(.openAPS).supportsCOB)
        XCTAssertFalse(AIDAnalyticsSource.careLink.supportsScheduledBasalAnalytics)
    }

    func testAIDAnalyticsSourceDistinguishesFollowTypes() {
        let sources: Set<AIDAnalyticsSource> = [.nightscout(.loop), .nightscout(.openAPS), .nightscout(.loop), .careLink]
        XCTAssertEqual(sources.count, 3)
        XCTAssertNotEqual(AIDAnalyticsSource.nightscout(.loop), .nightscout(.openAPS))
    }

    // MARK: - TherapyDataSourceType

    func testTherapyDataSourceDescriptionsUseLocalizedTextsForGenericChoices() {
        XCTAssertEqual(TherapyDataSourceType.automatic.description, Texts_SettingsView.therapyDataSourceAutomatic)
        XCTAssertEqual(TherapyDataSourceType.none.description, Texts_SettingsView.therapyDataSourceNone)
        XCTAssertEqual(TherapyDataSourceType.nightscout.description, "Nightscout")
        XCTAssertEqual(TherapyDataSourceType.careLink.description, "CareLink")
    }
}
