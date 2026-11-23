//
//  FollowerDataSourceTypeTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the follower source selection and the per-source rules that other managers rely on.
///
/// The raw value is stored in UserDefaults and Core Data, so a stored value must always resolve to a
/// usable source: a hidden or unknown value must fall back to the first enabled source instead of
/// leaving the follower without any data source. The OS-AID sharing policy decides whether glucose
/// may be passed to a closed-loop app, so only the sources that need consent may depend on it.
final class FollowerDataSourceTypeTests: XCTestCase {

    // MARK: - validated selection

    func testEveryEnabledStoredSelectionIsPreserved() {
        let enabled = FollowerDataSourceType.allCasesForList
        for source in FollowerDataSourceType.allCases {
            XCTAssertEqual(FollowerDataSourceType.validatedSelection(storedRawValue: source.rawValue, enabledCases: enabled), source)
        }
    }

    func testHiddenStoredSelectionFallsBackToFirstEnabledSourceInDisplayOrder() {
        // a build that hides LibreLinkUp Russia (raw 2): the first enabled case is used, not raw 0
        let enabled = FollowerDataSourceType.allCasesForList.filter { $0 != .libreLinkUpRussia && $0 != .nightscout }
        XCTAssertEqual(FollowerDataSourceType.validatedSelection(storedRawValue: 2, enabledCases: enabled), .dexcomShare)
    }

    func testUnknownOrMissingStoredSelectionFallsBack() {
        let enabled: [FollowerDataSourceType] = [.calendar, .careLink]
        for raw in [nil, -1, 7, 99, Int.max] as [Int?] {
            XCTAssertEqual(FollowerDataSourceType.validatedSelection(storedRawValue: raw, enabledCases: enabled), .calendar, "\(String(describing: raw))")
        }
        XCTAssertEqual(FollowerDataSourceType.validatedSelection(storedRawValue: 3, enabledCases: []), .nightscout, "Nightscout is the last-resort fallback")
    }

    /// Without an IgnoreFollowerTypes override every source is enabled and the default argument of
    /// `validatedSelection` keeps any stored value.
    func testDefaultBuildEnablesEverySourceInDisplayOrder() {
        XCTAssertEqual(FollowerDataSourceType.allEnabledCases, FollowerDataSourceType.allCasesForList)
        for source in FollowerDataSourceType.allCases {
            XCTAssertTrue(source.isEnabled, "\(source)")
            XCTAssertEqual(FollowerDataSourceType.validatedSelection(storedRawValue: source.rawValue), source)
        }
        XCTAssertEqual(FollowerDataSourceType.validatedSelection(storedRawValue: nil), .nightscout)
    }

    /// The picker list must show every case exactly once, otherwise a stored source cannot be shown
    /// or selected again.
    func testDisplayListIsAPermutationOfAllCases() {
        let list = FollowerDataSourceType.allCasesForList
        XCTAssertEqual(list.count, FollowerDataSourceType.allCases.count)
        XCTAssertEqual(Set(list), Set(FollowerDataSourceType.allCases))
        XCTAssertEqual(list.first, .nightscout, "Nightscout is the first and default choice")
    }

    /// Raw values are append-only because they are persisted as Int16 in Core Data.
    func testRawValuesAreContiguousAndAppendOnly() {
        XCTAssertEqual(FollowerDataSourceType.allCases.map(\.rawValue), Array(0..<FollowerDataSourceType.allCases.count))
        XCTAssertEqual(FollowerDataSourceType(rawValue: 6), .careLink)
        XCTAssertEqual(FollowerDataSourceType(rawValue: 4), .medtrumEasyView)
        XCTAssertNil(FollowerDataSourceType(rawValue: FollowerDataSourceType.allCases.count))
    }

    // MARK: - OS-AID sharing

    func testOnlyEasyViewSharingDependsOnExplicitConsent() {
        for source in FollowerDataSourceType.allCases {
            let withoutConsent = source.osAidSharingPolicy.permitsSharing(hasExplicitConsent: false)
            let withConsent = source.osAidSharingPolicy.permitsSharing(hasExplicitConsent: true)
            XCTAssertTrue(withConsent, "\(source)")
            XCTAssertEqual(withoutConsent, source != .medtrumEasyView, "\(source)")
        }
    }

