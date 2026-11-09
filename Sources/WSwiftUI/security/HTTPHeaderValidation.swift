//
//  HTTPHeaderValidation.swift
//  WSwiftUI
//
//  Validation rules for response header fields and Set-Cookie values.
//  A header that breaks these rules could split the response (CR/LF) or
//  inject cookie attributes (';'), so HttpResponse drops it instead.
//

import Foundation

internal enum HTTPHeaderValidation {

    /// RFC 7230 `token`: 1*tchar.
    /// tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA
    static func isToken(_ s: String) -> Bool {
        guard s.isEmpty == false else { return false }
        for b in s.utf8 {
            switch b {
                case UInt8(ascii: "0")...UInt8(ascii: "9"),
                     UInt8(ascii: "a")...UInt8(ascii: "z"),
                     UInt8(ascii: "A")...UInt8(ascii: "Z"):
                    continue
                case UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"), UInt8(ascii: "%"),
                     UInt8(ascii: "&"), UInt8(ascii: "'"), UInt8(ascii: "*"), UInt8(ascii: "+"),
                     UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "^"), UInt8(ascii: "_"),
                     UInt8(ascii: "`"), UInt8(ascii: "|"), UInt8(ascii: "~"):
                    continue
                default:
                    return false
            }
        }
        return true
    }

    /// A header value is safe to write when it contains no CR, LF or NUL.
    static func isSafeFieldValue(_ s: String) -> Bool {
        for b in s.utf8 where b == 0x0D || b == 0x0A || b == 0x00 {
            return false
        }
        return true
    }

    /// A header line can be written when its name is a token and its value has no CR, LF or NUL.
    static func isWritable(name: String, value: String) -> Bool {
        return isToken(name) && isSafeFieldValue(value)
    }

    /// RFC 6265 cookie-value: *cookie-octet / ( DQUOTE *cookie-octet DQUOTE ).
    /// cookie-octet = %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E. The empty value is allowed.
    static func isCookieValue(_ s: String) -> Bool {
        var bytes = Array(s.utf8)
        if bytes.count >= 2, bytes.first == 0x22, bytes.last == 0x22 {
            bytes = Array(bytes[1..<(bytes.count - 1)])
        }
        for b in bytes {
            switch b {
                case 0x21, 0x23...0x2B, 0x2D...0x3A, 0x3C...0x5B, 0x5D...0x7E:
                    continue
                default:
                    return false
            }
        }
        return true
    }

    /// Cookie attribute values (Path, Domain, SameSite) must be RFC 6265 av-octets:
    /// printable ASCII (0x20-0x7E) other than ';'. This excludes every control character,
    /// including the C1 controls such as U+0085 (NEL), and all non-ASCII text.
    static func isSafeCookieAttribute(_ s: String) -> Bool {
        for b in s.utf8 where b == UInt8(ascii: ";") || b < 0x20 || b > 0x7E {
            return false
        }
        return true
    }

    /// Logs one line for a dropped header. Only a sanitised, truncated name is printed:
    /// never the value, which may hold a session token or attacker-controlled bytes.
    static func logDropped(_ what: String, name: String, reason: String) {
        print("[WSwiftUI] Dropped \(what) \"\(printable(name))\": \(reason)")
    }

    /// Replaces control and non-ASCII characters so the text cannot forge log lines.
    static func printable(_ s: String, limit: Int = 64) -> String {
        var out = ""
        for scalar in s.unicodeScalars.prefix(limit) {
            if scalar.value >= 0x20 && scalar.value < 0x7F && scalar != "\"" && scalar != "\\" {
                out.unicodeScalars.append(scalar)
            } else {
                out += "?"
            }
        }
        if s.unicodeScalars.count > limit { out += "..." }
        return out
    }
}
