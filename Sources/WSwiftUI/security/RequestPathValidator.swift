//
//  RequestPathValidator.swift
//  WSwiftUI
//
//  Rejects request paths that could walk out of a directory when an
//  endpoint maps the path onto the file system. HTTPServer runs this on
//  every request before route lookup and answers 400 when it fails.
//

import Foundation

public enum RequestPathValidator {

    public enum Rejection: Error, Equatable, Sendable {
        /// The path is neither "*" nor starts with "/".
        case notOriginForm
        /// A '%' is not followed by two hex digits.
        case invalidPercentEncoding
        /// The percent-decoded bytes are not valid UTF-8.
        case invalidUTF8
        /// The path contains %2F or %5C (an encoded '/' or '\').
        case encodedSeparator
        /// The path contains a backslash.
        case backslash
        /// The decoded path contains NUL or another control character.
        case controlCharacter
        /// A path segment is "." or "..".
        case dotSegment
    }

    /// Validates the path part of a request target (everything before the first '?').
    /// The query string is not inspected.
    ///
    /// The path is percent-decoded exactly once. It is rejected when decoding fails,
    /// when it contains an encoded '/' or '\', a backslash, NUL or another control
    /// character, or when any segment is "." or "..".
    ///
    /// - Returns: the percent-decoded path on success.
    public static func validate(uri: String) -> Result<String, Rejection> {
        let rawPath: Substring
        if let q = uri.firstIndex(of: "?") {
            rawPath = uri[..<q]
        } else {
            rawPath = Substring(uri)
        }

        if rawPath == "*" {
            return .success("*")
        }
        guard rawPath.hasPrefix("/") else {
            return .failure(.notOriginForm)
        }

        // percent-decode once, at the byte level
        let raw = Array(rawPath.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(raw.count)
        var i = 0
        while i < raw.count {
            let b = raw[i]
            if b == UInt8(ascii: "%") {
                guard i + 2 < raw.count,
                      let hi = hexValue(raw[i + 1]),
                      let lo = hexValue(raw[i + 2]) else {
                    return .failure(.invalidPercentEncoding)
                }
                let value = hi << 4 | lo
                if value == UInt8(ascii: "/") || value == UInt8(ascii: "\\") {
                    return .failure(.encodedSeparator)
                }
                decoded.append(value)
                i += 3
            } else {
                if b == UInt8(ascii: "\\") {
                    return .failure(.backslash)
                }
                decoded.append(b)
                i += 1
            }
        }

        let path = String(decoding: decoded, as: UTF8.self)
        // String(decoding:) repairs invalid sequences, so a lossless round trip proves validity
        guard Array(path.utf8) == decoded else {
            return .failure(.invalidUTF8)
        }

        for b in decoded where b < 0x20 || b == 0x7F {
            return .failure(.controlCharacter)
        }

        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            if segment == "." || segment == ".." {
                return .failure(.dotSegment)
            }
        }

        return .success(path)
    }

    /// Convenience wrapper around `validate(uri:)`.
    public static func isAcceptable(uri: String) -> Bool {
        if case .success = validate(uri: uri) { return true }
        return false
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
            default: return nil
        }
    }
}
