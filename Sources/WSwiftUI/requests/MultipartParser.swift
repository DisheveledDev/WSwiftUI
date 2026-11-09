//
//  MultipartParser.swift
//  WSwiftUI
//
//  Bounds-checked multipart/form-data parsing for WebData.
//
//  Every index is checked before use, so a malformed or hostile body can only
//  produce fewer parts, never a trap. Well-formed bodies parse exactly as the
//  original in-memory parser did: parts in order, a part's content ends before
//  the CRLF that precedes the next delimiter, and a part with no closing
//  delimiter (a truncated body) is dropped.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A named part located in a multipart/form-data body.
struct MultipartPart {
    let name: String
    let filename: String?
    let contentType: String?
    /// The part's content: a slice of the parsed body that shares its storage.
    let body: Data
}

enum MultipartParser {

    /// Parts beyond this many are not parsed.
    static let maxParts = 1000
    /// A part whose header block is longer than this stops parsing.
    static let maxHeaderBytesPerPart = 16 * 1024
    /// RFC 2046 allows 70 characters; leave headroom for non-conforming clients.
    static let maxBoundaryLength = 256

    /// The `boundary` parameter of a request Content-Type, unquoted, or nil when it is
    /// missing, empty or implausibly long. When the parameter repeats, the first wins.
    static func boundary(fromContentType contentType: String) -> String? {
        guard let value = MultipartHeaderParameters.parse(contentType).first(where: { $0.name == "boundary" })?.value,
              value.isEmpty == false,
              value.utf8.count <= maxBoundaryLength
        else { return nil }
        return value
    }

    /// The named parts of `data`, in body order. Parts without a `name`, or whose
    /// header block is not UTF-8, are skipped.
    static func parse(_ data: Data,
                      boundary: String,
                      maxParts: Int = maxParts,
                      maxHeaderBytes: Int = maxHeaderBytesPerPart) -> [MultipartPart] {
        let base = data.startIndex
        var parts: [MultipartPart] = []
        for raw in locateParts(in: data, boundary: boundary, maxParts: maxParts, maxHeaderBytes: maxHeaderBytes) {
            let headerData = data[(base + raw.headers.lowerBound)..<(base + raw.headers.upperBound)]
            guard let headerText = String(data: headerData, encoding: .utf8) else { continue }
            let headers = MultipartPartHeaders(parsing: headerText)
            guard let name = headers.name else { continue }
            parts.append(MultipartPart(name: name,
                                       filename: headers.filename,
                                       contentType: headers.contentType,
                                       body: data[(base + raw.body.lowerBound)..<(base + raw.body.upperBound)]))
        }
        return parts
    }

    /// Offsets (from `data.startIndex`) of one part's header block and content.
    struct RawPart {
        let headers: Range<Int>
        let body: Range<Int>
    }

    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A
    private static let dash: UInt8 = 0x2D

