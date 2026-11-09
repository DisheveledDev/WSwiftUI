//
//  ScriptContext.swift
//  WSwiftUI
//
//  Helpers for building JavaScript source from Swift values in the action compiler, the variable
//  runtime, the event helpers and the objects that emit their own `<script>` blocks.
//
//  Rule: every non-constant Swift value that is written into generated JavaScript goes through one of
//  these helpers (which all bottom out in `WebJSON`), so the value can neither terminate the
//  surrounding string literal nor the surrounding `<script>` element. Generated identifiers
//  (`builderId`, md5-derived names) and enum raw values that the framework owns may be interpolated
//  directly, because they can only ever contain `[a-z0-9_-]`.
//

import Foundation

internal enum ScriptValue {

    /// A double-quoted, script-safe JavaScript string literal (see `WebJSON.scriptString`).
    @inline(__always)
    static func string(_ value: String) -> String {
        return WebJSON.scriptString(value)
    }

    /// A string literal, or `null` when the value is `nil`.
    static func stringOrNull(_ value: String?) -> String {
        guard let value else { return "null" }
        return WebJSON.scriptString(value)
    }

    /// A JavaScript number literal. Finite values use Swift's shortest round-trip representation
    /// (identical to the legacy `"\(double)"` output); NaN and the infinities become `NaN`,
    /// `Infinity` and `-Infinity` instead of the undefined identifiers `nan` / `inf`.
    static func number(_ value: Double) -> String {
        return WebJSON.numberLiteral(value)
    }

    /// Encodes the loosely typed payloads accepted by `.setVariable`, `.setInput`, `.setVariableName`
    /// and `Operator.equals`.
    ///
    /// The type dispatch mirrors the legacy compiler exactly: `String`, then `Int`, `Double` and `Bool`
    /// are emitted as literals of that type; anything else (including `nil`) was previously written as
    /// `'\(value ?? "")'`, i.e. its Swift description as a JS string, and still is, only encoded safely.
    static func loose(_ value: Any?) -> String {
        if let stringValue = value as? String {
            return WebJSON.scriptString(stringValue)
        } else if let intValue = value as? Int {
            return String(intValue)
        } else if let doubleValue = value as? Double {
            return number(doubleValue)
        } else if let boolValue = value as? Bool {
            return boolValue ? "true" : "false"
        } else {
            return WebJSON.scriptString(String(describing: value ?? ""))
        }
    }

    /// Makes an already-encoded JSON document script-safe: `WebJSON.makeScriptSafe` plus escaping `'` and
    /// the backtick, which in valid JSON can only occur inside strings. The output therefore has the same
    /// character guarantees as `WebJSON.scriptString` and decodes to the same value.
    static func json(_ encodedJSON: String) -> String {
        return WebJSON.makeScriptSafe(encodedJSON)
    }

    /// `document.getElementById("<id>")` with the id encoded as a string literal.
    static func elementById(_ id: String) -> String {
        return "document.getElementById(\(WebJSON.scriptString(id)))"
    }

    /// The element addressed by an optional `ref`: `document.getElementById("<ref>")` when a ref is given,
    /// otherwise the element's registered global (`builderId`, a generated identifier).
    static func element(_ ref: String?, fallback builderId: String) -> String {
        guard let ref else { return builderId }
        return elementById(ref)
    }

    /// The largest delay `setTimeout`/`setInterval` honour (2^31 - 1 ms, about 24.8 days). Browsers and
    /// Node treat anything larger as an overflow and fire after ~1 ms instead.
    static let maxTimerDelay = 2_147_483_647

    /// Converts seconds to whole milliseconds for `setTimeout`/`setInterval` without trapping on
    /// NaN, infinities or out-of-range values (which `Int(seconds * 1000)` would).
    ///
    /// The result is clamped to `0...maxTimerDelay`: NaN and non-positive values become 0 (which is how
    /// timers already treat negative delays), and huge values or +infinity become the maximum delay, so an
    /// "infinite" delay waits as long as a timer can instead of overflowing into "fire immediately".
    /// Ordinary values truncate exactly as the legacy `Int(seconds * 1000)` did.
    static func milliseconds(fromSeconds seconds: Double) -> Int {
        let ms = seconds * 1000
        if ms.isNaN || ms <= 0 { return 0 }
        if ms >= Double(maxTimerDelay) { return maxTimerDelay }
        return Int(ms)
    }

    /// The text JavaScript's `String(number)` produces for `value` (ECMAScript Number::toString):
    /// `NaN`, `Infinity`, `0` for ±0, plain decimal notation for 1e-7 <= |x| < 1e21 (no trailing `.0`) and
    /// exponent notation (`1e+21`, `1.5e-7`) outside that range.
    ///
    /// Swift's `description` already yields the shortest round-trip digits, as JS does; only the layout
    /// differs (Swift writes `1e-05`, `1e+16` and `1000000000000000.0`), so the digits and the decimal
    /// exponent are taken from it and re-laid out by the ECMAScript rules.
    static func numberText(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
        if value == 0 { return "0" }
        if value < 0 { return "-" + numberText(-value) }

        let description = String(value)
        var mantissa = Substring(description)
        var exponent = 0
        if let e = description.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = description[..<e]
            exponent = Int(description[description.index(after: e)...]) ?? 0
        }
        let integerPart: Substring
        let fractionPart: Substring
        if let dot = mantissa.firstIndex(of: ".") {
            integerPart = mantissa[..<dot]
            fractionPart = mantissa[mantissa.index(after: dot)...]
        } else {
            integerPart = mantissa
            fractionPart = ""
        }

        // digits * 10^(n - k) == value, with no leading or trailing zeros in `digits`
        var digits = Array(integerPart + fractionPart)
        var n = integerPart.count + exponent
        while digits.count > 1, digits.first == "0" { digits.removeFirst(); n -= 1 }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        let k = digits.count
        let s = String(digits)

        if k <= n && n <= 21 {
            return s + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            return String(digits[..<n]) + "." + String(digits[n...])
        }
        if -6 < n && n <= 0 {
            return "0." + String(repeating: "0", count: -n) + s
        }
        let e = n - 1
        let exponentText = e >= 0 ? "e+\(e)" : "e-\(-e)"
        if k == 1 {
            return s + exponentText
        }
        return String(digits[0]) + "." + String(digits[1...]) + exponentText
    }
}

internal extension Operator {

    /// Script-safe equivalent of `javascriptCondition`: the right-hand side of a comparison against a
    /// value, e.g. `== "value"`. The `.equals` operand is encoded with `ScriptValue.loose`, which
    /// keeps the legacy type dispatch (strings compare as strings, numbers/bools as literals).
    var scriptSafeCondition: String {
        switch self {
        case .equals(let comparitor):
            return "== \(ScriptValue.loose(comparitor))"
        case .isEmpty:
            return "== ''"
        case .isNotEmpty:
            return "!= ''"
        case .isTrue:
            return "== true"
        case .isFalse:
            return "== false"
        case .isZero:
            return "== 0"
        case .isNonzero:
            return "!= 0"
        case .isPositive:
            return "> 0"
        case .isNegative:
            return "< 0"
        }
    }
}
