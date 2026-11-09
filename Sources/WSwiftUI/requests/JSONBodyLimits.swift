//
//  JSONBodyLimits.swift
//  WSwiftUI
//
//  Limits that keep a hostile JSON request body from crashing the process.
//

import Foundation

enum JSONBodyLimits {

    /// Bodies nested deeper than this are not parsed.
    ///
    /// JSONSerialization, JSONDecoder and the `JSONValue` decoder all recurse once per level. On a
    /// 512 KiB worker-thread stack, JSONSerialization overflows at about 470 nested objects, and
    /// decoding `WebVariableTransaction` in a debug build at about 200. Real request bodies are
    /// nowhere near this deep.
    static let maxNestingDepth = 64

    /// Thrown by `jsonObject(with:options:)` for input nested deeper than `maxNestingDepth`.
    enum ParseError: Error, Equatable {
        case nestingTooDeep
    }

    /// `JSONSerialization.jsonObject(with:options:)` for JSON that came from a request (a body,
    /// a form field, a query value). Input nested deeper than `maxNestingDepth` throws
    /// `ParseError.nestingTooDeep` instead of overflowing the calling thread's stack.
    static func jsonObject(with data: Data, options: JSONSerialization.ReadingOptions = []) throws -> Any {
        guard nestingExceedsLimit(data) == false else { throw ParseError.nestingTooDeep }
        return try JSONSerialization.jsonObject(with: data, options: options)
    }

    /// Whether `data` opens more than `limit` nested objects or arrays, checked in one pass
    /// without parsing anything.
    static func nestingExceedsLimit(_ data: Data, limit: Int = maxNestingDepth) -> Bool {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            // JSONSerialization also reads UTF-16 and UTF-32. There a code unit's bytes can look like
            // quotes or brackets, so neither strings nor closing brackets can be trusted. Count every
            // opening bracket instead, which can only over-estimate the depth.
            let utf16BOM = buf.count >= 2 && ((buf[0] == 0xFE && buf[1] == 0xFF) || (buf[0] == 0xFF && buf[1] == 0xFE))
            let mayBeWideEncoding = buf.prefix(4).contains(0) || utf16BOM

            var depth = 0
            var inString = false
            var escaped = false
            for byte in buf {
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == backslash {
                        escaped = true
                    } else if byte == quote {
                        inString = false
                    }
                    continue
                }
                switch byte {
                    case quote:
                        inString = mayBeWideEncoding == false
                    case openBrace, openBracket:
                        depth += 1
                        if depth > limit { return true }
                    case closeBrace, closeBracket:
                        if mayBeWideEncoding == false {
                            depth = max(0, depth - 1)
                        }
                    default:
                        break
                }
            }
            return false
        }
    }

    private static let quote: UInt8 = 0x22
    private static let backslash: UInt8 = 0x5C
    private static let openBrace: UInt8 = 0x7B
    private static let closeBrace: UInt8 = 0x7D
    private static let openBracket: UInt8 = 0x5B
    private static let closeBracket: UInt8 = 0x5D
}

/// Decides whether WebData may flatten a JSON body into string fields.
///
/// A flattened key repeats its parent's whole path ("a.b.c"), and an array value is stored as
/// the description of its elements, which indents nested containers. Either lets a small hostile
/// body grow into gigabytes of strings. So before flattening, WebData measures what flattening
/// would copy: exactly for keys and scalar values, and with an upper bound for array
/// descriptions, without building any of those strings. A body over the limit is not flattened
/// at all. The total does not depend on dictionary order, so the outcome is the same on every run;
/// ordinary bodies (a few times their own size once flattened) never come near the limit.
enum JSONFlattenBudget {

    /// Every body may copy at least this much.
    static let minimumBytes = 64 * 1024 * 1024
    /// Larger bodies may copy this many times their own size.
    static let bodyMultiplier = 16

    /// The most bytes flattening a body of `bodyBytes` may copy.
    static func limit(forBodyBytes bodyBytes: Int) -> Int {
        let scaled = bodyBytes > Int.max / bodyMultiplier ? Int.max : max(0, bodyBytes) * bodyMultiplier
        return max(minimumBytes, scaled)
    }

