//
//  Libre3PairingMessagesTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the wire formats of the two encrypted pairing messages: the phase 5 challenge
/// (phone -> sensor, 36-byte ciphertext + 4-byte CCM tag, zero-padded to 54 bytes) and the
/// phase 6 response (sensor -> phone, 56-byte ciphertext + tag + 7-byte nonce).
///
/// The expected ciphertexts and tags are independent AES-CCM (M=4, L=8) vectors computed
/// with Python's `cryptography` package, so they check the app against a reference
/// implementation rather than against itself. Size validation matters because the sensor
/// silently drops malformed writes and the pairing then just times out.
/// `Libre3Phase6ResponseTests` encrypts with the app's own code; these vectors are independent.
final class Libre3PairingMessagesTests: XCTestCase {

    // MARK: - fixtures

    private let phase5Key = Data((0x10...0x1f).map { UInt8($0) })
    private let phase5Nonce = Data([0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6])
    private let phase5Plaintext = Data((0..<36).map { UInt8($0) })
    private let phase5CiphertextHex = "2d0c4563be5cda82bbfeb22df3a0b2eb43bae8586bacfbfb53aa6d304b2aa0c8bad71be9"
    private let phase5TagHex = "c9552ce0"

    private let phase6Key = Data(repeating: 0x42, count: 16)
    private let phase6Nonce = Data(repeating: 0x05, count: 7)
    private let phase6CiphertextHex =
        "81d70ac3650e99d88d7a9244d03cf4482bf9647cb0e149f1ec7218eb7b025e434fc80e5b4de765db01420acd2c16af18e94ce5e1f0a23515"
    private let phase6TagHex = "2702712c"
    /// Tag of the same plaintext authenticated with AAD `aa bb`.
    private let phase6TagWithAADHex = "1d3856bb"

    private func data(_ hex: String) -> Data {
        Libre3ProtocolFixtures.data(hex: hex)
    }

    private func phase6Wire(tagHex: String? = nil) -> Data {
        data(phase6CiphertextHex) + data(tagHex ?? phase6TagHex) + phase6Nonce
    }

    // MARK: - phase 5 challenge

    func testPhase5EncryptMatchesReferenceVectorAndPadsWireToFiftyFourBytes() throws {
        let challenge = try Libre3Phase5Challenge.encrypt(plaintext: phase5Plaintext, sessionKey: phase5Key, nonce: phase5Nonce)

        XCTAssertEqual(challenge.ciphertext.hex, phase5CiphertextHex)
        XCTAssertEqual(challenge.tag.hex, phase5TagHex)
        XCTAssertEqual(challenge.logicalBytes.hex, phase5CiphertextHex + phase5TagHex)
        XCTAssertEqual(challenge.wireBytes.count, 54)
        XCTAssertEqual(challenge.wireBytes.prefix(40), challenge.logicalBytes)
        XCTAssertEqual(challenge.wireBytes.suffix(14), Data(count: 14))
    }

    /// The sensor sends the 54-byte padded form, tests and logs use the 40-byte logical
    /// form; both decode to the same message, and the padding is ignored.
    func testPhase5DecodeAcceptsWireAndLogicalFormsAndRoundTrips() throws {
        let logical = data(phase5CiphertextHex + phase5TagHex)
        var wire = logical + Data(count: 14)
        let fromLogical = try Libre3Phase5Challenge.decode(logical)
        let fromWire = try Libre3Phase5Challenge.decode(wire)
        wire[50] = 0xff
        let fromDirtyPadding = try Libre3Phase5Challenge.decode(wire)

        XCTAssertEqual(fromLogical, fromWire)
        XCTAssertEqual(fromDirtyPadding, fromWire)
        XCTAssertEqual(try fromWire.decrypt(sessionKey: phase5Key, nonce: phase5Nonce), phase5Plaintext)
    }

    func testPhase5DecodeRejectsOtherSizes() {
        for size in [0, 36, 39, 41, 53, 55, 67] {
            XCTAssertThrowsError(try Libre3Phase5Challenge.decode(Data(count: size)), "size \(size)") { error in
                XCTAssertEqual(error as? Libre3ChallengeError, .wrongWireSize(size))
            }
        }
    }

