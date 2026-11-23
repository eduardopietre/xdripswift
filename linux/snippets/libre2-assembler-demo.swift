// Example snippet: exercises real app code from a plain script.
// Run: linux/xdrip-linux.sh snippet linux/snippets/libre2-assembler-demo.swift   (all suites)
import Foundation
@testable import xdrip

var assembler = Libre2FrameAssembler(expectedByteCount: 6)
let start = ContinuousClock.now

for (i, chunk) in [Data([0, 1]), Data([2, 3]), Data([4, 5])].enumerated() {
    let result = assembler.append(chunk, arrival: start.advanced(by: .milliseconds(100 * i)))
    print("chunk \(i): \(result.frameResult)")
}

let auth = AuthRequestTxMessage(slot: .medicalDevice)
print("G6 auth request:", auth.data.map { String(format: "%02x", $0) }.joined(separator: " "))
