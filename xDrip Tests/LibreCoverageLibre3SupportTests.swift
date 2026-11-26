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

    func testPhoneCertificateRejectsWrongSizeAndCompressedPoint() {
        XCTAssertThrowsError(try Libre3PhoneCert(raw: Data(count: 161))) { XCTAssertEqual($0 as? Libre3PhoneCertError, .wrongSize(161)) }
        var raw = Data(repeating: 0, count: 162)
        XCTAssertThrowsError(try Libre3PhoneCert(raw: raw)) { XCTAssertEqual($0 as? Libre3PhoneCertError, .notUncompressedPoint) }
        raw[33] = 0x04
        XCTAssertEqual(try Libre3PhoneCert(raw: raw).staticPub.count, 65)
    }

    // MARK: - Libre3IdentityStore with Keychain

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

    // MARK: - errors and NFC

    // MARK: - clinical and historical records

    private func words(_ values: [UInt16]) -> Data {
        Data(values.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    }

    func testHistoricalPageSpacesSamplesFiveMinutesApart() throws {
        let page = try Libre3HistoricalReadingPage(plaintext: words([700, 100, 0, 600, 38, 501, 1000]))
        XCTAssertEqual(page.startLifeCount, 700)
        XCTAssertEqual(page.endLifeCount, 725)
        XCTAssertEqual(page.samples.map(\.lifeCount), [700, 705, 710, 715, 720, 725])
        XCTAssertEqual(page.samples.map(\.glucoseMgDL), [100, nil, 501, 39, 501, nil])
    }

    // MARK: - data plane state

}