    func testSharingPolicyDecisionTable() {
        let expectations: [(OSAidSharingPolicy, Bool, Bool)] = [
            (.allowed, false, true),
            (.allowed, true, true),
            (.requiresExplicitConsent, false, false),
            (.requiresExplicitConsent, true, true),
            (.blocked, false, false),
            (.blocked, true, false)
        ]
        for (policy, consent, expected) in expectations {
            XCTAssertEqual(policy.permitsSharing(hasExplicitConsent: consent), expected, "\(policy) consent=\(consent)")
        }
    }

    // MARK: - texts used by compact surfaces

    /// The Watch and widgets use the abbreviation to tell sources apart; only the two LibreLinkUp
    /// server variants are the same service and may share one.
    func testAbbreviationsAndShortDescriptionsOnlyCollapseLibreLinkUpVariants() {
        let others = FollowerDataSourceType.allCases.filter { $0 != .libreLinkUpRussia }
        XCTAssertEqual(Set(others.map(\.abbreviation)).count, others.count)
        XCTAssertEqual(Set(others.map(\.shortDescription)).count, others.count)
        XCTAssertEqual(Set(FollowerDataSourceType.allCases.map(\.description)).count, FollowerDataSourceType.allCases.count, "the full description stays unique")
        XCTAssertEqual(FollowerDataSourceType.libreLinkUpRussia.abbreviation, FollowerDataSourceType.libreLinkUp.abbreviation)
        XCTAssertEqual(FollowerDataSourceType.libreLinkUpRussia.shortDescription, FollowerDataSourceType.libreLinkUp.shortDescription)
    }

    func testShortDescriptionIsNeverLongerThanDescription() {
        for source in FollowerDataSourceType.allCases {
            XCTAssertLessThanOrEqual(source.shortDescription.count, source.description.count, "\(source)")
            XCTAssertLessThanOrEqual(source.abbreviation.count, 3, "\(source)")
            XCTAssertTrue(source.descriptionForLogging().hasPrefix(source.description), "\(source)")
            XCTAssertTrue(source.descriptionForLogging().hasSuffix(" Follower"), "\(source)")
        }
    }

    // MARK: - disconnect warning

    /// Sources polled every minute warn sooner than the five-minute sources; the calendar follower
    /// reads Nightscout-like five-minute data and shares its threshold.
    func testDisconnectWarningMatchesEachSourcePollingInterval() {
        XCTAssertEqual(FollowerDataSourceType.nightscout.secondsUntilFollowerDisconnectWarning, ConstantsFollower.secondsUntilFollowerDisconnectWarningNightscout)
        XCTAssertEqual(FollowerDataSourceType.calendar.secondsUntilFollowerDisconnectWarning, ConstantsFollower.secondsUntilFollowerDisconnectWarningNightscout)
        XCTAssertEqual(FollowerDataSourceType.libreLinkUp.secondsUntilFollowerDisconnectWarning, ConstantsFollower.secondsUntilFollowerDisconnectWarningLibreLinkUp)
        XCTAssertEqual(FollowerDataSourceType.libreLinkUpRussia.secondsUntilFollowerDisconnectWarning, ConstantsFollower.secondsUntilFollowerDisconnectWarningLibreLinkUp)
        XCTAssertEqual(FollowerDataSourceType.dexcomShare.secondsUntilFollowerDisconnectWarning, ConstantsFollower.secondsUntilFollowerDisconnectWarningDexcomShare)
        XCTAssertEqual(FollowerDataSourceType.medtrumEasyView.secondsUntilFollowerDisconnectWarning, ConstantsFollower.secondsUntilFollowerDisconnectWarningMedtrumEasyView)
        XCTAssertEqual(FollowerDataSourceType.careLink.secondsUntilFollowerDisconnectWarning, 20 * 60, "CareLink publishes every five minutes with long upload delays")

        // one-minute sources must warn before the five-minute sources
        XCTAssertLessThan(FollowerDataSourceType.libreLinkUp.secondsUntilFollowerDisconnectWarning, FollowerDataSourceType.nightscout.secondsUntilFollowerDisconnectWarning)
        // a warning must never fire before one five-minute reading interval has passed
        for source in [FollowerDataSourceType.nightscout, .dexcomShare, .calendar, .careLink] {
            XCTAssertGreaterThan(source.secondsUntilFollowerDisconnectWarning, 300, "\(source)")
        }
    }
}
