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
    func validateData(_ fields: [ValidateField]) -> Bool {
        var overallResult = true
        
        for field in fields {
            switch field {
                case .named(let name, let conditions):
                    guard let value = data.raw(name) ?? data.webVariableTransaction()?.data[name] else {
                        return false
                    }
                    
                    // normalize value → String
                    let valueString: String
                    if let s = value as? String {
                        valueString = s
                    } else if let i = value as? Int {
                        valueString = String(i)
                    } else if let d = value as? Double {
                        valueString = String(d)
                    } else if let b = value as? Bool {
                        valueString = String(b)
                    } else if let w = value as? JSONValue {
                        switch w {
                            case .string(let str): valueString = str
                            case .int(let intVal): valueString = String(intVal)
                            case .double(let doubleVal): valueString = String(doubleVal)
                            case .bool(let boolVal): valueString = String(boolVal)
                            case .array(let arr): valueString = arr.description
                            case .object(let obj): valueString = obj.description
                            case .null: valueString = ""
                        }
                    } else {
                        return false
                    }
                    
                    for condition in conditions {
                        switch condition {
                            case .notEmpty:
                                if valueString.isEmpty {
                                    overallResult = false
                                    ephemeralData["error_\(name)"] = "Field cannot be empty"
                                    ephemeralData["previous_\(name)"] = value
                                }
                            case .empty:
                                if !valueString.isEmpty {
                                    overallResult = false
                                    ephemeralData["error_\(name)"] = "Field must be empty"
                                    ephemeralData["previous_\(name)"] = value
                                }
                            case .atLeast(let length):
                                if valueString.count < length {
                                    overallResult = false
                                    ephemeralData["error_\(name)"] = "Field must be at least \(length) characters"
                                    ephemeralData["previous_\(name)"] = value
                                }
                            case .validURL:
                                // Require a parsable URL with scheme + host
                                if let comps = URLComponents(string: valueString),
                                   let scheme = comps.scheme, !scheme.isEmpty,
                                   let host = comps.host, !host.isEmpty {
                                    // ok
                                } else {
                                    overallResult = false
                                    ephemeralData["error_\(name)"] = "Field must be a valid URL"
                                    ephemeralData["previous_\(name)"] = value
                                }
                            case .validEmail:
                                // Simple email pattern; anchored full match
                                // matches: local@domain.tld (tld len ≥ 2)
                                let emailPattern = "^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
                                if !valueString.fullMatch(of: emailPattern) {
                                    overallResult = false
                                    ephemeralData["error_\(name)"] = "Field must be a valid email address"
                                    ephemeralData["previous_\(name)"] = value
                                }
                            case .validPhoneNumber:
                                // Very permissive: digits, + - ( ) spaces; length 7–15
                                let phonePattern = "^[0-9+\\-() ]{7,15}$"
                                if !valueString.fullMatch(of: phonePattern) {
                                    overallResult = false
                                    ephemeralData["error_\(name)"] = "Field must be a valid phone number"
                                    ephemeralData["previous_\(name)"] = value
                                }
                            case .validDate:
                                // yyyy-MM-dd
                                let df = DateFormatter()
                                df.locale = Locale(identifier: "en_US_POSIX")
                                df.timeZone = TimeZone(secondsFromGMT: 0)
                                df.dateFormat = "yyyy-MM-dd"
                                if df.date(from: valueString) == nil {
                                    overallResult = false
                                    ephemeralData["error_\(name)"] = "Field must be a valid date (yyyy-MM-dd)"
                                    ephemeralData["previous_\(name)"] = value
                                }
                            case .validJSON:
                                if let d = valueString.data(using: .utf8) {
                                    do {
                                        // depth-limited: a deeply nested value fails as invalid JSON instead of overflowing the stack
                                        _ = try JSONBodyLimits.jsonObject(with: d)
                                    } catch {
                                        overallResult = false
                                        ephemeralData["error_\(name)"] = "Field must be valid JSON"
                                        ephemeralData["previous_\(name)"] = value
                                    }
                                } else {
                                    overallResult = false
                                    ephemeralData["error_\(name)"] = "Field must be valid JSON"
                                    ephemeralData["previous_\(name)"] = value
                                }
                            case .validNumber:
                                // Locale-agnostic numeric check
                                let trimmed = valueString.trimmingCharacters(in: .whitespacesAndNewlines)
                                if Double(trimmed) == nil && Int(trimmed) == nil {
                                    overallResult = false
                                    ephemeralData["error_\(name)"] = "Field must be a valid number"
                                    ephemeralData["previous_\(name)"] = value
                                }
                        }
                    }
            }
        }
        return overallResult
    }
}
