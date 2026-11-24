//
//  NightscoutTreatmentEditSyncTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
import CoreData
@testable import xdrip

/// Regression tests for treatments edited by another app after xDrip4iOS imported them.
///
/// Issue #624: after changing the carbs of a meal in iAPS, the treatment list showed two meals,
/// the original and the edited one. iAPS does not update the Nightscout record in place: it
/// deletes the old record (`DELETE` by `creation_date`) and uploads a new one with a new `_id`.
/// Loop updates the record in place, which is why the same scenario worked with Loop. xDrip4iOS
/// imported the new record but kept the old one, as nothing removed treatments deleted remotely.
final class NightscoutTreatmentEditSyncTests: XCTestCase {

    // MARK: - iAPS meal edits

    /// The edited meal must replace the imported one: one visible carbs treatment, new amount.
    @MainActor func testMealEditedInIAPSReplacesTheImportedTreatment() async throws {
        try await withNightscoutTreatmentImport { coreDataManager, manager in
            let accessor = TreatmentEntryAccessor(coreDataManager: coreDataManager)
            // Within the 24-hour download window, which reconciliation is limited to.
            let mealDate = ISO8601DateFormatter.string(from: Date().addingTimeInterval(-3600), timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withInternetDateTime, .withFractionalSeconds])

            // iAPS uploads the meal and xDrip4iOS imports it.
            let original = try responses([meal(id: "6741a1f0c2a3b40012a1b2c3", carbs: 20, createdAt: mealDate)])
            let imported = try await manager.newTreatmentsIfRequired(treatmentNSResponses: original)
            XCTAssertEqual(imported, 1)
            XCTAssertTrue(coreDataManager.saveChangesSynchronously())

            // The meal is edited in iAPS: the old record is deleted, the new one has a new _id.
            let edited = try responses([meal(id: "6741a2b8c2a3b40012a1b2d9", carbs: 30, createdAt: mealDate)])
            let importedAfterEdit = try await manager.newTreatmentsIfRequired(treatmentNSResponses: edited)
            XCTAssertEqual(importedAfterEdit, 1)

            // Same reconciliation the sync performs after each treatment download. Nightscout
            // confirms the old record is gone by returning an empty result for its exact _id.
            var lookedUpIDs: [String] = []
            var deletedCount: Int?
            manager.reconcileRemoteTreatmentDeletions(
                treatments: accessor.getLatestTreatments(limit: ConstantsNightscout.maxTreatmentsToUpload),
                downloaded: edited,
                lookup: { remoteID, finished in
                    lookedUpIDs.append(remoteID)
                    finished(Data("[]".utf8), true)
                },
                completion: { deletedCount = $0 }
            )

            XCTAssertEqual(lookedUpIDs, ["6741a1f0c2a3b40012a1b2c3"])
            XCTAssertEqual(deletedCount, 1)

            let visibleCarbs = accessor.getLatestTreatments(howOld: nil)
                .filter { $0.treatmentType == .Carbs && !$0.treatmentdeleted }
            XCTAssertEqual(visibleCarbs.count, 1, "the meal edited in iAPS must not appear twice")
            XCTAssertEqual(visibleCarbs.first?.value, 30)
            XCTAssertEqual(visibleCarbs.first?.id, "6741a2b8c2a3b40012a1b2d9" + TreatmentType.Carbs.idExtension())
        }
    }

    /// Meals edited hours later must be checked too. OpenAPS and Trio record a temp basal every
    /// few minutes, so the latest 50 treatments, used for uploading, cover only a few hours: an
    /// older edited meal was never checked for deletion and stayed in the list twice.
    @MainActor func testMealOlderThanTheLatestFiftyTreatmentsIsCheckedForDeletion() async throws {
        try await withNightscoutTreatmentImport { coreDataManager, manager in
            let context = coreDataManager.mainManagedObjectContext
            let meal = TreatmentEntry(id: "6741a1f0c2a3b40012a1b2c3" + TreatmentType.Carbs.idExtension(), date: Date().addingTimeInterval(-6 * 3600), value: 20, treatmentType: .Carbs, nightscoutEventType: "Carb Correction", enteredBy: "iAPS", nsManagedObjectContext: context)
            // A temp basal every 5 minutes after the meal, as uploaded by an oref-based AID.
            for index in 0..<70 {
                _ = TreatmentEntry(id: "basal\(index)" + TreatmentType.Basal.idExtension(), date: Date().addingTimeInterval(-Double(index) * 300), value: 0.8, valueSecondary: 30, treatmentType: .Basal, nightscoutEventType: "Temp Basal", enteredBy: "openaps", nsManagedObjectContext: context)
            }
            XCTAssertTrue(coreDataManager.saveChangesSynchronously())

            let treatmentsToSync = TreatmentEntryAccessor(coreDataManager: coreDataManager).getLatestTreatments(limit: ConstantsNightscout.maxTreatmentsToUpload)
            XCTAssertFalse(treatmentsToSync.contains(meal), "precondition: the meal is not among the latest 50 treatments")

            XCTAssertTrue(manager.treatmentsForRemoteDeletionCheck(treatmentsToSync: treatmentsToSync).contains(meal))
        }
    }

    // MARK: - private functions

    /// A carbs treatment as iAPS uploads it to Nightscout.
    private func meal(id: String, carbs: Double, createdAt: String) -> NSDictionary {
        ["_id": id, "eventType": "Carb Correction", "carbs": carbs, "created_at": createdAt, "enteredBy": "iAPS"]
    }

    /// Parses Nightscout documents through the same JSON path as the treatment download.
    private func responses(_ documents: [NSDictionary]) throws -> [TreatmentNSResponse] {
        let data = try JSONSerialization.data(withJSONObject: documents)
        return try XCTUnwrap(TreatmentNSResponse.arrayFromData(data))
    }

    /// Runs `body` with Nightscout as the treatment source, restoring the changed defaults afterwards.
    @MainActor private func withNightscoutTreatmentImport(
        _ body: (CoreDataManager, NightscoutSyncManager) async throws -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let keys = ["nightscoutEnabled", "therapyDataSourceType"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.nightscoutEnabled = true
        defaults.therapyDataSourceType = .nightscout

        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
        try await body(coreDataManager, manager)
    }
}
