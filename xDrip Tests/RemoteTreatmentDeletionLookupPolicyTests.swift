//
//  RemoteTreatmentDeletionLookupPolicyTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for the number of Nightscout requests made to confirm remote deletions.
///
/// Issue #624: to remove meals edited in iAPS, every local treatment of the 24 hour download window
/// became a candidate for an exact-id request, instead of only the latest 50. When Nightscout
/// returned fewer treatments than the window holds (at most 1000 by default, which a busy AID can
/// reach), each missing one was requested separately, hundreds of requests on every sync.
final class RemoteTreatmentDeletionLookupPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - limit (#624)

    func testLookupsAreLimitedPerSync() {
        let candidates = Dictionary(uniqueKeysWithValues: (0..<300).map { ("id\($0)", now.addingTimeInterval(TimeInterval(-60 * $0))) })

        XCTAssertEqual(RemoteTreatmentDeletionLookupPolicy.remoteIDsToLookUp(newestDateByRemoteID: candidates).count, RemoteTreatmentDeletionLookupPolicy.maximumLookupsPerSync)
    }

    func testNewestTreatmentsAreLookedUpFirst() {
        let candidates = [
            "a-oldest": now.addingTimeInterval(-20 * 3600),
            "b-newest": now.addingTimeInterval(-60),
            "c-middle": now.addingTimeInterval(-3600)
        ]

        XCTAssertEqual(RemoteTreatmentDeletionLookupPolicy.remoteIDsToLookUp(newestDateByRemoteID: candidates, limit: 2), ["b-newest", "c-middle"])
    }

    // MARK: - ids

    func testEmptyIDsAreNeverLookedUp() {
        XCTAssertEqual(RemoteTreatmentDeletionLookupPolicy.remoteIDsToLookUp(newestDateByRemoteID: ["": now, "id": now]), ["id"])
    }
}
