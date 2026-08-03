import Foundation

/// A minimal test harness.
///
/// XCTest ships inside Xcode, not the Command Line Tools, so `swift test` can't
/// run on a machine that only has the CLT — which is the situation this project
/// is explicitly built for. This gives the same assertions with no dependency
/// beyond Foundation, runnable as `swift run castr-selftest`.
enum Check {
    static var passed = 0
    static var failed = 0
    private static var currentTest = ""

    static func begin(_ name: String) {
        currentTest = name
    }

    static func fail(_ message: String, line: Int) {
        failed += 1
        print("  ✗ \(currentTest):\(line)  \(message)")
    }

    static func ok() {
        passed += 1
    }

    static func isTrue(_ condition: Bool, _ message: String, line: Int = #line) {
        condition ? ok() : fail(message, line: line)
    }

    static func isFalse(_ condition: Bool, _ message: String, line: Int = #line) {
        isTrue(!condition, message, line: line)
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T,
                                    _ message: String = "", line: Int = #line) {
        if actual == expected {
            ok()
        } else {
            fail("\(message.isEmpty ? "" : message + ": ")expected \(expected), got \(actual)",
                 line: line)
        }
    }

    static func close(_ actual: Double, _ expected: Double, _ tolerance: Double,
                      _ message: String = "", line: Int = #line) {
        if abs(actual - expected) <= tolerance {
            ok()
        } else {
            fail("\(message.isEmpty ? "" : message + ": ")expected \(expected) "
                 + "±\(tolerance), got \(actual)", line: line)
        }
    }

    static func lessThan(_ actual: Int, _ limit: Int,
                         _ message: String = "", line: Int = #line) {
        if actual < limit {
            ok()
        } else {
            fail("\(message.isEmpty ? "" : message + ": ")expected < \(limit), got \(actual)",
                 line: line)
        }
    }

    static func atLeast(_ actual: Int, _ minimum: Int,
                        _ message: String = "", line: Int = #line) {
        if actual >= minimum {
            ok()
        } else {
            fail("\(message.isEmpty ? "" : message + ": ")expected >= \(minimum), got \(actual)",
                 line: line)
        }
    }

    static func notNil<T>(_ value: T?, _ message: String = "", line: Int = #line) -> T? {
        if value == nil { fail("\(message) was nil", line: line) } else { ok() }
        return value
    }
}

/// Runs a named test, reporting per-test status.
func test(_ name: String, _ body: () throws -> Void) {
    Check.begin(name)
    let before = Check.failed
    do {
        try body()
    } catch {
        Check.fail("threw \(error)", line: 0)
    }
    if Check.failed == before {
        print("  ✓ \(name)")
    }
}
