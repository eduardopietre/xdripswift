//
//  DexcomCoverageG7AuthTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreBluetooth
import CryptoKit
import XCTest
@testable import xdrip

final class DexcomCoverageG7AuthTests: XCTestCase {
    private let transmitterID = "DXCMCOV1"
    private let sharedKey = Data((0..<16).map { UInt8($0) })
    private let partALength = 494
    private let partBLength = 465

    override func setUp() {
        super.setUp()
        DexcomG7AuthBridge.clearPersistedSharedKeys(forTransmitterID: transmitterID)
    }

    override func tearDown() {
        DexcomG7AuthBridge.clearPersistedSharedKeys(forTransmitterID: transmitterID)
        super.tearDown()
    }

    // MARK: - Static decision helpers

    func testAuthenticationStatusActionTruthTable() {
        typealias Session = DexcomG7AuthSession
        XCTAssertEqual(Session.authenticationStatusAction(usingFullBootstrap: true, authenticated: true, paired: false), .continueAuthentication)
        XCTAssertEqual(Session.authenticationStatusAction(usingFullBootstrap: true, authenticated: false, paired: true), .reject)
        XCTAssertEqual(Session.authenticationStatusAction(usingFullBootstrap: false, authenticated: true, paired: true), .continueAuthentication)
        XCTAssertEqual(Session.authenticationStatusAction(usingFullBootstrap: false, authenticated: true, paired: false), .startFullBootstrap)
        XCTAssertEqual(Session.authenticationStatusAction(usingFullBootstrap: false, authenticated: false, paired: true), .rejectPersistedKey)
        XCTAssertEqual(Session.authenticationStatusAction(usingFullBootstrap: false, authenticated: false, paired: false), .rejectPersistedKey)
    }

    func testOwnershipKeepAliveActionRecognisesOnlyExactResponses() {
        XCTAssertEqual(DexcomG7AuthSession.ownershipKeepAliveAction(for: Data([0x06, 0x01])), .completeOwnership)
        XCTAssertEqual(DexcomG7AuthSession.ownershipKeepAliveAction(for: Data([0x06, 0x00])), .requestLegacyBond)
        XCTAssertEqual(DexcomG7AuthSession.ownershipKeepAliveAction(for: Data([0x06, 0x02])), .ignore)
        XCTAssertEqual(DexcomG7AuthSession.ownershipKeepAliveAction(for: Data([0x06, 0x01, 0x00])), .ignore)
        XCTAssertEqual(DexcomG7AuthSession.ownershipKeepAliveAction(for: Data()), .ignore)
    }

    // MARK: - Bridge

    func testAESCryptEncryptsECBBlockAndRejectsInvalidKey() throws {
        let doubled = Data([1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8])
        let encrypted = try AESCrypt.encryptData(doubled, usingKey: sharedKey)
        XCTAssertEqual(encrypted.prefix(16), Data(hex: "8610e13d3226a4b578107eaaaea9f730"))
        XCTAssertThrowsError(try AESCrypt.encryptData(doubled, usingKey: Data([1, 2, 3])))
    }