    /// The bytes WebData's flatten copies for `dictionary`: every full key it builds (including
    /// the prefixes of nested objects), every scalar value, and an upper bound for every array
    /// value. Once the count passes `limit` it stops and returns a value above `limit`.
    ///
    /// This mirrors the cases of WebData's flatten, in the same order.
    static func flattenedSize(of dictionary: [String: Any], limit: Int) -> Int {
        var total = 0
        // `prefixBytes` is the parent's full key plus its ".", or 0 at the top level.
        var pending: [(dictionary: [String: Any], prefixBytes: Int)] = [(dictionary, 0)]
        while let (dict, prefixBytes) = pending.popLast() {
            for (key, value) in dict {
                let keyBytes = add(prefixBytes, key.utf8.count)
                total = add(total, keyBytes)
                switch value {
                    case let s as String:
                        total = add(total, s.utf8.count)
                    case let n as NSNumber:
                        total = add(total, n.stringValue.utf8.count)
                    case let b as Bool:
                        total = add(total, b.description.utf8.count)
                    case let d as Double:
                        total = add(total, String(d).utf8.count)
                    case let sub as [String: Any]:
                        pending.append((sub, add(keyBytes, 1)))
                    case let arr as [Any]:
                        // The elements' descriptions joined by ",".
                        total = add(total, max(0, arr.count - 1))
                        for element in arr {
                            if total > limit { return total }
                            total = add(total, arrayElementBound(element, limit: limit - total))
                        }
                    default:
                        break
                }
                if total > limit { return total }
            }
        }
        return total
    }

    /// An upper bound on the length of `"\(value)"` for a value from JSONSerialization, counted
    /// without building the description. Stops counting once `limit` is passed.
    ///
    /// Darwin describes a container across lines: each child line is indented 4 spaces per
    /// level, a nested container's opening line twice that, and its closing line once more, so
    /// a child at level L costs at most 12 L + 8 bytes besides its key and its text. Strings
    /// may be quoted and escaped, and non-ASCII characters are written as 6-character escapes
    /// per UTF-16 unit. Swift's own description (used on Linux) is shorter on every count.
    static func descriptionSizeBound(of value: Any, limit: Int) -> Int {
        guard isContainer(value) else { return arrayElementBound(value, limit: limit) }
        // The root's brackets and newline, or "[:]".
        var total = 4
        var pending: [(container: Any, level: Int)] = [(value, 0)]
        while let (item, level) = pending.popLast() {
            let childOverhead = add(16, multiply(12, level + 1))
            if let dictionary = item as? [String: Any] {
                for (key, child) in dictionary {
                    total = add(total, add(childOverhead, quotedStringBound(key)))
                    total = add(total, childTextBound(child))
                    if total > limit { return total }
                    if isContainer(child) { pending.append((child, level + 1)) }
                }
            } else if let array = item as? [Any] {
                for child in array {
                    total = add(total, add(childOverhead, childTextBound(child)))
                    if total > limit { return total }
                    if isContainer(child) { pending.append((child, level + 1)) }
                }
            }
        }
        return total
    }

    /// An upper bound on the length of `"\(element)"` for an element of an array value.
    private static func arrayElementBound(_ element: Any, limit: Int) -> Int {
        if let string = element as? String {
            return string.utf8.count
        }
        if isContainer(element) {
            return descriptionSizeBound(of: element, limit: limit)
        }
        return scalarTextBound(element)
    }

    /// An upper bound on the text of a value written inside a container's description.
    /// A nested container's own lines are counted when it is visited.
    private static func childTextBound(_ value: Any) -> Int {
        if let string = value as? String {
            return quotedStringBound(string)
        }
        if isContainer(value) {
            return 0
        }
        return add(scalarTextBound(value), 2)
    }

    /// A number, bool or null, measured exactly (both ways a container may describe it).
    private static func scalarTextBound(_ value: Any) -> Int {
        max(String(describing: value).utf8.count, String(reflecting: value).utf8.count)
    }

    /// An upper bound on a string written quoted and escaped, as containers describe strings:
    /// two quotes, at most 2 bytes per printable ASCII byte (a backslash escape), 6 per ASCII
    /// control byte, and 4 per byte of a non-ASCII character (Darwin writes 6 bytes per UTF-16
    /// unit; Swift writes a non-printable scalar as at most 3.5 bytes per UTF-8 byte).
    static func quotedStringBound(_ string: String) -> Int {
        var total = 2
        for byte in string.utf8 {
            switch byte {
                case 0x20...0x7E: total += 2
                case 0x80...: total += 4
                default: total += 6
            }
        }
        return total
    }

    private static func isContainer(_ value: Any) -> Bool {
        value is [String: Any] || value is [Any]
    }

    /// Adds without overflowing; the counts only ever need to be compared with a limit.
    private static func add(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : sum
    }

    private static func multiply(_ a: Int, _ b: Int) -> Int {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? Int.max : product
    }
}
