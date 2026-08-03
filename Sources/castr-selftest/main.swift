import Foundation
import CastrCore

let args = Array(CommandLine.arguments.dropFirst())

// `--emit-fixture <path> [samples]` writes a synthetic hex fixture that
// `castr-collect --replay` can consume. Keeps fixture generation next to the
// code that defines the wire format.
if let flagIndex = args.firstIndex(of: "--emit-fixture") {
    guard flagIndex + 1 < args.count else {
        print("usage: castr-selftest --emit-fixture <path> [sampleCount]")
        exit(2)
    }
    let path = args[flagIndex + 1]
    let sampleCount = flagIndex + 2 < args.count ? (Int(args[flagIndex + 2]) ?? 400) : 400

    let bytes = SyntheticSource.session(sampleCount: sampleCount)
    var text = "# Synthetic WT901BLE stream: \(sampleCount) frames of 0x55 0x61\n"
    text += "# Simulates a cast — at rest, one burst of acceleration, back to rest.\n"
    // One frame per line keeps the fixture legible and diffable.
    for start in stride(from: 0, to: bytes.count, by: FrameParser.frameLength) {
        let end = min(start + FrameParser.frameLength, bytes.count)
        text += SyntheticSource.hexString(Array(bytes[start..<end])) + "\n"
    }

    do {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        print("Wrote \(sampleCount) frames (\(bytes.count) bytes) to \(path)")
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

print("castr-selftest — parser and CSV checks, no hardware required\n")

runFrameParserTests()
print("")
runCSVTests()
print("")
runStaticCheckTests()
print("")
runSaturationTests()
print("")
runGlitchFilterTests()

print("")
if Check.failed == 0 {
    print("PASS — \(Check.passed) checks")
    exit(0)
} else {
    print("FAIL — \(Check.failed) failed, \(Check.passed) passed")
    exit(1)
}