    func testBridgeWithoutKeyOrPairingCodeCannotStart() {
        let bridge = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: nil, authenticationSlot: 2)
        XCTAssertThrowsError(try bridge.initialControlPacket()) { error in
            XCTAssertEqual((error as NSError).code, 7)
        }
    }

    func testBridgeWithPairingCodeStartsFullBootstrap() throws {
        let bridge = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: "1234", authenticationSlot: 2)
        XCTAssertEqual(try bridge.initialControlPacket(), Data([0x0A, 0x00]))
        let anonymous = DexcomG7AuthBridge(transmitterID: nil, pairingCode: "1234", authenticationSlot: 2)
        XCTAssertEqual(try anonymous.initialControlPacket(), Data([0x0A, 0x00]))
    }

    func testBridgeRestoresPersistedKeyForSlotTwoAndBuildsAuthRequest() throws {
        persistKey(slotSuffix: nil)
        let bridge = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: nil, authenticationSlot: 2)
        let packet = try bridge.initialControlPacket()
        XCTAssertEqual(packet.count, 10)
        XCTAssertEqual(packet.first, 0x02)
        XCTAssertEqual(packet.last, 0x02)
    }

    func testBridgeSlotSpecificKeysAreIsolated() throws {
        persistKey(slotSuffix: ".01")
        let medical = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: "1234", authenticationSlot: 1)
        XCTAssertEqual(try medical.initialControlPacket().last, 0x01)
        XCTAssertEqual(try medical.initialControlPacket().count, 10)
        let mobile = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: "1234", authenticationSlot: 2)
        XCTAssertEqual(try mobile.initialControlPacket(), Data([0x0A, 0x00]))
        mobile.authenticationSlot = 1
        XCTAssertEqual(try mobile.initialControlPacket().first, 0x02)
        mobile.authenticationSlot = 3
        XCTAssertEqual(try mobile.initialControlPacket(), Data([0x0A, 0x00]))
    }

    func testBridgeChallengeResponseUsesPersistedKey() throws {
        persistKey(slotSuffix: nil)
        let bridge = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: nil, authenticationSlot: 2)
        _ = try bridge.initialControlPacket()
        let response = try bridge.authChallengeResponse(forTokenHash: Data(repeating: 0, count: 8), challenge: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(response, Data([0x04]) + Data(hex: "8610e13d3226a4b5"))
        XCTAssertEqual(bridge.lastResolvedAuthKeyLabel, "persisted short-auth sharedKey")
        bridge.resetSession()
        XCTAssertEqual(bridge.lastResolvedAuthKeyLabel, "unresolved")
    }

    func testBridgeChallengeResponseErrors() {
        let bridge = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: "1234", authenticationSlot: 2)
        XCTAssertThrowsError(try bridge.authChallengeResponse(forTokenHash: Data(), challenge: Data([1, 2, 3]))) { error in
            XCTAssertEqual((error as NSError).code, 2)
            XCTAssertEqual((error as NSError).domain, "DexcomG7AuthBridgeErrorDomain")
        }
        XCTAssertThrowsError(try bridge.authChallengeResponse(forTokenHash: Data(), challenge: Data(repeating: 1, count: 8))) { error in
            XCTAssertEqual((error as NSError).code, 10)
        }
    }

    func testBridgeClearSharedKeyRemovesPersistedValue() throws {
        persistKey(slotSuffix: nil)
        let bridge = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: "1234", authenticationSlot: 2)
        bridge.clearSharedKey()
        XCTAssertNil(UserDefaults.standard.data(forKey: defaultsKey(nil)))
        XCTAssertEqual(try bridge.initialControlPacket(), Data([0x0A, 0x00]))
        bridge.confirmSharedKey()
        XCTAssertNil(UserDefaults.standard.data(forKey: defaultsKey(nil)))
    }

    func testClearPersistedSharedKeysRemovesLegacyAndEverySlot() {
        for suffix in [nil, ".01", ".02", ".03"] {
            persistKey(slotSuffix: suffix)
        }
        DexcomG7AuthBridge.clearPersistedSharedKeys(forTransmitterID: transmitterID)
        for suffix in [nil, ".01", ".02", ".03"] {
            XCTAssertNil(UserDefaults.standard.data(forKey: defaultsKey(suffix)))
        }
        DexcomG7AuthBridge.clearPersistedSharedKeys(forTransmitterID: "")
    }

    func testBridgeIgnoresStoredKeyOfWrongLength() throws {
        UserDefaults.standard.set(Data(repeating: 1, count: 15), forKey: defaultsKey(nil))
        let bridge = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: "1234", authenticationSlot: 2)
        XCTAssertEqual(try bridge.initialControlPacket(), Data([0x0A, 0x00]))
    }

    func testBridgeCertificateRequestsUseLittleEndianLengths() throws {
        let bridge = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: "1234", authenticationSlot: 2)
        XCTAssertEqual(try bridge.certificateRequest(forPhase: 0), Data([0x0B, 0x00, 0xEE, 0x01, 0x00, 0x00]))
        XCTAssertEqual(try bridge.certificateRequest(forPhase: 1), Data([0x0B, 0x01, 0xD1, 0x01, 0x00, 0x00]))
        XCTAssertEqual(try bridge.certificateRequest(forPhase: 2), Data([0x0B, 0x02, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertThrowsError(try bridge.certificateRequest(forPhase: 3)) { XCTAssertEqual(($0 as NSError).code, 4) }
    }

    func testBridgeCertificateStreamPacketsAreTwentyByteDERChunks() throws {
        let bridge = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: "1234", authenticationSlot: 2)
        let partA = try bridge.certificateStreamPackets(forPhase: 0)
        XCTAssertEqual(partA.count, 25)
        XCTAssertTrue(partA.dropLast().allSatisfy { $0.count == 20 })
        XCTAssertEqual(partA.last?.count, 14)
        let joined = partA.reduce(Data(), +)
        XCTAssertEqual(joined.count, partALength)
        XCTAssertEqual(Array(joined.prefix(4)), [0x30, 0x82, 0x01, 0xEA])
        let partB = try bridge.certificateStreamPackets(forPhase: 1).reduce(Data(), +)
        XCTAssertEqual(partB.count, partBLength)
        XCTAssertTrue(try bridge.certificateStreamPackets(forPhase: 2).isEmpty)
        XCTAssertThrowsError(try bridge.certificateStreamPackets(forPhase: 4))
    }

    func testBridgeProofChallengeRequestIsRandomSeventeenBytes() {
        let bridge = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: "1234", authenticationSlot: 2)
        let first = bridge.makeProofOfPossessionChallengeRequest()
        let second = bridge.makeProofOfPossessionChallengeRequest()
        XCTAssertEqual(first.count, 17)
        XCTAssertEqual(first.first, 0x0C)
        XCTAssertNotEqual(first, second)
    }

    func testBridgeProofSignatureVerifiesAgainstClientCertificateKey() throws {
        let bridge = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: "1234", authenticationSlot: 2)
        let challenge = Data((0..<16).map { UInt8($0 * 3) })
        let signature = try bridge.proofOfPossessionResponse(forChallenge: challenge)
        XCTAssertEqual(signature.count, 64)
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(hex: "007CFBD596F6E74477B8C0E9F6F7A174275E101EF6BF7D18CAF01181D127B579"))
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        XCTAssertTrue(key.publicKey.isValidSignature(ecdsa, for: SHA256.hash(data: challenge)))
        XCTAssertThrowsError(try bridge.proofOfPossessionResponse(forChallenge: Data(repeating: 0, count: 15))) { XCTAssertEqual(($0 as NSError).code, 2) }
    }

    func testBridgePakePayloadValidationErrors() throws {
        let noCode = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: nil, authenticationSlot: 2)
        var packets: NSArray?
        XCTAssertThrowsError(try noCode.handlePakePayload(forPhase: 0, payload: Data(count: 160), streamPackets: &packets)) { XCTAssertEqual(($0 as NSError).code, 7) }
        let bridge = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: "1234", authenticationSlot: 2)
        XCTAssertThrowsError(try bridge.handlePakePayload(forPhase: 0, payload: Data(count: 159), streamPackets: &packets)) { XCTAssertEqual(($0 as NSError).code, 8) }
        XCTAssertThrowsError(try bridge.handlePakePayload(forPhase: 0, payload: Data(count: 160), streamPackets: &packets)) { XCTAssertEqual(($0 as NSError).code, 9) }
        XCTAssertNil(packets)
    }

    func testBridgePakePayloadWithValidPointsRejectsBadProofAndUnknownPhase() throws {
        let bridge = DexcomG7AuthBridge(transmitterID: transmitterID, pairingCode: "1234", authenticationSlot: 2)
        let payload = P256.Signing.PrivateKey().publicKey.rawRepresentation + P256.Signing.PrivateKey().publicKey.rawRepresentation + Data(repeating: 7, count: 32)
        XCTAssertEqual(payload.count, 160)
        var packets: NSArray?
        XCTAssertThrowsError(try bridge.handlePakePayload(forPhase: 0, payload: payload, streamPackets: &packets)) { XCTAssertEqual(($0 as NSError).code, 9) }
        XCTAssertThrowsError(try bridge.handlePakePayload(forPhase: 1, payload: payload, streamPackets: &packets)) { XCTAssertEqual(($0 as NSError).code, 9) }
        XCTAssertThrowsError(try bridge.handlePakePayload(forPhase: 7, payload: payload + Data([1]), streamPackets: &packets)) { XCTAssertEqual(($0 as NSError).code, 3) }
    }

    // MARK: - Session notification ordering

    func testConfigureEnablesAuthStreamBeforeReceiveAuthentication() {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.session.configure(receiveAuthentication: fixture.control, authStream: fixture.stream)
        XCTAssertEqual(fixture.transport.notifyRequests, [fixture.stream.uuid])
        fixture.stream.notifying = true
        fixture.session.notificationStateUpdated(for: fixture.stream)
        XCTAssertEqual(fixture.transport.notifyRequests, [fixture.stream.uuid, fixture.control.uuid])
        XCTAssertTrue(fixture.transport.writes.isEmpty)
        fixture.control.notifying = true
        fixture.session.notificationStateUpdated(for: fixture.control)
        XCTAssertEqual(fixture.transport.writes.map(\.data), [Data([0x0A, 0x00])])
        XCTAssertEqual(fixture.transport.writes.first?.type, .withResponse)
        XCTAssertEqual(fixture.transport.progress, ["G7 full ownership exchange started"])
        fixture.session.notificationStateUpdated(for: fixture.control)
        XCTAssertEqual(fixture.transport.writes.count, 1)
    }

    func testAlreadyNotifyingCharacteristicsStartImmediately() {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.startReady()
        XCTAssertTrue(fixture.transport.notifyRequests.isEmpty)
        XCTAssertEqual(fixture.transport.writes.map(\.data), [Data([0x0A, 0x00])])
    }

    func testNotificationDisabledDoesNotStartAuthentication() {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.session.configure(receiveAuthentication: fixture.control, authStream: fixture.stream)
        fixture.session.notificationStateUpdated(for: fixture.stream)
        fixture.session.notificationStateUpdated(for: fixture.control)
        fixture.session.notificationStateUpdated(for: DexcomCoverageFakeCharacteristic(uuid: "F8083533-849E-531C-C594-30F1F86A4EA5", notifying: true))
        XCTAssertEqual(fixture.transport.notifyRequests.count, 1)
        XCTAssertTrue(fixture.transport.writes.isEmpty)
    }

    func testMissingPairingCodeAndKeyFailsInitialPacket() {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: nil)
        fixture.startReady()
        XCTAssertTrue(fixture.transport.writes.isEmpty)
        XCTAssertEqual(fixture.transport.failures.count, 1)
        XCTAssertTrue(fixture.transport.failures[0].hasPrefix("could not create the initial authentication packet"))
    }

    // MARK: - Session short authentication

    func testShortAuthenticationAnswersChallengeOnceAndCompletes() {
        persistKey(slotSuffix: nil)
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: nil)
        fixture.startReady()
        XCTAssertEqual(fixture.transport.progress, ["G7 saved-key authentication started"])
        XCTAssertEqual(fixture.transport.writes.first?.data.count, 10)
        let request = Data([0x03]) + Data(repeating: 0xAB, count: 8) + Data([1, 2, 3, 4, 5, 6, 7, 8])
        fixture.session.receiveAuthentication(request)
        fixture.session.receiveAuthentication(request)
        XCTAssertEqual(fixture.transport.writes.count, 2)
        XCTAssertEqual(fixture.transport.writes.last?.data, Data([0x04]) + Data(hex: "8610e13d3226a4b5"))
        fixture.session.receiveAuthentication(Data([0x05, 0x01, 0x01]))
        XCTAssertEqual(fixture.transport.authenticatedCount, 1)
        XCTAssertTrue(fixture.transport.failures.isEmpty)
    }

    func testShortAuthenticationRejectedKeyStopsWithoutClearingIt() {
        persistKey(slotSuffix: nil)
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.startReady()
        fixture.session.receiveAuthentication(Data([0x05, 0x00, 0x01]))
        XCTAssertEqual(fixture.transport.rejectedKeyCount, 1)
        XCTAssertEqual(fixture.transport.authenticatedCount, 0)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: defaultsKey(nil)))
    }

    func testShortAuthenticationUnpairedClearsKeyAndRequestsReconnect() {
        persistKey(slotSuffix: nil)
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.startReady()
        fixture.session.receiveAuthentication(Data([0x05, 0x01, 0x02]))
        XCTAssertEqual(fixture.transport.cleanReconnectCount, 1)
        XCTAssertNil(UserDefaults.standard.data(forKey: defaultsKey(nil)))
    }

    func testMalformedStatusAndUnknownPacketsAreHandledSafely() {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.startReady()
        fixture.session.receiveAuthentication(Data())
        fixture.session.receiveAuthentication(Data([0xEE, 0x01]))
        XCTAssertTrue(fixture.transport.failures.isEmpty)
        fixture.session.receiveAuthentication(Data([0x05, 0x01]))
        XCTAssertEqual(fixture.transport.failures, ["could not parse authentication status"])
        fixture.session.receiveAuthentication(Data([0x22, 0x00]))
        XCTAssertEqual(fixture.transport.failures.count, 1)
    }

    func testChallengeWithoutKeyReportsFailure() {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.startReady()
        fixture.session.receiveAuthentication(Data([0x03]) + Data(repeating: 1, count: 16))
        XCTAssertEqual(fixture.transport.failures.count, 1)
        XCTAssertTrue(fixture.transport.failures[0].hasPrefix("could not create the challenge response"))
    }

    // MARK: - Session full ownership

    func testFullBootstrapRejectionClearsKeyAndFails() {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.startReady()
        fixture.session.receiveAuthentication(Data([0x05, 0x00, 0x01]))
        XCTAssertEqual(fixture.transport.failures, ["authentication was rejected"])
        XCTAssertEqual(fixture.transport.rejectedKeyCount, 0)
    }

    func testPakeControlRejectionAndInvalidPayloadFail() {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.startReady()
        fixture.session.receiveAuthentication(Data([0x0A, 0x01, 0x00]))
        XCTAssertEqual(fixture.transport.failures, ["transmitter rejected J-PAKE"])
        fixture.session.receiveAuthStream(Data(count: 100))
        fixture.session.receiveAuthentication(Data([0x0A, 0x00, 0x00]))
        XCTAssertEqual(fixture.transport.failures.count, 1)
        fixture.session.receiveAuthStream(Data(count: 60))
        XCTAssertEqual(fixture.transport.failures.count, 2)
        XCTAssertTrue(fixture.transport.failures[1].hasPrefix("J-PAKE phase 0 failed"))
    }

    func testAuthStreamIsIgnoredBeforeAuthenticationStarts() {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.session.receiveAuthStream(Data(count: 200))
        fixture.session.receiveAuthentication(Data([0x0D, 0x00]))
        fixture.session.receiveAuthentication(Data([0x06, 0x01]))
        fixture.session.receiveAuthentication(Data([0x07, 0x00]))
        fixture.session.receiveAuthentication(Data([0x08, 0x01]))
        XCTAssertTrue(fixture.transport.writes.isEmpty)
        XCTAssertEqual(fixture.transport.authenticatedCount, 0)
    }

    func testCertificateExchangeProofAndOwnershipCompletion() throws {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        try fixture.runToProofOfPossession(test: self)
        fixture.session.receiveAuthentication(Data([0x0D, 0x00]))
        XCTAssertEqual(fixture.transport.writes.last?.data, Data([0x06, 0x19]))
        fixture.session.receiveAuthentication(Data([0x06, 0x05]))
        XCTAssertEqual(fixture.transport.authenticatedCount, 0)
        fixture.session.receiveAuthentication(Data([0x06, 0x01]))
        XCTAssertEqual(fixture.transport.authenticatedCount, 1)
        XCTAssertTrue(fixture.transport.failures.isEmpty)
    }

    func testLegacyBondCompletionPath() throws {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        try fixture.runToProofOfPossession(test: self)
        fixture.session.receiveAuthentication(Data([0x0D, 0x00]))
        fixture.session.receiveAuthentication(Data([0x06, 0x00]))
        XCTAssertEqual(fixture.transport.writes.last?.data, Data([0x07]))
        XCTAssertEqual(fixture.transport.progress.last, "G7 ownership requested Bluetooth bonding")
        fixture.session.receiveAuthentication(Data([0x08, 0x01]))
        XCTAssertEqual(fixture.transport.authenticatedCount, 0)
        fixture.session.receiveAuthentication(Data([0x07, 0x01]))
        fixture.session.receiveAuthentication(Data([0x07, 0x00]))
        fixture.session.receiveAuthentication(Data([0x08, 0x00]))
        XCTAssertEqual(fixture.transport.authenticatedCount, 0)
        fixture.session.receiveAuthentication(Data([0x08, 0x01]))
        XCTAssertEqual(fixture.transport.authenticatedCount, 1)
    }

    func testCertificateExchangeWritesCertificatesInOrder() throws {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.startReady()
        fixture.session.receiveAuthentication(Data([0x05, 0x01, 0x01]))
        XCTAssertEqual(fixture.transport.writes.last?.data, Data([0x0B, 0x00, 0xEE, 0x01, 0x00, 0x00]))
        XCTAssertEqual(fixture.transport.progress.last, "G7 certificate exchange started")
        fixture.session.receiveAuthentication(Data([0x05, 0x01, 0x01]))
        XCTAssertEqual(fixture.transport.writes.count, 2)
        fixture.transport.writes.removeAll()
        fixture.session.receiveAuthStream(Data(count: 3))
        fixture.session.receiveAuthentication(Data([0x0B, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00]))
        XCTAssertTrue(fixture.transport.writes.isEmpty)
        fixture.session.receiveAuthStream(Data(count: 2))
        let streamWrites = fixture.transport.writes.filter { $0.type == .withoutResponse }
        XCTAssertEqual(streamWrites.count, 25)
        XCTAssertEqual(streamWrites.map(\.data).reduce(Data(), +).count, partALength)
        XCTAssertTrue(streamWrites.allSatisfy { $0.uuid == fixture.stream.uuid })
        XCTAssertEqual(fixture.transport.writes.last?.data, Data([0x0B, 0x01, 0xD1, 0x01, 0x00, 0x00]))
        XCTAssertEqual(fixture.transport.writes.last?.uuid, fixture.control.uuid)
        XCTAssertEqual(fixture.transport.scheduledDelays.last ?? 0, 0.04 * 26, accuracy: 0.0001)
    }

    func testCertificateStatusValidation() {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.startReady()
        fixture.session.receiveAuthentication(Data([0x0B, 0x00, 0x00, 0, 0, 0, 0]))
        XCTAssertEqual(fixture.transport.failures.last, "certificate exchange was rejected")
        fixture.session.receiveAuthentication(Data([0x05, 0x01, 0x01]))
        fixture.session.receiveAuthentication(Data([0x0B, 0x00, 0x01, 0, 0, 0, 0]))
        XCTAssertEqual(fixture.transport.failures.last, "certificate phase was out of order")
        fixture.session.receiveAuthentication(Data([0x0B, 0x00, 0x00, 0x01, 0x10, 0, 0]))
        XCTAssertEqual(fixture.transport.failures.last, "certificate payload size was invalid")
        fixture.session.receiveAuthentication(Data([0x0B, 0x01, 0x00, 0, 0, 0, 0]))
        XCTAssertEqual(fixture.transport.failures.last, "certificate exchange was rejected")
        fixture.session.receiveAuthentication(Data([0x0B, 0x00, 0x00, 0, 0]))
        XCTAssertEqual(fixture.transport.failures.count, 5)
    }

    func testFinalCertificatePhaseMustBeEmpty() {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.startReady()
        fixture.session.receiveAuthentication(Data([0x05, 0x01, 0x01]))
        fixture.session.receiveAuthentication(Data([0x0B, 0x00, 0x00, 0, 0, 0, 0]))
        fixture.session.receiveAuthentication(Data([0x0B, 0x00, 0x01, 0, 0, 0, 0]))
        fixture.session.receiveAuthentication(Data([0x0B, 0x00, 0x02, 1, 0, 0, 0]))
        XCTAssertEqual(fixture.transport.failures, ["certificate payload size was invalid"])
    }

    func testProofStatusValidation() {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.startReady()
        fixture.session.receiveAuthentication(Data([0x0C, 0x00]) + Data(count: 16))
        XCTAssertEqual(fixture.transport.failures.last, "proof-of-possession request was invalid")
        fixture.session.receiveAuthentication(Data([0x05, 0x01, 0x01]))
        fixture.session.receiveAuthentication(Data([0x0C, 0x00]) + Data(count: 15))
        fixture.session.receiveAuthentication(Data([0x0C, 0x01]) + Data(count: 16))
        XCTAssertEqual(fixture.transport.failures.count, 3)
    }

    func testResetForConnectionCancelsDelayedWrites() {
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        fixture.transport.runScheduledImmediately = false
        fixture.startReady()
        fixture.session.receiveAuthentication(Data([0x05, 0x01, 0x01]))
        fixture.session.receiveAuthentication(Data([0x0B, 0x00, 0x00, 0, 0, 0, 0]))
        XCTAssertEqual(fixture.transport.pendingActions.count, 26)
        let before = fixture.transport.writes.count
        fixture.session.resetForConnection()
        fixture.transport.pendingActions.forEach { $0() }
        XCTAssertEqual(fixture.transport.writes.count, before)
    }

    func testSlotAndPairingCodeChangesResetSessionAndClearKey() {
        persistKey(slotSuffix: nil)
        let fixture = Fixture(transmitterID: transmitterID, pairingCode: "1234")
        XCTAssertEqual(fixture.session.bluetoothSlot, .mobileApp)
        fixture.session.updateBluetoothSlot(.mobileApp)
        fixture.session.updateBluetoothSlot(.smartWatch)
        XCTAssertEqual(fixture.session.bluetoothSlot, .smartWatch)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: defaultsKey(nil)))
        fixture.session.updateBluetoothSlot(.mobileApp)
        fixture.session.updatePairingCode("5678")
        XCTAssertNil(UserDefaults.standard.data(forKey: defaultsKey(nil)))
        persistKey(slotSuffix: nil)
        fixture.session.clearPersistedAuthentication()
        XCTAssertNil(UserDefaults.standard.data(forKey: defaultsKey(nil)))
    }

    func testUpdateTransmitterIDSelectsStoredKey() {
        persistKey(slotSuffix: nil)
        let fixture = Fixture(transmitterID: nil, pairingCode: "1234")
        fixture.session.updateTransmitterID(transmitterID)
        fixture.startReady()
        XCTAssertEqual(fixture.transport.writes.first?.data.count, 10)
    }

    // MARK: - Helpers

    private func defaultsKey(_ suffix: String?) -> String {
        "G7NativeAuthBridge.SharedKey." + transmitterID + (suffix ?? "")
    }

    private func persistKey(slotSuffix: String?) {
        UserDefaults.standard.set(sharedKey, forKey: defaultsKey(slotSuffix))
    }
}