    /// Splits `data` into header and content ranges without decoding anything.
    ///
    /// The line ending is taken from the first delimiter line: CRLF as RFC 2046 requires,
    /// or a bare LF, which is tolerated. A CRLF body is split exactly as before.
    static func locateParts(in data: Data,
                            boundary: String,
                            maxParts: Int = maxParts,
                            maxHeaderBytes: Int = maxHeaderBytesPerPart) -> [RawPart] {
        guard boundary.isEmpty == false, maxParts > 0 else { return [] }
        let delimiter = Array("--\(boundary)".utf8)
        let headerCap = max(0, maxHeaderBytes)

        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> [RawPart] in
            let n = buf.count
            var parts: [RawPart] = []
            // As before, the first delimiter may appear anywhere in the body.
            guard let first = MultipartByteSearch(delimiter).firstMatch(in: buf, from: 0, to: n) else { return parts }
            var pos = first + delimiter.count

            let eol: [UInt8] = (pos < n && buf[pos] == lf) ? [lf] : [cr, lf]
            let nextDelimiter = MultipartByteSearch(eol + delimiter)
            let blankLine = MultipartByteSearch(eol + eol)
            var attempted = 0

            while attempted < maxParts {
                // "--" straight after a delimiter closes the body; the epilogue is ignored.
                if matches([dash, dash], in: buf, at: pos) { break }
                if matches(eol, in: buf, at: pos) { pos += eol.count }

                // No further delimiter means a truncated body: drop the unterminated part.
                guard let end = nextDelimiter.firstMatch(in: buf, from: pos, to: n) else { break }
                attempted += 1

                let startsWithBlankLine = end - pos >= eol.count && matches(eol, in: buf, at: pos)
                if startsWithBlankLine == false {
                    // The blank line may share its last line ending with the next delimiter
                    // (headers followed directly by the delimiter: empty content).
                    let window = min(end + eol.count, pos + min(headerCap, n) + 2 * eol.count)
                    if let headerEnd = blankLine.firstMatch(in: buf, from: pos, to: window) {
                        let bodyStart = min(headerEnd + 2 * eol.count, end)
                        parts.append(RawPart(headers: pos..<headerEnd, body: bodyStart..<end))
                    } else if end - pos > headerCap {
                        break // header block over the cap: stop parsing
                    }
                    // Otherwise the part has no blank line after its headers: skip it.
                }
                // A part that starts with a blank line has no headers, so no name: skip it.

                pos = end + eol.count + delimiter.count
            }
            return parts
        }
    }

    private static func matches(_ pattern: [UInt8], in buf: UnsafeRawBufferPointer, at index: Int) -> Bool {
        guard index >= 0, index <= buf.count - pattern.count else { return false }
        for (offset, byte) in pattern.enumerated() where buf[index + offset] != byte {
            return false
        }
        return true
    }
}

/// Leftmost-match byte search in linear time (Knuth-Morris-Pratt), so a hostile
/// boundary or body cannot make delimiter scanning quadratic.
struct MultipartByteSearch {
    private let pattern: [UInt8]
    private let fallback: [Int]

    init(_ pattern: [UInt8]) {
        self.pattern = pattern
        var fallback = [Int](repeating: 0, count: pattern.count)
        var k = 0
        var i = 1
        while i < pattern.count {
            while k > 0 && pattern[i] != pattern[k] { k = fallback[k - 1] }
            if pattern[i] == pattern[k] { k += 1 }
            fallback[i] = k
            i += 1
        }
        self.fallback = fallback
    }

    /// Offset of the first match lying entirely inside `from..<to`, or nil.
    func firstMatch(in buf: UnsafeRawBufferPointer, from: Int, to: Int) -> Int? {
        let m = pattern.count
        let lower = max(0, from)
        let upper = min(buf.count, to)
        guard m > 0, lower < upper, upper - lower >= m else { return nil }
        let first = pattern[0]
        var k = 0
        var i = lower
        while i < upper {
            if k == 0 {
                // Jump to the next byte that can start a match.
                guard let next = Self.firstIndex(of: first, in: buf, from: i, to: upper) else { return nil }
                i = next
            }
            let byte = buf[i]
            while k > 0 && byte != pattern[k] { k = fallback[k - 1] }
            if byte == pattern[k] { k += 1 }
            if k == m { return i - m + 1 }
            i += 1
        }
        return nil
    }

    /// libc's memchr where available: fast even in debug builds, which matters for large uploads.
    private static func firstIndex(of byte: UInt8, in buf: UnsafeRawBufferPointer, from: Int, to: Int) -> Int? {
        guard from < to, let base = buf.baseAddress else { return nil }
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        guard let hit = memchr(base + from, Int32(byte), to - from) else { return nil }
        return base.distance(to: UnsafeRawPointer(hit))
        #else
        var i = from
        while i < to {
            if buf[i] == byte { return i }
            i += 1
        }
        return nil
        #endif
    }
}

/// The fields WebData reads from one part's header block.
struct MultipartPartHeaders {
    var name: String?
    var filename: String?
    var contentType: String?

