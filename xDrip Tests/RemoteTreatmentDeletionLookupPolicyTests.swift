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

    /// When more ids are missing than one sync may look up, the ids looked up by a sync come last at
    /// the next one. Otherwise the same newest ids, still present on Nightscout, would take every
    /// lookup of every sync and an older deleted treatment would never be checked.
    func testLaterSyncsLookUpTheIdsEarlierSyncsDidNot() {
        let candidates = Dictionary(uniqueKeysWithValues: (0..<120).map { ("id\($0)", now.addingTimeInterval(TimeInterval(-60 * $0))) })
        var lastLookup = [String: Date]()
        var lookedUp = [String]()
        for sync in 0..<3 {
            let ids = RemoteTreatmentDeletionLookupPolicy.remoteIDsToLookUp(newestDateByRemoteID: candidates, lastLookupByRemoteID: lastLookup)
            for id in ids { lastLookup[id] = now.addingTimeInterval(TimeInterval(sync * 300)) }
            lookedUp += ids
        }
        XCTAssertEqual(lookedUp.count, 3 * RemoteTreatmentDeletionLookupPolicy.maximumLookupsPerSync)
        XCTAssertEqual(Set(lookedUp.prefix(120)).count, 120, "every id is looked up once before any is looked up again")
        XCTAssertEqual(Set(lookedUp), Set(candidates.keys))
    }

    // MARK: - ids

    func testEmptyIDsAreNeverLookedUp() {
        XCTAssertEqual(RemoteTreatmentDeletionLookupPolicy.remoteIDsToLookUp(newestDateByRemoteID: ["": now, "id": now]), ["id"])
    }
}
