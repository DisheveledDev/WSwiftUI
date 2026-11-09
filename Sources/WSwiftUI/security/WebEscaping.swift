//
//  WebEscaping.swift
//  WSwiftUI
//
//  Canonical escaping helpers for the output contexts the renderer produces.
//
//  There are only two contexts that framework code should ever write dynamic values into:
//
//   1. HTML: element text content, or a double-quoted attribute value.  Use `WebEscape.html(_:)`
//      (or `WebEscape.attribute(_:)`, which is identical) on the value.
//   2. JavaScript inside a `<script>` element.  Use `WebJSON.scriptString(_:)` for strings and
//      `WebJSON.scriptLiteral(_:)` / `WebJSON.scriptLiteral(any:)` for other values.  The result is a
//      complete JS literal (including its quotes) that cannot terminate the script element.
//
//  If generated JavaScript has to live inside an HTML attribute (e.g. `onclick="…"`), build the JS with
//  the `WebJSON` helpers first and then pass the *whole* JS string through `WebEscape.attribute(_:)`.
//

import Foundation

/// HTML escaping.
public enum WebEscape {

    /// Escapes `&`, `<`, `>`, `"` and `'` so the value is inert inside HTML element content or a
    /// double-quoted (or single-quoted) attribute value.
    public static func html(_ value: String) -> String {
        // fast path: nothing to escape
        if value.unicodeScalars.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" || $0 == "\"" || $0 == "'" }) == false {
            return value
        }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(value.unicodeScalars.count + 16)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": out.append(contentsOf: "&quot;".unicodeScalars)
            case "'": out.append(contentsOf: "&#39;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// Escapes a value for use inside a double-quoted HTML attribute. Identical to `html(_:)`.
    public static func attribute(_ value: String) -> String {
        return html(value)
    }
}

/// JSON / JavaScript literal encoding that is safe to embed inside a `<script>` element.
public enum WebJSON {

