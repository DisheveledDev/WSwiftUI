//
//  WebData.swift
//  WSwiftUI
//
//  Created by Adrian on 27/07/2025.
//

import Foundation

public class WebData {
    
    private var jsonBody: Data? = nil
    private var combined: [String: String] = [:]
    private var wVarTransaction: WebVariableTransaction?
    
    public struct FilePart {
        public let fieldName: String
        public let filename: String?
        public let contentType: String?
        public let data: Data?
    }
    private(set) var files: [String: FilePart] = [:]
    
    public func consume(_ data: [String: String]) {
        for (k, v) in data {
            combined[k] = v
        }
    }
    
    public func consume(_ body: [UInt8]) {
        let data = Data(body)
        consume(data)
    }
    
    public func consume(_ body: Data) {
        let contentType = combined["content-type"] ?? ""
        
        if contentType.contains("application/json") {
            consumeJSON(body)
        } else if contentType.contains("application/x-www-form-urlencoded") {
            consumeURLEncoded(body)
        } else if contentType.contains("multipart/form-data"),
                  let boundary = boundary(from: contentType) {
            // In-memory multipart path (unchanged)
            consumeMultipart(body, boundary: boundary)
        } else {
            if let text = String(data: body, encoding: .utf8) {
                combined["body"] = text
            }
        }
    }
    
    public func consume(_ body: HttpBody) {
        switch body {
            case .none:
                break
            case .inMemory(let mem):
                consume(mem)
        }
    }
    
    private func consumeJSON(_ data: Data) {
        
        // Foundation's JSON parsers recurse once per nesting level, so a deeply nested body can
        // overflow a worker thread's stack. Such a body is ignored, like any other unreadable one,
        // and is not kept for object(_:) either.
        guard JSONBodyLimits.nestingExceedsLimit(data) == false else { return }
        
        jsonBody = data
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return }
        
        if let wVar = try? JSONDecoder().decode(WebVariableTransaction.self, from: data) {
            wVarTransaction = wVar
        }
        
        // Flattened keys repeat their parent's path and array values are descriptions, so a
        // hostile body could expand many times over. Measure what flattening would copy first: a
        // body over the limit keeps no fields at all, the same way on every run, and is still
        // available to object(_:) and webVariableTransaction().
        let flattenLimit = JSONFlattenBudget.limit(forBodyBytes: data.count)
        guard JSONFlattenBudget.flattenedSize(of: dict, limit: flattenLimit) <= flattenLimit else { return }

        // Keep these cases in step with JSONFlattenBudget.flattenedSize.
        func flatten(_ dict: [String: Any], prefix: String? = nil) {
            for (key, value) in dict {
                let fullKey = prefix.map { "\($0).\(key)" } ?? key
                switch value {
                    case let s as String:
                        combined[fullKey] = s
                    case let n as NSNumber:
                        combined[fullKey] = n.stringValue
                    case let b as Bool:
                        combined[fullKey] = b.description
                    case let d as Double:
                        combined[fullKey] = String(d)
                    case let sub as [String: Any]:
                        flatten(sub, prefix: fullKey)
                    case let arr as [Any]:
                        let items = arr.compactMap { "\($0)" }
                        combined[fullKey] = items.joined(separator: ",")
                    default:
                        continue
                }
            }
        }
        
        flatten(dict)
    }
    
    private func consumeURLEncoded(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        let pairs = s.split(separator: "&")
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let rawKey = String(parts[0])
            let rawVal = String(parts[1])
            let key = rawKey.removingPercentEncoding ?? rawKey
            let val = rawVal.removingPercentEncoding ?? rawVal
            combined[key] = val
        }
    }
    
    // MARK: - In-memory multipart
    // Parsing is bounds-checked and capped (see MultipartParser); hostile bodies yield fewer parts, never a trap.
    private func consumeMultipart(_ data: Data, boundary: String) {
        for part in MultipartParser.parse(data, boundary: boundary) {
            if let fn = part.filename {
                // A repeated name (e.g. several "files[]") keeps the last part, as before.
                files[part.name] = FilePart(fieldName: part.name, filename: fn, contentType: part.contentType, data: Data(part.body))
            } else if let text = String(data: part.body, encoding: .utf8)?.trimmingCharacters(in: .newlines) {
                combined[part.name] = text
            }
        }
    }
    
    private func boundary(from contentType: String) -> String? {
        return MultipartParser.boundary(fromContentType: contentType)
    }
    
    // MARK: – Accessors
    public func webVariableTransaction() -> WebVariableTransaction? {
        return wVarTransaction
    }
    public func raw(_ key: String) -> Any? {
        if let value = combined[key] {
            return value
        } else if let filePart = files[key] {
            return filePart
        }
        return nil
    }
    public func exists(_ key: String) -> Bool {
        return combined[key] != nil
    }
    public func string(_ key: String) -> String? {
        return combined[key]
    }
    public func int(_ key: String) -> Int? {
        guard let v = combined[key] else { return nil }
        return Int(v)
    }
    public func double(_ key: String) -> Double? {
        guard let v = combined[key] else { return nil }
        return Double(v)
    }
    public func bool(_ key: String) -> Bool? {
        guard let v = combined[key]?.lowercased() else { return nil }
        if v == "true" || v == "1" || v == "on" { return true }
        if v == "false" || v == "0" || v == "off" { return false }
        return Bool(v)
    }
    public func uuid(_ key: String) -> UUID? {
        guard let v = combined[key] else { return nil }
        return UUID(uuidString: v)
    }
    public func file(_ key: String) -> FilePart? {
        return files[key]
    }
    public func object<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = jsonBody else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