    /// Key size is checked first, then plaintext, then nonce: each error names the
    /// offending size so a pairing log points at the right input.
    func testPhase5EncryptValidatesKeyPlaintextAndNonceSizes() {
        let cases: [(name: String, key: Data, plaintext: Data, nonce: Data, error: Libre3ChallengeError)] = [
            ("short key", Data(count: 15), phase5Plaintext, phase5Nonce, .wrongKeySize(15)),
            ("long key", Data(count: 32), phase5Plaintext, phase5Nonce, .wrongKeySize(32)),
            ("short plaintext", phase5Key, Data(count: 35), phase5Nonce, .wrongPlaintextSize(35)),
            ("long plaintext", phase5Key, Data(count: 37), phase5Nonce, .wrongPlaintextSize(37)),
            ("short nonce", phase5Key, phase5Plaintext, Data(count: 6), .wrongNonceSize(6)),
            ("13-byte nonce", phase5Key, phase5Plaintext, Data(count: 13), .wrongNonceSize(13)),
            ("bad key wins", Data(count: 1), Data(count: 1), Data(count: 1), .wrongKeySize(1)),
        ]
        for c in cases {
            XCTAssertThrowsError(try Libre3Phase5Challenge.encrypt(plaintext: c.plaintext, sessionKey: c.key, nonce: c.nonce), c.name) { error in
                XCTAssertEqual(error as? Libre3ChallengeError, c.error, c.name)
            }
        }
    }

    func testPhase5InitRejectsWrongCiphertextOrTagSize() {
        XCTAssertThrowsError(try Libre3Phase5Challenge(ciphertext: Data(count: 35), tag: Data(count: 4))) { error in
            XCTAssertEqual(error as? Libre3ChallengeError, .wrongCiphertextSize(35))
        }
        XCTAssertThrowsError(try Libre3Phase5Challenge(ciphertext: Data(count: 36), tag: Data(count: 8))) { error in
            XCTAssertEqual(error as? Libre3ChallengeError, .wrongTagSize(8))
        }
    }

    /// Decryption must authenticate: a flipped ciphertext bit, another nonce or another
    /// key all fail instead of returning garbage R1/R2 values.
    func testPhase5DecryptFailsAuthenticationOnAnyMismatch() throws {
        let challenge = try Libre3Phase5Challenge.encrypt(plaintext: phase5Plaintext, sessionKey: phase5Key, nonce: phase5Nonce)

        var tamperedBytes = challenge.logicalBytes
        tamperedBytes[0] ^= 0x01
        let tampered = try Libre3Phase5Challenge.decode(tamperedBytes)
        XCTAssertThrowsError(try tampered.decrypt(sessionKey: phase5Key, nonce: phase5Nonce))

        var otherNonce = phase5Nonce
        otherNonce[6] ^= 0x01
        XCTAssertThrowsError(try challenge.decrypt(sessionKey: phase5Key, nonce: otherNonce))
        XCTAssertThrowsError(try challenge.decrypt(sessionKey: Data(count: 16), nonce: phase5Nonce))
        XCTAssertThrowsError(try challenge.decrypt(sessionKey: phase5Key, nonce: phase5Nonce, aad: Data([0x01])))

        XCTAssertThrowsError(try challenge.decrypt(sessionKey: phase5Key, nonce: Data(count: 8))) { error in
            XCTAssertEqual(error as? Libre3ChallengeError, .wrongNonceSize(8))
        }
        XCTAssertThrowsError(try challenge.decrypt(sessionKey: Data(count: 17), nonce: phase5Nonce)) { error in
            XCTAssertEqual(error as? Libre3ChallengeError, .wrongKeySize(17))
        }
    }

    // MARK: - phase 6 response

    /// The 67-byte notify splits as ciphertext [0, 56), tag [56, 60), nonce [60, 67).
    func testPhase6DecodeSplitsWireIntoCiphertextTagAndNonce() throws {
        let wire = Data((0..<67).map { UInt8($0) })
        let response = try Libre3Phase6Response.decode(wire)

        XCTAssertEqual(response.ciphertext, Data((0..<56).map { UInt8($0) }))
        XCTAssertEqual(response.tag, Data([56, 57, 58, 59]))
        XCTAssertEqual(response.nonce, Data([60, 61, 62, 63, 64, 65, 66]))
    }

    func testPhase6DecodeRejectsOtherSizes() {
        for size in [0, 56, 60, 66, 68] {
            XCTAssertThrowsError(try Libre3Phase6Response.decode(Data(count: size)), "size \(size)") { error in
                XCTAssertEqual(error as? Libre3ChallengeError, .wrongWireSize(size))
            }
        }
    }