final class DexcomCoverageFakeCharacteristic: CBMutableCharacteristic {
    var notifying: Bool
    var fakeValue: Data?

    override var isNotifying: Bool { notifying }
    override var value: Data? {
        get { fakeValue }
        set { fakeValue = newValue }
    }

    init(uuid: String, notifying: Bool = false, value: Data? = nil) {
        self.notifying = notifying
        super.init(type: CBUUID(string: uuid), properties: [.notify, .write, .writeWithoutResponse, .read], value: nil, permissions: [.writeable])
        fakeValue = value
    }
}

private final class FakeAuthTransport: DexcomG7AuthSessionTransport {
    struct Write { let data: Data; let uuid: CBUUID; let type: CBCharacteristicWriteType }
    var notifyRequests = [CBUUID]()
    var writes = [Write]()
    var authenticatedCount = 0
    var rejectedKeyCount = 0
    var cleanReconnectCount = 0
    var failures = [String]()
    var progress = [String]()
    var scheduledDelays = [TimeInterval]()
    var runScheduledImmediately = true
    var pendingActions = [() -> Void]()

    func authSessionSetNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        notifyRequests.append(characteristic.uuid)
    }

    func authSessionWrite(_ data: Data, to characteristic: CBCharacteristic, type: CBCharacteristicWriteType) -> Bool {
        writes.append(Write(data: data, uuid: characteristic.uuid, type: type))
        return true
    }

    func authSessionDidAuthenticate() { authenticatedCount += 1 }
    func authSessionDidRejectPersistedKey() { rejectedKeyCount += 1 }
    func authSessionRequiresCleanReconnect() { cleanReconnectCount += 1 }
    func authSessionDidFail(_ message: String) { failures.append(message) }
    func authSessionDidProgress(_ message: String) { progress.append(message) }

    func authSessionSchedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        scheduledDelays.append(delay)
        if runScheduledImmediately { action() } else { pendingActions.append(action) }
    }
}

