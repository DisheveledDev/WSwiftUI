//
//  HtmlContext.swift
//  WSwiftUI
//
//  HTML-context helpers used by the renderer and the built-in controls, complementing `WebEscape`.
//
//  Escaping rules used across the controls:
//   - Text a control *shows* (titles, labels, captions, list items, code, ...) is passed through
//     `WebEscape.html(_:)` exactly once before it is stored with `.innerHTML(...)`.
//   - Typed attribute values (`.title`, `.value`, `.href`, `.pair`, ...) are escaped centrally by the
//     renderer, so call sites must pass them *unescaped*.
//   - `.innerHTML(...)`, `.custom(...)` and `NavBar(brand:)` are the explicit raw-HTML opt-ins.
//

import Foundation

/// Helpers for HTML syntax positions that are not attribute values or text content.
internal enum WebHTMLSyntax {

    /// Returns `name` with every character that can't legally appear in an HTML attribute name removed
    /// (whitespace, control characters, `"`, `'`, `<`, `>`, `/` and `=`), so a name can never terminate the
    /// tag or smuggle in another attribute. Valid names are returned unchanged.
    static func attributeName(_ name: String) -> String {
        if name.unicodeScalars.contains(where: isForbiddenInAttributeName) == false {
            return name
        }
        var out = String.UnicodeScalarView()
        for scalar in name.unicodeScalars where isForbiddenInAttributeName(scalar) == false {
            out.append(scalar)
        }
        return String(out)
    }

    /// Makes `text` safe to place inside `<!-- ... -->`. A comment can only be closed early by a sequence
    /// that contains `>` (`-->` or `--!>`), so `>` is replaced with `&gt;` (entities aren't decoded in comments,
    /// but comments are never displayed).
    static func commentText(_ text: String) -> String {
        return text.replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `true` when `value` names the HTML password input type.
    static func isPasswordType(_ value: String) -> Bool {
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "password"
    }

    private static func isForbiddenInAttributeName(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case " ", "\t", "\n", "\r", "\u{000C}", "\"", "'", "<", ">", "/", "=":
            return true
        default:
            return scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F)
        }
    }
}
