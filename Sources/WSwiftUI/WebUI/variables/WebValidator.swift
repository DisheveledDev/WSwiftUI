//
//  WebValidator.swift
//  WSwiftUI
//
//  Created by Adrian Herridge on 12/08/2025.
//

import Foundation

public enum ValidationCondition {
    case notEmpty
    case empty
    case atLeast(Int)
    case validURL
    case validEmail
    case validPhoneNumber
    case validDate
    case validJSON
    case validNumber
    
    var encoded: String {
        switch self {
            case .notEmpty: return "notEmpty"
            case .empty: return "empty"
            case .atLeast(let length): return "atLeast:\(length)"
            case .validURL: return "validURL"
            case .validEmail: return "validEmail"
            case .validPhoneNumber: return "validPhoneNumber"
            case .validDate: return "validDate"
            case .validJSON: return "validJSON"
            case .validNumber: return "validNumber"
        }
    }
}

public enum ValidateField {
    case named(String,[ValidationCondition])
}

private extension String {
    /// Full-string regex match using NSRegularExpression (works on Linux & macOS)
    func fullMatch(of pattern: String, caseInsensitive: Bool = false) -> Bool {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let m = regex.firstMatch(in: self, options: [], range: range) else { return false }
        return m.range == range
    }
}

public extension CoreWebEndpoint {
    /// Validates the submitted `fields` (form fields, or the `data` of a liveUpdate `WebVariableTransaction`)
    /// and returns `true` when every field passed.
    ///
    /// Every field is checked, so a re-rendered form can show all of its problems at once:
    /// - a field that was not submitted fails with "This field is required";
    /// - a field that fails a condition gets that condition's message (the last failing one);
    /// - the submitted value of every field, passing or failing, is recorded so the controls bound to it
    ///   show it again when the form is re-rendered. Password inputs never re-display it.
    ///
    /// Messages are stored as `ephemeralData["error_<name>"]`, values as `ephemeralData["previous_<name>"]`.
    func validateData(_ fields: [ValidateField]) -> Bool {
        var overallResult = true
        for field in fields {
            switch field {
                case .named(let name, let conditions):
                    if validateField(name, conditions) == false {
                        overallResult = false
                    }
            }
        }
        return overallResult
    }
}

fileprivate extension CoreWebEndpoint {

    static let missingFieldMessage = "This field is required"

    /// Checks one field and records its error and submitted value. Returns `true` when it passed.
    func validateField(_ name: String, _ conditions: [ValidationCondition]) -> Bool {
        guard let value = data.raw(name) ?? data.webVariableTransaction()?.data[name] else {
            ephemeralData["error_\(name)"] = Self.missingFieldMessage
            return false
        }

        // normalize value → String
        let valueString: String
        switch value {
            case let s as String:
                valueString = s
            case let w as JSONValue:
                valueString = Self.text(of: w)
            case let file as WebData.FilePart:
                // A file input: validated as its file name, empty when no file was chosen. A file is never
                // re-displayed, so nothing is recorded for it.
                let filename = file.filename ?? ""
                let chosen = filename.isEmpty == false || (file.data?.isEmpty == false)
                valueString = chosen ? (filename.isEmpty ? "file" : filename) : ""
            case let i as Int:
                valueString = String(i)
            case let d as Double:
                valueString = String(d)
            case let b as Bool:
                valueString = String(b)
            default:
                ephemeralData["error_\(name)"] = "Field has an unsupported value"
                return false
        }

        if (value is WebData.FilePart) == false {
            ephemeralData["previous_\(name)"] = value
        }

        var passed = true
        func fail(_ message: String) {
            passed = false
            ephemeralData["error_\(name)"] = message
        }

        for condition in conditions {
            switch condition {
                case .notEmpty:
                    if valueString.isEmpty {
                        fail("Field cannot be empty")
                    }
                case .empty:
                    if !valueString.isEmpty {
                        fail("Field must be empty")
                    }
                case .atLeast(let length):
                    if valueString.count < length {
                        fail("Field must be at least \(length) characters")
                    }
                case .validURL:
                    // Require a parsable URL with scheme + host
                    if let comps = URLComponents(string: valueString),
                       let scheme = comps.scheme, !scheme.isEmpty,
                       let host = comps.host, !host.isEmpty {
                        // ok
                    } else {
                        fail("Field must be a valid URL")
                    }
                case .validEmail:
                    // Simple email pattern; anchored full match
                    // matches: local@domain.tld (tld len ≥ 2)
                    let emailPattern = "^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
                    if !valueString.fullMatch(of: emailPattern) {
                        fail("Field must be a valid email address")
                    }
                case .validPhoneNumber:
                    // Very permissive: digits, + - ( ) spaces; length 7–15
                    let phonePattern = "^[0-9+\\-() ]{7,15}$"
                    if !valueString.fullMatch(of: phonePattern) {
                        fail("Field must be a valid phone number")
                    }
                case .validDate:
                    // yyyy-MM-dd
                    let df = DateFormatter()
                    df.locale = Locale(identifier: "en_US_POSIX")
                    df.timeZone = TimeZone(secondsFromGMT: 0)
                    df.dateFormat = "yyyy-MM-dd"
                    if df.date(from: valueString) == nil {
                        fail("Field must be a valid date (yyyy-MM-dd)")
                    }
                case .validJSON:
                    // depth-limited: a deeply nested value fails as invalid JSON instead of overflowing the stack
                    if (try? JSONBodyLimits.jsonObject(with: Data(valueString.utf8))) == nil {
                        fail("Field must be valid JSON")
                    }
                case .validNumber:
                    // Locale-agnostic numeric check
                    let trimmed = valueString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if Double(trimmed) == nil && Int(trimmed) == nil {
                        fail("Field must be a valid number")
                    }
            }
        }
        return passed
    }

    /// The text a transaction value is validated as: strings as they are, numbers and booleans as text,
    /// arrays and objects as JSON (so `.validJSON` and `.notEmpty` see what the client sent).
    static func text(of value: JSONValue) -> String {
        switch value {
            case .string(let str): return str
            case .int(let intVal): return String(intVal)
            case .double(let doubleVal): return String(doubleVal)
            case .bool(let boolVal): return String(boolVal)
            case .null: return ""
            case .array, .object:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                guard let data = try? encoder.encode(value) else { return "" }
                return String(decoding: data, as: UTF8.self)
        }
    }
}
