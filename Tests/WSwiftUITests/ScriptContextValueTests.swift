//
//  ScriptContextValueTests.swift
//  WSwiftUITests
//
//  Unit tests for the ScriptValue helpers used by the script-context slice.
//

import Foundation
import Testing
@testable import WSwiftUI

@Suite("Script context: ScriptValue helpers")
struct ScriptContextValueTests {

    @Test func jsonIsScriptSafeAndDecodesToTheSameValue() throws {
        let value = ["k'`": Hostile.payload]
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let safe = ScriptValue.json(encoded)
        for marker in ["'", "`", "<", ">", "&", Hostile.lineSeparator, Hostile.paragraphSeparator] {
            #expect(safe.contains(marker) == false, "\(marker.debugDescription) left in \(safe)")
        }
        #expect(try JSONDecoder().decode([String: String].self, from: Data(safe.utf8)) == value)
        #expect(ScriptValue.json("{\"a\":1}") == "{\"a\":1}")
    }

    @Test func looseKeepsTheLegacyTypeDispatch() throws {
        #expect(ScriptValue.loose("Saved") == "\"Saved\"")
        #expect(ScriptValue.loose(75) == "75")
        #expect(ScriptValue.loose(1.5) == "1.5")
        #expect(ScriptValue.loose(Double.nan) == "NaN")
        #expect(ScriptValue.loose(-Double.infinity) == "-Infinity")
        #expect(ScriptValue.loose(true) == "true")
        #expect(ScriptValue.loose(nil) == "\"\"")
        // anything else is its Swift description, as a (now safely encoded) string
        let described = ScriptValue.loose(["O'Brien", "</script>"])
        let decoded = try JSONDecoder().decode(String.self, from: Data(described.utf8))
        #expect(decoded == String(describing: ["O'Brien", "</script>"]))
        #expect(described.contains("<") == false && described.contains("'") == false)
    }

    @Test func millisecondsNeverTrapAndStayInTimerRange() {
        // ordinary values truncate exactly like the legacy Int(seconds * 1000)
        #expect(ScriptValue.milliseconds(fromSeconds: 1.5) == 1500)
        #expect(ScriptValue.milliseconds(fromSeconds: 0.0105) == 10)
        #expect(ScriptValue.milliseconds(fromSeconds: 0) == 0)
        #expect(ScriptValue.milliseconds(fromSeconds: 86_400) == 86_400_000)
        // timers treat negative delays as 0 anyway; NaN has no meaningful delay
        #expect(ScriptValue.milliseconds(fromSeconds: -1) == 0)
        #expect(ScriptValue.milliseconds(fromSeconds: -1e300) == 0)
        #expect(ScriptValue.milliseconds(fromSeconds: -.infinity) == 0)
        #expect(ScriptValue.milliseconds(fromSeconds: .nan) == 0)
        // "forever" waits as long as a timer can, instead of overflowing into "fire after ~1 ms"
        #expect(ScriptValue.maxTimerDelay == 2_147_483_647)
        #expect(ScriptValue.milliseconds(fromSeconds: .infinity) == ScriptValue.maxTimerDelay)
        #expect(ScriptValue.milliseconds(fromSeconds: 1e300) == ScriptValue.maxTimerDelay)
        #expect(ScriptValue.milliseconds(fromSeconds: 2_147_483.647) == ScriptValue.maxTimerDelay)
        #expect(ScriptValue.milliseconds(fromSeconds: 3_000_000) == ScriptValue.maxTimerDelay)
        #expect(ScriptValue.milliseconds(fromSeconds: 2_147_483.5) == 2_147_483_500)
    }

    /// Values whose JS `String(x)` differs from Swift's `description`, plus ordinary ones.
    static let numberTextCases: [(Double, String)] = [
        (0.00001, "0.00001"), (1e16, "10000000000000000"), (1e15, "1000000000000000"),
        (123456789012.5, "123456789012.5"), (3, "3"), (2.5, "2.5"), (-2.5, "-2.5"), (0, "0"), (-0.0, "0"),
        (0.1, "0.1"), (0.000001, "0.000001"), (1e-7, "1e-7"), (1.5e-7, "1.5e-7"), (1e20, "100000000000000000000"),
        (1e21, "1e+21"), (1.5e21, "1.5e+21"), (-1e21, "-1e+21"), (123e18, "123000000000000000000"),
        (Double.greatestFiniteMagnitude, "1.7976931348623157e+308"), (5e-324, "5e-324"),
        (9007199254740992, "9007199254740992"), (0.1 + 0.2, "0.30000000000000004"),
        (.nan, "NaN"), (.infinity, "Infinity"), (-.infinity, "-Infinity"),
    ]

    @Test func numberTextMatchesJavaScriptString() {
        for (value, expected) in Self.numberTextCases {
            #expect(ScriptValue.numberText(value) == expected, "String(\(value)) in JS is \(expected)")
        }
    }

    /// Cross-checks `numberText` against node's `String(x)` for the fixed cases, powers across the whole
    /// exponent range and a deterministic spread of random bit patterns.
    @Test(.enabled(if: NodeJS.isAvailable))
    func numberTextMatchesNode() throws {
        var values = Self.numberTextCases.map { $0.0 }
        var generator = SplitMix64(seed: 0x5EED)
        for _ in 0..<600 {
            let value = Double(bitPattern: generator.next())
            if value.isFinite { values.append(value) }
        }
        for exponent in -330...310 {
            values.append(Double("1.25e\(exponent)") ?? 0)
            values.append(Double("7e\(exponent)") ?? 0)
        }
        var literals: [String: String] = [:]
        for (index, value) in values.enumerated() {
            literals["v\(index)"] = "String(\(ScriptValue.number(value)))"
        }
        let result = try NodeJS.run(literals: literals)
        for (index, value) in values.enumerated() {
            let js = result.values["v\(index)"]?["str"] as? String
            #expect(js == ScriptValue.numberText(value),
                    "bits \(value.bitPattern): node \(js ?? "nil") vs \(ScriptValue.numberText(value))")
        }
    }

    @Test func operatorConditions() throws {
        #expect(Operator.equals("x").scriptSafeCondition == "== \"x\"")
        #expect(Operator.equals(3).scriptSafeCondition == "== 3")
        #expect(Operator.equals(true).scriptSafeCondition == "== true")
        #expect(Operator.isEmpty.scriptSafeCondition == "== ''")
        #expect(Operator.isNotEmpty.scriptSafeCondition == "!= ''")
        #expect(Operator.isNegative.scriptSafeCondition == "< 0")
        // the non-hostile operators are unchanged from javascriptCondition
        for op in [Operator.isEmpty, .isNotEmpty, .isTrue, .isFalse, .isZero, .isNonzero, .isPositive, .isNegative,
                   .equals(3), .equals(2.5), .equals(false), .equals("plain")] {
            let legacy = op.javascriptCondition
                .replacingOccurrences(of: "'plain'", with: "\"plain\"")
            #expect(op.scriptSafeCondition == legacy)
        }
        let hostile = Operator.equals(Hostile.payload).scriptSafeCondition
        ScriptScan.expectScriptSafe(hostile)
        #expect(hostile.hasPrefix("== \""))
        #expect(try JSONDecoder().decode(String.self, from: Data(hostile.dropFirst(3).utf8)) == Hostile.payload)
    }
}

/// Small deterministic PRNG (SplitMix64) for reproducible test inputs.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
