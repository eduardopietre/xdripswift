//
//  LibreCoverageLibre3SupportTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CryptoKit
import Security
import XCTest
@testable import xdrip

final class LibreCoverageLibre3SupportTests: XCTestCase {
    // MARK: - helpers

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func identityEntry(label: String, key: P256.KeyAgreement.PrivateKey = .init(), corruptCertificate: Bool = false) -> [String: String] {
        var certificate = Data(repeating: 0xA5, count: 162)
        certificate.replaceSubrange(33..<98, with: key.publicKey.x963Representation)
        if corruptCertificate { certificate[33] = 0x02 }
        return ["label": label, "privateKeyHex": hex(key.rawRepresentation), "certificateHex": hex(certificate)]
    }

    private func payload(format: Int = 1, curve: String = "P-256", identities: [[String: String]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["format": format, "curve": curve, "identities": identities], options: [.sortedKeys])
    }

    private func requireKeychain() throws -> String {
        let service = "xdrip.librecoverage.tests." + UUID().uuidString
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "probe", kSecValueData as String: Data([0])]
        let status = SecItemAdd(probe as CFDictionary, nil)
        if status == errSecMissingEntitlement { throw XCTSkip("Unsigned simulator cannot access Keychain, requires a signed host.") }
        XCTAssertEqual(status, errSecSuccess)
        SecItemDelete(probe as CFDictionary)
        return service
    }

    private func removeKeychain(_ service: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }

    // MARK: - Libre3IdentityStore.validate

    func testValidateAcceptsWellFormedIdentityFile() throws {
        let key = P256.KeyAgreement.PrivateKey()
        let json = try payload(identities: [identityEntry(label: "first", key: key), identityEntry(label: "second")])
        let identities = try Libre3IdentityStore.validate(json: json, digest: digest(json))
        XCTAssertEqual(identities.map(\.label), ["first", "second"])
        XCTAssertEqual(identities.first?.privateKey.rawRepresentation, key.rawRepresentation)
        XCTAssertEqual(identities.first?.certificate.staticPub, key.publicKey.x963Representation)
        XCTAssertEqual(identities.first?.certificate.raw.count, 162)
    }

    func testValidateAcceptsUppercaseHex() throws {
        var entry = identityEntry(label: "upper")
        entry["privateKeyHex"] = entry["privateKeyHex"]?.uppercased()
        entry["certificateHex"] = entry["certificateHex"]?.uppercased()
        let json = try payload(identities: [entry])
        XCTAssertEqual(try Libre3IdentityStore.validate(json: json, digest: digest(json)).count, 1)
    }

    func testValidateRejectsDigestMismatch() throws {
        let json = try payload(identities: [identityEntry(label: "a")])
        XCTAssertThrowsError(try Libre3IdentityStore.validate(json: json, digest: String(repeating: "0", count: 64))) {
            XCTAssertEqual($0 as? Libre3IdentityError, .invalidFile)
        }
    }

    func testValidateRejectsUnsupportedFormatOrCurve() throws {
        for json in [try payload(format: 2, identities: [identityEntry(label: "a")]), try payload(curve: "P-384", identities: [identityEntry(label: "a")])] {
            XCTAssertThrowsError(try Libre3IdentityStore.validate(json: json, digest: digest(json)))
        }
    }

    func testValidateRejectsEmptyDuplicateOrTooManyIdentities() throws {
        let empty = try payload(identities: [])
        XCTAssertThrowsError(try Libre3IdentityStore.validate(json: empty, digest: digest(empty)))
        let duplicate = try payload(identities: [identityEntry(label: "same"), identityEntry(label: "same")])
        XCTAssertThrowsError(try Libre3IdentityStore.validate(json: duplicate, digest: digest(duplicate)))
        let tooMany = try payload(identities: (0..<17).map { identityEntry(label: "id\($0)") })
        XCTAssertThrowsError(try Libre3IdentityStore.validate(json: tooMany, digest: digest(tooMany)))
        let sixteen = try payload(identities: (0..<16).map { identityEntry(label: "id\($0)") })
        XCTAssertEqual(try Libre3IdentityStore.validate(json: sixteen, digest: digest(sixteen)).count, 16)
    }

    func testValidateRejectsMalformedHexAndKeyMaterial() throws {
        var badCharacter = identityEntry(label: "a")
        badCharacter["privateKeyHex"] = "zz" + String(badCharacter["privateKeyHex"]!.dropFirst(2))
        var shortKey = identityEntry(label: "b")
        shortKey["privateKeyHex"] = String(shortKey["privateKeyHex"]!.dropFirst(2))
        var mismatched = identityEntry(label: "c")
        mismatched["privateKeyHex"] = identityEntry(label: "other")["privateKeyHex"]
        var emptyLabel = identityEntry(label: "d")
        emptyLabel["label"] = ""
        let compressedPoint = identityEntry(label: "e", corruptCertificate: true)
        for entry in [badCharacter, shortKey, mismatched, emptyLabel, compressedPoint] {
            let json = try payload(identities: [entry])
            XCTAssertThrowsError(try Libre3IdentityStore.validate(json: json, digest: digest(json)), entry["label"] ?? "") {
                XCTAssertEqual($0 as? Libre3IdentityError, .invalidFile)
            }
        }
    }

    func testValidateRejectsNonJSONAndOversizedFiles() throws {
        let garbage = Data("not json".utf8)
        XCTAssertThrowsError(try Libre3IdentityStore.validate(json: garbage, digest: digest(garbage)))
        let huge = Data(repeating: 0x20, count: 1_000_001)
        XCTAssertThrowsError(try Libre3IdentityStore.validate(json: huge, digest: digest(huge)))
    }

    func testIdentitySourceListsTwoGatewaysForTheTransaction() {
        let source = Libre3IdentitySource.current
        XCTAssertEqual(source.gateways.map(\.absoluteString), [
            "https://arweave.net/" + source.transaction, "https://turbo-gateway.com/" + source.transaction,
        ])
        XCTAssertEqual(source.digest.count, 64)
    }

    func testIdentityErrorsHaveDistinctDescriptions() {
        XCTAssertNotEqual(Libre3IdentityError.invalidFile.errorDescription, Libre3IdentityError.unavailable.errorDescription)
        XCTAssertFalse(Libre3IdentityError.invalidFile.errorDescription?.isEmpty ?? true)
    }

    func testPhoneCertificateRejectsWrongSizeAndCompressedPoint() {
        XCTAssertThrowsError(try Libre3PhoneCert(raw: Data(count: 161))) { XCTAssertEqual($0 as? Libre3PhoneCertError, .wrongSize(161)) }
        var raw = Data(repeating: 0, count: 162)
        XCTAssertThrowsError(try Libre3PhoneCert(raw: raw)) { XCTAssertEqual($0 as? Libre3PhoneCertError, .notUncompressedPoint) }
        raw[33] = 0x04
        XCTAssertEqual(try Libre3PhoneCert(raw: raw).staticPub.count, 65)
    }

    // MARK: - Libre3IdentityStore with Keychain

    func testIdentityStoreSavesSelectsAndReloadsValidatedVersion() async throws {
        let service = try requireKeychain()
        defer { removeKeychain(service) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: service))
        defer { defaults.removePersistentDomain(forName: service) }
        let store = Libre3IdentityStore(service: service, defaults: defaults)
        let json = try payload(identities: [identityEntry(label: "alpha"), identityEntry(label: "beta")])
        let source = Libre3IdentitySource(version: "test-1", transaction: "t", digest: digest(json))

        let empty = try await store.versions()
        XCTAssertTrue(empty.isEmpty)
        let version = try await store.saveValidated(json: json, source: source)
        XCTAssertEqual(version.id, "test-1")
        XCTAssertEqual(version.labels, ["alpha", "beta"])
        let selected = try await store.selectedVersion()
        XCTAssertEqual(selected, "test-1")
        let identities = try await store.identities(version: "test-1")
        XCTAssertEqual(identities.map(\.label), ["alpha", "beta"])
        let again = try await store.saveValidated(json: json, source: source)
        XCTAssertEqual(again, version)
        let available = try await store.ensureAvailable()
        XCTAssertEqual(available, version)
    }

    func testIdentityStoreRejectsUnknownVersionAndChangedDigest() async throws {
        let service = try requireKeychain()
        defer { removeKeychain(service) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: service))
        defer { defaults.removePersistentDomain(forName: service) }
        let store = Libre3IdentityStore(service: service, defaults: defaults)
        do {
            try await store.select("missing")
            XCTFail("selecting an unknown version must fail")
        } catch {
            XCTAssertEqual(error as? Libre3IdentityError, .unavailable)
        }
        let json = try payload(identities: [identityEntry(label: "alpha")])
        _ = try await store.saveValidated(json: json, source: Libre3IdentitySource(version: "v", transaction: "t", digest: digest(json)))
        let other = try payload(identities: [identityEntry(label: "beta")])
        do {
            _ = try await store.saveValidated(json: other, source: Libre3IdentitySource(version: "v", transaction: "t", digest: digest(other)))
            XCTFail("an immutable version cannot change its digest")
        } catch {
            XCTAssertEqual(error as? Libre3IdentityError, .invalidFile)
        }
    }

    func testCredentialStoreRoundTripsPairingRecords() throws {
        let service = try requireKeychain()
        defer { removeKeychain(service) }
        let store = Libre3CredentialStore(service: service)
        XCTAssertNil(try store.pending())
        XCTAssertNil(try store.load(serial: "NONE"))
        var record = Libre3PairingRecord.unavailable(serial: "SERIAL1")
        record.lastLifeCount = 99
        try store.save(record)
        XCTAssertEqual(try store.load(serial: "SERIAL1"), record)
        XCTAssertEqual(try store.pending(), record)
        try store.removeAll()
        XCTAssertNil(try store.pending())
    }

    // MARK: - Libre3SensorStatus

    func testSensorStatusSeverities() {
        XCTAssertEqual(Libre3SensorStatus.okay.severity, .okay)
        XCTAssertEqual(Libre3SensorStatus.warmingUp.severity, .warmup)
        XCTAssertEqual(Libre3SensorStatus.readingUnavailable.severity, .warning)
        XCTAssertEqual(Libre3SensorStatus.checkSensor.severity, .warning)
        XCTAssertEqual(Libre3SensorStatus.expired.severity, .error)
        XCTAssertEqual(Libre3SensorStatus.replaceSensor.severity, .error)
        for status: Libre3SensorStatus in [.waitingForSensor, .authenticating, .waitingForGlucose] {
            XCTAssertEqual(status.severity, .waiting)
        }
    }

    func testSensorStatusParsesStoredValuesIncludingLegacyHealthyStatus() {
        XCTAssertEqual(Libre3SensorStatus(storedValue: "Receiving glucose"), .okay)
        XCTAssertEqual(Libre3SensorStatus(storedValue: "Sensor expired"), .expired)
        XCTAssertEqual(Libre3SensorStatus(storedValue: "Authenticating sensor"), .authenticating)
        XCTAssertNil(Libre3SensorStatus(storedValue: "The sensor disconnected. Retry the connection."))
        XCTAssertNil(Libre3SensorStatus(storedValue: ""))
    }

    // MARK: - backfill helpers

    func testBackfillWindowRequiresSensorPastWarmup() {
        XCTAssertNil(Libre3BackfillWindow.startMinute(currentAge: 60, lastKnownAge: nil, warmupMinutes: 60))
        XCTAssertNil(Libre3BackfillWindow.startMinute(currentAge: 100, lastKnownAge: nil, warmupMinutes: -1))
        XCTAssertNil(Libre3BackfillWindow.startMinute(currentAge: 70_000, lastKnownAge: nil, warmupMinutes: 60))
    }

    func testBackfillWindowKeepsThreeHourOverlapByDefault() {
        XCTAssertEqual(Libre3BackfillWindow.startMinute(currentAge: 1000, lastKnownAge: nil, warmupMinutes: 60), 820)
        XCTAssertEqual(Libre3BackfillWindow.startMinute(currentAge: 100, lastKnownAge: nil, warmupMinutes: 60), 60)
        XCTAssertEqual(Libre3BackfillWindow.startMinute(currentAge: 1000, lastKnownAge: 990, warmupMinutes: 60), 820)
    }

    func testBackfillWindowExtendsToTheLastKnownMinuteButNotBeforeWarmup() {
        XCTAssertEqual(Libre3BackfillWindow.startMinute(currentAge: 1000, lastKnownAge: 500, warmupMinutes: 60), 500)
        XCTAssertEqual(Libre3BackfillWindow.startMinute(currentAge: 1000, lastKnownAge: 10, warmupMinutes: 60), 60)
    }

    func testBackfillSummaryCountsStreamsAndRange() {
        var summary = Libre3BackfillSummary()
        summary.append(minutes: [], stream: .historical)
        XCTAssertNil(summary.firstMinute)
        summary.append(minutes: [300, 200, 250], stream: .historical)
        summary.append(minutes: [400], stream: .clinical)
        summary.append(minutes: [100, 150], stream: .clinical)
        XCTAssertEqual(summary.historicalCount, 3)
        XCTAssertEqual(summary.clinicalCount, 3)
        XCTAssertEqual(summary.firstMinute, 100)
        XCTAssertEqual(summary.lastMinute, 400)
    }

    // MARK: - errors and NFC

    func testConnectionErrorsHaveDistinctDescriptions() {
        let errors: [Libre3ConnectionError] = [.storage, .disconnected, .timeout, .malformed, .identity, .notStarted, .recovery, .resources, .credentialsRejected, .alreadyStarted(receiverID: nil)]
        let descriptions = errors.compactMap(\.errorDescription)
        XCTAssertEqual(descriptions.count, errors.count)
        XCTAssertEqual(Set(descriptions).count, errors.count)
        XCTAssertEqual(Libre3ConnectionError.alreadyStarted(receiverID: 1).errorDescription, Libre3ConnectionError.alreadyStarted(receiverID: nil).errorDescription)
    }

    func testAccountLookupErrorsHaveDistinctDescriptions() {
        let errors: [Libre3AccountLookup.LookupError] = [.credentials, .consent, .unsupported]
        XCTAssertEqual(Set(errors.compactMap(\.errorDescription)).count, 3)
    }

    func testLogHandlesEveryErrorCategoryWithoutThrowing() {
        Libre3Log.failure("lookup", error: Libre3AccountLookup.LookupError.credentials)
        Libre3Log.failure("lookup", error: Libre3AccountLookup.LookupError.consent, channel: "x")
        Libre3Log.failure("lookup", error: Libre3AccountLookup.LookupError.unsupported)
        Libre3Log.failure("identity", error: Libre3IdentityError.invalidFile)
        Libre3Log.failure("identity", error: Libre3IdentityError.unavailable)
        Libre3Log.failure("system", error: NSError(domain: "test", code: 7))
        Libre3Log.failure("none", error: nil)
        Libre3Log.event(.authenticationFailed, error: Libre3ConnectionError.timeout)
        Libre3Log.event(.sensorOkay)
        Libre3Log.detail("detail")
    }

    func testNFCScanFailsWithoutReaderHardware() async {
        let reader = Libre3NFCActivationReader()
        do {
            _ = try await reader.scan(mode: .readPatchInfo)
            XCTFail("the simulator has no NFC reader")
        } catch {
            XCTAssertEqual(error as? Libre3NFCError, .readerUnavailable)
        }
        reader.cancel()
    }

    // MARK: - clinical and historical records

    private func words(_ values: [UInt16]) -> Data {
        Data(values.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    }

    func testClinicalRecordDecodesWordsAndGlucose() throws {
        let record = try Libre3ClinicalReadingRecord(plaintext: words([1000, 1, 2, 3, 4, 145, 20]))
        XCTAssertEqual(record.lifeCount, 1000)
        XCTAssertEqual([record.rawSensorWord1, record.rawSensorWord2, record.rawSensorWord3, record.reservedWord], [1, 2, 3, 4])
        XCTAssertEqual(record.currentGlucoseMgDL, 145)
        XCTAssertEqual(record.historicGlucose, .belowDisplayRange(raw: 20, displayMgDL: 39))
        XCTAssertEqual(record.historicGlucoseMgDL, 39)
        XCTAssertEqual(record.historicLifeCountEstimate, 980)
    }

    func testClinicalRecordHistoricEstimateNeedsSeventeenMinutes() throws {
        XCTAssertNil(try Libre3ClinicalReadingRecord(plaintext: words([16, 0, 0, 0, 0, 0, 0])).historicLifeCountEstimate)
        XCTAssertEqual(try Libre3ClinicalReadingRecord(plaintext: words([17, 0, 0, 0, 0, 0, 0])).historicLifeCountEstimate, 0)
        XCTAssertEqual(try Libre3ClinicalReadingRecord(plaintext: words([29, 0, 0, 0, 0, 0, 0])).historicLifeCountEstimate, 10)
        XCTAssertNil(try Libre3ClinicalReadingRecord(plaintext: words([100, 0, 0, 0, 0, 0, 0])).currentGlucoseMgDL)
    }

    func testClinicalRecordRejectsWrongSize() {
        XCTAssertThrowsError(try Libre3ClinicalReadingRecord(plaintext: Data(count: 13))) {
            XCTAssertEqual($0 as? Libre3ClinicalReadingRecordError, .wrongPlaintextSize(13))
        }
    }

    func testHistoricalPageSpacesSamplesFiveMinutesApart() throws {
        let page = try Libre3HistoricalReadingPage(plaintext: words([700, 100, 0, 600, 38, 501, 1000]))
        XCTAssertEqual(page.startLifeCount, 700)
        XCTAssertEqual(page.endLifeCount, 725)
        XCTAssertEqual(page.samples.map(\.lifeCount), [700, 705, 710, 715, 720, 725])
        XCTAssertEqual(page.samples.map(\.glucoseMgDL), [100, nil, 501, 39, 501, nil])
    }

    func testHistoricalPageRejectsWrongSizeAndOverflowingLifeCount() {
        XCTAssertThrowsError(try Libre3HistoricalReadingPage(plaintext: Data(count: 15))) {
            XCTAssertEqual($0 as? Libre3HistoricalReadingPageError, .wrongPlaintextSize(15))
        }
        XCTAssertThrowsError(try Libre3HistoricalReadingPage(plaintext: words([UInt16.max - 24, 0, 0, 0, 0, 0, 0]))) {
            XCTAssertEqual($0 as? Libre3HistoricalReadingPageError, .invalidLifeCount)
        }
        XCTAssertEqual(try Libre3HistoricalReadingPage(plaintext: words([UInt16.max - 25, 0, 0, 0, 0, 0, 0])).endLifeCount, UInt16.max)
    }

    // MARK: - data plane state

    func testDataPlaneStateBuildsReconnectBackfillFromLastAcceptedGlucose() throws {
        XCTAssertTrue(Libre3DataPlaneState().reconnectBackfillCommands().isEmpty)
        let sensor = try Libre3SensorState(serialNumber: "S", blePIN: Data([1, 2, 3, 4]), lastGlucoseLifeCount: 900, lastGlucoseMgDL: 110, warmupDurationMinutes: 45, wearDurationMinutes: 21600)
        let state = Libre3DataPlaneState(sensorState: sensor)
        XCTAssertEqual(state.warmupDurationMinutes, 45)
        XCTAssertEqual(state.wearDurationMinutes, 21600)
        XCTAssertEqual(state.reconnectBackfillLowerBoundLifeCount, 900)
        XCTAssertEqual(state.reconnectBackfillCommands(), [
            .historicalBackfillGreaterEqual(lifeCount: 900, selector: 0x01),
            .clinicalBackfillGreaterEqual(lifeCount: 900, selector: 0x01),
        ])
        XCTAssertEqual(state.reconnectBackfillCommands(includeClinical: false).count, 1)
        XCTAssertNil(state.lifecyclePhase)
        XCTAssertFalse(state.isInWarmup)
        XCTAssertFalse(state.shouldNotifyUser)
        XCTAssertFalse(state.shouldNotifyReplaceSensor)
    }

    func testDataPlaneStateClampsDurationsAndFallsBackToDefaults() throws {
        let clamped = Libre3DataPlaneState(warmupDurationMinutes: -5, wearDurationMinutes: -1)
        XCTAssertEqual(clamped.warmupDurationMinutes, 0)
        XCTAssertEqual(clamped.wearDurationMinutes, 0)
        let sensor = try Libre3SensorState(serialNumber: nil, blePIN: Data([1, 2, 3, 4]))
        XCTAssertEqual(Libre3DataPlaneState(sensorState: sensor).warmupDurationMinutes, Libre3SensorLifecycle.defaultWarmupDurationMinutes)
        XCTAssertEqual(Libre3DataPlaneState(sensorState: sensor, warmupDurationMinutes: 30).warmupDurationMinutes, 30)
        XCTAssertThrowsError(try Libre3SensorState(serialNumber: nil, blePIN: Data([1, 2])))
    }
}