private final class Fixture {
    let session: DexcomG7AuthSession
    let transport = FakeAuthTransport()
    let control = DexcomCoverageFakeCharacteristic(uuid: "F8083535-849E-531C-C594-30F1F86A4EA5")
    let stream = DexcomCoverageFakeCharacteristic(uuid: "F8083538-849E-531C-C594-30F1F86A4EA5")

    init(transmitterID: String?, pairingCode: String?) {
        session = DexcomG7AuthSession(transmitterID: transmitterID, pairingCode: pairingCode, bluetoothSlot: .mobileApp)
        session.transport = transport
    }

    func startReady() {
        control.notifying = true
        stream.notifying = true
        session.configure(receiveAuthentication: control, authStream: stream)
    }

    func runToProofOfPossession(test: XCTestCase) throws {
        startReady()
        session.receiveAuthentication(Data([0x05, 0x01, 0x01]))
        session.receiveAuthentication(Data([0x0B, 0x00, 0x00, 0, 0, 0, 0]))
        session.receiveAuthentication(Data([0x0B, 0x00, 0x01, 0, 0, 0, 0]))
        session.receiveAuthentication(Data([0x0B, 0x00, 0x02, 0, 0, 0, 0]))
        let challengeRequest = try XCTUnwrap(transport.writes.last)
        XCTAssertEqual(challengeRequest.data.count, 17)
        XCTAssertEqual(challengeRequest.data.first, 0x0C)
        let challenge = Data((0..<16).map { UInt8($0) })
        session.receiveAuthentication(Data([0x0C, 0x00]) + challenge)
        let countBefore = transport.writes.count
        session.receiveAuthStream(Data(count: 64))
        let proofWrites = transport.writes.suffix(from: countBefore)
        XCTAssertEqual(proofWrites.filter { $0.type == .withoutResponse }.map(\.data.count), [20, 20, 20, 4])
        XCTAssertEqual(proofWrites.last?.data, Data([0x0D, 0x00, 0x02]))
        XCTAssertEqual(transport.progress.last, "G7 ownership proof sent")
        XCTAssertTrue(transport.failures.isEmpty, "\(transport.failures)")
    }
}

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