    init(parsing headerText: String) {
        var extendedFilename: String?
        for line in headerText.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" }) {
            // A line without a colon is not a header field: ignore it.
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...]
            switch line[..<colon].lowercased() {
                case "content-disposition":
                    // As before, later parameters (and later lines) override earlier ones.
                    for parameter in MultipartHeaderParameters.parse(value, skippingFirstSegment: true) {
                        switch parameter.name {
                            case "name":
                                name = parameter.value
                            case "filename":
                                filename = parameter.value
                            case "filename*":
                                extendedFilename = MultipartHeaderParameters.decodeExtendedValue(parameter.value) ?? parameter.value
                            default:
                                break
                        }
                    }
                case "content-type":
                    contentType = value.trimmingCharacters(in: .whitespaces)
                default:
                    break
            }
        }
        // RFC 7578 tells senders not to use filename*, so it only fills in for a missing filename.
        if filename == nil {
            filename = extendedFilename
        }
    }
}

/// `;`-separated `name=value` parameters of a header value such as Content-Type or
/// Content-Disposition.
enum MultipartHeaderParameters {

    struct Parameter: Equatable {
        /// Lowercased and trimmed.
        let name: String
        let value: String
    }

    /// Parses every `name=value` segment of `text`; segments without `=` are skipped.
    ///
    /// A value in double quotes may contain `;` and `=`; it ends at the first quote followed only
    /// by whitespace before the next `;` or the end. Backslashes are kept as sent, as before
    /// (browsers percent-encode quotes in names and filenames). Unquoted values, and quoted values
    /// that never close, are trimmed of whitespace and of surrounding quotes, as before.
    /// - Parameter skippingFirstSegment: skip everything up to the first `;`, e.g. the
    ///   disposition type in `form-data; name="x"`.
    static func parse<S: StringProtocol>(_ text: S, skippingFirstSegment: Bool = false) -> [Parameter] {
        let scalars = Array(text.unicodeScalars)
        let n = scalars.count
        var parameters: [Parameter] = []
        var i = 0
        // Once a quoted value has no closing quote, no later one can have one either; remembering
        // that keeps parsing linear when every value is an unterminated quote.
        var closingQuotesExhausted = false

        if skippingFirstSegment {
            while i < n && scalars[i] != ";" { i += 1 }
            i += 1
        }

        while i < n {
            let nameStart = i
            while i < n && scalars[i] != "=" && scalars[i] != ";" { i += 1 }
            guard i < n, scalars[i] == "=" else {
                i += 1 // a segment with no '=' carries no parameter
                continue
            }
            let name = string(scalars[nameStart..<i]).trimmingCharacters(in: .whitespaces).lowercased()
            i += 1
            while i < n && isWhitespace(scalars[i]) { i += 1 }

            var value: String?
            if i < n && scalars[i] == "\"" && closingQuotesExhausted == false {
                if let close = closingQuote(in: scalars, openingAt: i) {
                    value = string(scalars[(i + 1)..<close])
                    i = close + 1
                    while i < n && scalars[i] != ";" { i += 1 }
                } else {
                    closingQuotesExhausted = true
                }
            }
            if value == nil {
                let valueStart = i
                while i < n && scalars[i] != ";" { i += 1 }
                value = string(scalars[valueStart..<i])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: quotes)
            }
            i += 1 // past the ';'
            parameters.append(Parameter(name: name, value: value ?? ""))
        }
        return parameters
    }

    /// Decodes an RFC 8187 extended value (`charset'language'percent-encoded`). Only UTF-8 is
    /// decoded; anything else returns nil so the caller can keep the raw value.
    static func decodeExtendedValue(_ raw: String) -> String? {
        let pieces = raw.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].lowercased() == "utf-8" else { return nil }
        return String(pieces[2]).removingPercentEncoding
    }

    private static let quotes = CharacterSet(charactersIn: "\"")

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespaces.contains(scalar)
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// The first quote after `open` that is followed only by whitespace before `;` or the end.
    private static func closingQuote(in scalars: [Unicode.Scalar], openingAt open: Int) -> Int? {
        var q = open + 1
        while q < scalars.count {
            if scalars[q] == "\"" {
                var r = q + 1
                while r < scalars.count && isWhitespace(scalars[r]) { r += 1 }
                if r == scalars.count || scalars[r] == ";" { return q }
            }
            q += 1
        }
        return nil
    }
}
