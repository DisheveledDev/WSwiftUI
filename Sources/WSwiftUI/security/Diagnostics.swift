//
//  Diagnostics.swift
//  WSwiftUI
//
//  One place for the framework's `[WSwiftUI] …` warnings.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

internal enum WSwiftUIDiagnostics {

    private static let lock = NSLock()

    /// Writes one diagnostic line to standard error, which is unbuffered. `print` goes to standard
    /// output, which is block-buffered when it is not a terminal (a service manager, a container, a
    /// pipe), so a one-time warning could sit in the buffer or be lost when the process exits.
    ///
    /// It writes to file descriptor 2 directly and ignores errors: a closed standard error or a pipe
    /// whose reader has gone (the server ignores SIGPIPE) loses the line but never stops the server.
    /// (`FileHandle.write(_:)` raises an exception on such an error, which aborts the process.)
    static func log(_ line: String) {
        let bytes = Array((line + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        bytes.withUnsafeBytes { buffer in
            guard var next = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(2, next, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if written == 0 { return }
                next += written
                remaining -= written
            }
        }
    }

    /// `text` with control characters, line and paragraph separators replaced by `?` and cut to `limit`
    /// characters, so app- or request-supplied text quoted in a diagnostic can't forge log lines.
    static func printable(_ text: String, limit: Int = 120) -> String {
        var out = ""
        for scalar in text.unicodeScalars.prefix(limit) {
            switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator, .unassigned, .surrogate, .privateUse:
                    out += "?"
                default:
                    out.unicodeScalars.append(scalar)
            }
        }
        if text.unicodeScalars.count > limit { out += "..." }
        return out
    }
}
