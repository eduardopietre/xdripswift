//
//  CommonCrypto.swift
//  xdrip Linux shim modules
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation

// Minimal stand-in for Apple's CommonCrypto, which does not exist on Linux.
//
// App files keep their `import CommonCrypto` and compile unchanged against this module. Only what
// the app uses is provided: one-shot `CCCrypt` with AES in ECB mode, encryption only. Anything else
// returns `kCCUnimplemented`, so a test relying on it fails loudly instead of passing by accident.
// The AES implementation follows FIPS-197 and is checked by the app's own AES-CCM test vectors.

public typealias CCCryptorStatus = Int32
public typealias CCOperation = UInt32
public typealias CCAlgorithm = UInt32
public typealias CCOptions = UInt32

public let kCCSuccess: CCCryptorStatus = 0
public let kCCParamError: CCCryptorStatus = -4300
public let kCCBufferTooSmall: CCCryptorStatus = -4301
public let kCCAlignmentError: CCCryptorStatus = -4303
public let kCCUnimplemented: CCCryptorStatus = -4305

public let kCCEncrypt = 0
public let kCCDecrypt = 1

public let kCCAlgorithmAES = 0
public let kCCAlgorithmAES128 = 0

public let kCCOptionPKCS7Padding = 1
public let kCCOptionECBMode = 2

public let kCCKeySizeAES128 = 16
public let kCCKeySizeAES192 = 24
public let kCCKeySizeAES256 = 32
public let kCCBlockSizeAES128 = 16

/// One-shot encryption with the same signature as CommonCrypto's `CCCrypt`.
public func CCCrypt(
    _ op: CCOperation,
    _ alg: CCAlgorithm,
    _ options: CCOptions,
    _ key: UnsafeRawPointer?,
    _ keyLength: Int,
    _ iv: UnsafeRawPointer?,
    _ dataIn: UnsafeRawPointer?,
    _ dataInLength: Int,
    _ dataOut: UnsafeMutableRawPointer?,
    _ dataOutAvailable: Int,
    _ dataOutMoved: UnsafeMutablePointer<Int>?
) -> CCCryptorStatus {
    guard op == CCOperation(kCCEncrypt),
          alg == CCAlgorithm(kCCAlgorithmAES),
          options == CCOptions(kCCOptionECBMode) else { return kCCUnimplemented }
    guard let key, [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(keyLength) else { return kCCParamError }
    guard dataInLength % kCCBlockSizeAES128 == 0 else { return kCCAlignmentError }
    guard dataOutAvailable >= dataInLength else { return kCCBufferTooSmall }
    guard dataInLength == 0 || (dataIn != nil && dataOut != nil) else { return kCCParamError }

    let aes = AESBlockCipher(key: [UInt8](UnsafeRawBufferPointer(start: key, count: keyLength)))
    if dataInLength > 0, let dataIn, let dataOut {
        let input = UnsafeRawBufferPointer(start: dataIn, count: dataInLength)
        for offset in stride(from: 0, to: dataInLength, by: kCCBlockSizeAES128) {
            let block = aes.encrypt(block: [UInt8](input[offset..<offset + kCCBlockSizeAES128]))
            (dataOut + offset).copyMemory(from: block, byteCount: block.count)
        }
    }
    dataOutMoved?.pointee = dataInLength
    return kCCSuccess
}

// MARK: - AES (FIPS-197), encryption only

private struct AESBlockCipher {
    private let roundKeys: [UInt8]
    private let rounds: Int

    init(key: [UInt8]) {
        let keyWords = key.count / 4
        rounds = keyWords + 6
        var expanded = key
        var roundConstant: UInt8 = 1
        while expanded.count < 16 * (rounds + 1) {
            var word = Array(expanded[(expanded.count - 4)...])
            let wordIndex = expanded.count / 4
            if wordIndex % keyWords == 0 {
                word = [word[1], word[2], word[3], word[0]].map { Self.sBox[Int($0)] }
                word[0] ^= roundConstant
                roundConstant = Self.xtime(roundConstant)
            } else if keyWords > 6 && wordIndex % keyWords == 4 {
                word = word.map { Self.sBox[Int($0)] }
            }
            let previous = expanded.count - 4 * keyWords
            for i in 0..<4 { expanded.append(expanded[previous + i] ^ word[i]) }
        }
        roundKeys = expanded
    }

    func encrypt(block: [UInt8]) -> [UInt8] {
        var state = block
        addRoundKey(&state, round: 0)
        for round in 1...rounds {
            state = state.map { Self.sBox[Int($0)] }
            // ShiftRows: the state is column-major, row r of column c is at index 4c + r.
            var shifted = state
            for row in 1..<4 {
                for column in 0..<4 { shifted[4 * column + row] = state[4 * ((column + row) % 4) + row] }
            }
            state = shifted
            if round != rounds {
                for column in 0..<4 {
                    let a = Array(state[(4 * column)..<(4 * column + 4)])
                    let all = a[0] ^ a[1] ^ a[2] ^ a[3]
                    for row in 0..<4 { state[4 * column + row] = a[row] ^ all ^ Self.xtime(a[row] ^ a[(row + 1) % 4]) }
                }
            }
            addRoundKey(&state, round: round)
        }
        return state
    }

    private func addRoundKey(_ state: inout [UInt8], round: Int) {
        for i in 0..<16 { state[i] ^= roundKeys[16 * round + i] }
    }

    private static func xtime(_ value: UInt8) -> UInt8 {
        (value << 1) ^ (value & 0x80 != 0 ? 0x1b : 0)
    }

    private static let sBox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]
}