    /// Returns a double-quoted JavaScript string literal for `value`.
    ///
    /// The literal is valid JSON and valid JavaScript, and it contains no `<`, `>`, `&`, `'`, U+2028 or U+2029
    /// characters (they are `\u`-escaped), so it can't close a `<script>` element, start an HTML comment, or
    /// break out of a single-quoted context.
    public static func scriptString(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(value.unicodeScalars.count + 2)
        out.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out.append(contentsOf: "\\\"".unicodeScalars)
            case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case "\r": out.append(contentsOf: "\\r".unicodeScalars)
            case "\t": out.append(contentsOf: "\\t".unicodeScalars)
            case "<": out.append(contentsOf: "\\u003c".unicodeScalars)
            case ">": out.append(contentsOf: "\\u003e".unicodeScalars)
            case "&": out.append(contentsOf: "\\u0026".unicodeScalars)
            case "'": out.append(contentsOf: "\\u0027".unicodeScalars)
            case "`": out.append(contentsOf: "\\u0060".unicodeScalars)
            case "\u{2028}": out.append(contentsOf: "\\u2028".unicodeScalars)
            case "\u{2029}": out.append(contentsOf: "\\u2029".unicodeScalars)
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out.append(contentsOf: unicodeEscape(scalar.value).unicodeScalars)
                } else {
                    out.append(scalar)
                }
            }
        }
        out.append("\"")
        return String(out)
    }

    /// Encodes any `Encodable` value as script-safe JSON. Returns `nil` if encoding fails.
    public static func scriptLiteral<T: Encodable>(_ value: T, encoder: JSONEncoder? = nil) -> String? {
        let encoder = encoder ?? makeEncoder()
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return makeScriptSafe(json)
    }

    /// Encodes the loosely typed values used by the variable system (`Bool`, `Int`, `Double`, `String`,
    /// `[String]`, `[Int]`, `[Double]`, `[Bool]`, and JSON-compatible dictionaries/arrays) as a script-safe
    /// JavaScript literal. Returns `nil` for values that can't be represented.
    public static func scriptLiteral(any raw: Any) -> String? {
        // A Foundation number (e.g. a value parsed by JSONSerialization) is a class instance, and on Darwin
        // an NSNumber holding 0 or 1 also casts to Bool. Let JSONSerialization, which knows whether the
        // number is a boolean, encode it. Native Swift values are value types and skip this.
        if type(of: raw) is AnyClass, let number = raw as? NSNumber {
            if JSONSerialization.isValidJSONObject([number]),
               let data = try? JSONSerialization.data(withJSONObject: [number]),
               let json = String(data: data, encoding: .utf8), json.count >= 2 {
                return String(json.dropFirst().dropLast())
            }
            return numberLiteral(number.doubleValue)   // NaN / ±Infinity
        }
        // A Foundation array (e.g. from JSONSerialization) would otherwise match `[Int]` below, turning
        // boolean elements into 0/1; encode each element on its own instead.
        if type(of: raw) is AnyClass, let items = raw as? [Any] {
            var parts: [String] = []
            parts.reserveCapacity(items.count)
            for item in items {
                guard let part = scriptLiteral(any: item) else { return nil }
                parts.append(part)
            }
            return "[" + parts.joined(separator: ",") + "]"
        }
        switch raw {
        case let v as Bool:
            return v ? "true" : "false"
        case let v as Int:
            return String(v)
        case let v as Double:
            return numberLiteral(v)
        case let v as String:
            return scriptString(v)
        case let v as Substring:
            return scriptString(String(v))
        case let v as [String]:
            return "[" + v.map { scriptString($0) }.joined(separator: ",") + "]"
        case let v as [Int]:
            return "[" + v.map { String($0) }.joined(separator: ",") + "]"
        case let v as [Double]:
            return "[" + v.map { numberLiteral($0) }.joined(separator: ",") + "]"
        case let v as [Bool]:
            return "[" + v.map { $0 ? "true" : "false" }.joined(separator: ",") + "]"
        default:
            // JSONSerialization raises an (uncatchable) Objective-C exception for invalid objects, so validate first.
            guard JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return makeScriptSafe(json)
        }
    }

    /// Makes an already-encoded JSON document safe to embed in a `<script>` element by `\u`-escaping
    /// `<`, `>`, `&`, `'`, the backtick, U+2028 and U+2029. In valid JSON these characters can only occur
    /// inside strings, so the escaped document decodes to the same value, and the result has the same
    /// character guarantees as `scriptString`.
    public static func makeScriptSafe(_ json: String) -> String {
        if json.unicodeScalars.contains(where: { $0 == "<" || $0 == ">" || $0 == "&" || $0 == "'" || $0 == "`" || $0 == "\u{2028}" || $0 == "\u{2029}" }) == false {
            return json
        }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(json.unicodeScalars.count + 16)
        for scalar in json.unicodeScalars {
            switch scalar {
            case "<": out.append(contentsOf: "\\u003c".unicodeScalars)
            case ">": out.append(contentsOf: "\\u003e".unicodeScalars)
            case "&": out.append(contentsOf: "\\u0026".unicodeScalars)
            case "'": out.append(contentsOf: "\\u0027".unicodeScalars)
            case "`": out.append(contentsOf: "\\u0060".unicodeScalars)
            case "\u{2028}": out.append(contentsOf: "\\u2028".unicodeScalars)
            case "\u{2029}": out.append(contentsOf: "\\u2029".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// Defence in depth for raw, developer-supplied JavaScript placed inside a `<script>` element.
    ///
    /// Rewrites every `</script` (ASCII case-insensitive, as the HTML tokenizer matches it) to `<\/script`,
    /// so a stray closing tag inside a string, regex, template literal or comment can't end the element
    /// early. `\/` means `/` in all of those contexts, so the script behaves the same. This does not make
    /// untrusted text safe to concatenate into JavaScript; use `scriptString` / `scriptLiteral` for values.
    ///
    /// It runs over every script of every page, so it is a single byte-level pass that returns the input
    /// unchanged (without copying) when there is nothing to rewrite.
    public static func scriptElementBody(_ js: String) -> String {
        let offsets = js.utf8.withContiguousStorageIfAvailable(closingScriptTagOffsets)
            ?? Array(js.utf8).withUnsafeBufferPointer(closingScriptTagOffsets)
        guard offsets.isEmpty == false else { return js }
        let bytes = Array(js.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + offsets.count)
        var start = 0
        for offset in offsets {
            out.append(contentsOf: bytes[start...offset])  // up to and including the "<"
            out.append(0x5C)                               // "\\"
            start = offset + 1
        }
        out.append(contentsOf: bytes[start...])
        return String(decoding: out, as: UTF8.self)
    }

    /// Offsets of every `<` that starts an ASCII case-insensitive `</script`.
    private static func closingScriptTagOffsets(_ buf: UnsafeBufferPointer<UInt8>) -> [Int] {
        let n = buf.count
        guard n >= 8 else { return [] }
        var result: [Int] = []
        var i = 0
        while i <= n - 8 {
            // `| 0x20` lower-cases an ASCII letter; no other byte maps onto these letters
            if buf[i] == 0x3C, buf[i + 1] == 0x2F,
               buf[i + 2] | 0x20 == 0x73, buf[i + 3] | 0x20 == 0x63, buf[i + 4] | 0x20 == 0x72,
               buf[i + 5] | 0x20 == 0x69, buf[i + 6] | 0x20 == 0x70, buf[i + 7] | 0x20 == 0x74 {
                result.append(i)
                i += 8
            } else {
                i += 1
            }
        }
        return result
    }

    /// The encoder used for script literals: sorted keys (deterministic output) and ISO-8601 dates.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// A JavaScript number literal: Swift's shortest round-trip form for finite values, and `NaN`,
    /// `Infinity` and `-Infinity` (instead of the undefined identifiers `nan` / `inf`) otherwise.
    internal static func numberLiteral(_ v: Double) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v > 0 ? "Infinity" : "-Infinity" }
        return String(v)
    }

    private static func unicodeEscape(_ value: UInt32) -> String {
        let hex = String(value, radix: 16)
        return "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }
}