    func testPhase6InitValidatesEachPartSize() {
        XCTAssertThrowsError(try Libre3Phase6Response(ciphertext: Data(count: 55), tag: Data(count: 4), nonce: Data(count: 7))) { error in
            XCTAssertEqual(error as? Libre3Phase6ResponseError, .wrongCiphertextSize(55))
        }
        XCTAssertThrowsError(try Libre3Phase6Response(ciphertext: Data(count: 56), tag: Data(count: 5), nonce: Data(count: 7))) { error in
            XCTAssertEqual(error as? Libre3Phase6ResponseError, .wrongTagSize(5))
        }
        XCTAssertThrowsError(try Libre3Phase6Response(ciphertext: Data(count: 56), tag: Data(count: 4), nonce: Data(count: 13))) { error in
            XCTAssertEqual(error as? Libre3ChallengeError, .wrongNonceSize(13))
        }
    }

    /// The decrypted 56 bytes are R2 || R1 || kEnc || ivEnc8, in that order: swapping R1
    /// and R2 would still decrypt but break the session key derivation.
    func testPhase6DecryptsReferenceVectorIntoSessionMaterial() throws {
        let material = try Libre3Phase6Response.decode(phase6Wire()).decrypt(rawKey: phase6Key)

        XCTAssertEqual(material.phoneR2, Data(repeating: 1, count: 16))
        XCTAssertEqual(material.sensorR1, Data(repeating: 2, count: 16))
        XCTAssertEqual(material.kEnc, Data(repeating: 3, count: 16))
        XCTAssertEqual(material.ivEnc, Data(repeating: 4, count: 8))
    }

    /// AAD is part of the authentication: the tag computed with AAD verifies only when the
    /// same AAD is passed, and the plain tag fails with it.
    func testPhase6DecryptAuthenticatesAAD() throws {
        let aad = Data([0xaa, 0xbb])
        let withAAD = try Libre3Phase6Response.decode(phase6Wire(tagHex: phase6TagWithAADHex))

        XCTAssertEqual(try withAAD.decrypt(rawKey: phase6Key, aad: aad).kEnc, Data(repeating: 3, count: 16))
        XCTAssertThrowsError(try withAAD.decrypt(rawKey: phase6Key))
        XCTAssertThrowsError(try Libre3Phase6Response.decode(phase6Wire()).decrypt(rawKey: phase6Key, aad: aad))
    }

    func testPhase6DecryptRejectsWrongKeySizeAndTampering() throws {
        let response = try Libre3Phase6Response.decode(phase6Wire())
        for size in [0, 15, 17, 32] {
            XCTAssertThrowsError(try response.decrypt(rawKey: Data(count: size)), "size \(size)") { error in
                XCTAssertEqual(error as? Libre3ChallengeError, .wrongKeySize(size))
            }
        }

        var wrongNonce = phase6Wire()
        wrongNonce[66] ^= 0x80
        XCTAssertThrowsError(try Libre3Phase6Response.decode(wrongNonce).decrypt(rawKey: phase6Key))

        var wrongTag = phase6Wire()
        wrongTag[59] ^= 0x01
        XCTAssertThrowsError(try Libre3Phase6Response.decode(wrongTag).decrypt(rawKey: phase6Key))
    }

    func testPhase6SessionMaterialValidatesEachPartSize() {
        let r = Data(count: 16)
        let iv = Data(count: 8)
        let cases: [(name: String, r2: Data, r1: Data, kEnc: Data, ivEnc: Data, error: Libre3Phase6ResponseError)] = [
            ("R2", Data(count: 15), r, r, iv, .wrongR2Size(15)),
            ("R1", r, Data(count: 17), r, iv, .wrongR1Size(17)),
            ("kEnc", r, r, Data(count: 8), iv, .wrongKEncSize(8)),
            ("ivEnc", r, r, r, Data(count: 16), .wrongIVEncSize(16)),
        ]
        for c in cases {
            XCTAssertThrowsError(try Libre3Phase6SessionMaterial(phoneR2: c.r2, sensorR1: c.r1, kEnc: c.kEnc, ivEnc: c.ivEnc), c.name) { error in
                XCTAssertEqual(error as? Libre3Phase6ResponseError, c.error, c.name)
            }
        }
        XCTAssertNoThrow(try Libre3Phase6SessionMaterial(phoneR2: r, sensorR1: r, kEnc: r, ivEnc: iv))
    }
}
