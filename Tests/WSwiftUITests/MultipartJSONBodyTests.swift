//
//  MultipartJSONBodyTests.swift
//  WSwiftUITests
//
//  The JSON body path of WebData: deep nesting must not overflow the stack, flattening
//  must not multiply a small body into gigabytes, and ordinary bodies flatten as before.
//

import Foundation
import Testing
@testable import WSwiftUI

@Suite("JSON body limits")
struct MultipartJSONBodyTests {

    private func consumeJSON(_ body: Data) -> WebData {
        let data = WebData()
        data.consume(["content-type": "application/json"])
        data.consume(body)
        return data
    }

    private func nested(_ depth: Int, open: String = "{\"a\":", close: String = "}", leaf: String = "1") -> String {
        String(repeating: open, count: depth) + leaf + String(repeating: close, count: depth)
    }

    // MARK: Nesting depth

    @Test func deepWebVariableTransactionDoesNotOverflowTheStack() {
        // Decoding JSONValue recursion overflowed a 512 KiB stack at about 200 levels.
        for depth in [150, 200, 300, 450] {
            for (open, close) in [("{\"a\":", "}"), ("[", "]")] {
                let body = #"{"reference":"r","read":true,"write":true,"data":{"k":"# + nested(depth, open: open, close: close) + "}}"
                let data = consumeJSON(Data(body.utf8))
                #expect(data.webVariableTransaction() == nil)
                #expect(data.string("reference") == nil)
            }
        }
    }

    @Test func deepObjectsDoNotOverflowJSONSerialization() {
        // JSONSerialization overflowed a 512 KiB stack at about 470 nested objects.
        for depth in [470, 480, 500, 510] {
            let data = consumeJSON(Data(("{\"k\":" + nested(depth) + "}").utf8))
            #expect(data.string("k") == nil)
            #expect(data.object([String: String].self) == nil)
        }
    }

    @Test func nestingUpToTheLimitStillParses() {
        let limit = JSONBodyLimits.maxNestingDepth
        // The outer object is one level, so `limit - 1` more objects reach the limit exactly.
        let atLimit = consumeJSON(Data(("{\"k\":" + nested(limit - 1) + ",\"top\":\"yes\"}").utf8))
        #expect(atLimit.string("top") == "yes")
        #expect(atLimit.string("k" + String(repeating: ".a", count: limit - 1)) == "1")

        let overLimit = consumeJSON(Data(("{\"k\":" + nested(limit) + ",\"top\":\"yes\"}").utf8))
        #expect(overLimit.string("top") == nil)
    }

    @Test func nestingScanIgnoresBracketsInsideStrings() {
        let many = String(repeating: "[{", count: 200)
        #expect(JSONBodyLimits.nestingExceedsLimit(Data(#"{"a":"\#(many)"}"#.utf8)) == false)
        #expect(JSONBodyLimits.nestingExceedsLimit(Data(#"{"a":"\"\#(many)\""}"#.utf8)) == false)
        #expect(JSONBodyLimits.nestingExceedsLimit(Data(#"{"\#(many)":1}"#.utf8)) == false)
        // An escaped backslash before the closing quote really does close the string.
        #expect(JSONBodyLimits.nestingExceedsLimit(Data(#"{"a\\":\#(String(repeating: "[", count: 70))"#.utf8)) == true)
        // Closing brackets before opening ones cannot buy extra depth.
        #expect(JSONBodyLimits.nestingExceedsLimit(Data((String(repeating: "]", count: 100) + String(repeating: "[", count: 65)).utf8)) == true)
        #expect(JSONBodyLimits.nestingExceedsLimit(Data(nested(64, open: "[", close: "]").utf8)) == false)
        #expect(JSONBodyLimits.nestingExceedsLimit(Data(nested(65, open: "[", close: "]").utf8)) == true)
        #expect(JSONBodyLimits.nestingExceedsLimit(Data()) == false)

        // A string with brackets is still consumed.
        let data = consumeJSON(Data(#"{"a":"\#(many)"}"#.utf8))
        #expect(data.string("a") == many)
    }

    private func utf16LE(_ text: String) -> Data {
        var data = Data()
        for unit in text.utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        return data
    }

    @Test func wideEncodedBodiesAreCountedConservatively() {
        // Ordinary UTF-16 JSON is still read wherever Foundation reads it.
        let wide = utf16LE(#"{"a":"b","n":[1,2]}"#)
        if (try? JSONSerialization.jsonObject(with: wide)) != nil {
            let small = consumeJSON(wide)
            #expect(small.string("a") == "b")
            #expect(small.string("n") == "1,2")
        }

        // In UTF-16 the code unit U+7D7D is the bytes 7D 7D, which look like two closing braces.
        // They must not hide real nesting from the scan.
        let lookalike = String(Character(Unicode.Scalar(0x7D7D)!))
        let hidden = String(repeating: "{\"\(lookalike)\(lookalike)\":", count: 500) + "1" + String(repeating: "}", count: 500)
        #expect(JSONBodyLimits.nestingExceedsLimit(utf16LE(hidden)) == true)
        _ = consumeJSON(utf16LE(hidden))

        var bom = Data([0xFF, 0xFE])
        bom.append(utf16LE(nested(100)))
        #expect(JSONBodyLimits.nestingExceedsLimit(bom) == true)
    }

    // MARK: Flatten limit

    private struct TopField: Decodable {
        let top: String
    }

    /// A transaction-shaped body whose `parent` key (64 KiB) holds `children` small fields.
    /// Each flattened child key repeats the whole parent key.
    private func prefixAmplified(children: Int) -> (body: Data, parent: String) {
        let parent = String(repeating: "p", count: 64 * 1024)
        let fields = (0..<children).map { "\"k\($0)\":1" }.joined(separator: ",")
        let body = #"{"reference":"r","read":true,"write":false,"data":{},"top":"t","\#(parent)":{\#(fields)}}"#
        return (Data(body.utf8), parent)
    }

    @Test func bodyOverTheLimitKeepsNoFieldsOnEveryRun() throws {
        // ~80 KB of body would become ~130 MB of keys.
        let (body, parent) = prefixAmplified(children: 2000)
        let dict = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let limit = JSONFlattenBudget.limit(forBodyBytes: body.count)
        #expect(JSONFlattenBudget.flattenedSize(of: dict, limit: .max) > limit)

        // Before, a random subset of keys survived, different on every run. Now none do.
        for _ in 0..<3 {
            let data = consumeJSON(body)
            #expect(data.string("top") == nil)
            #expect(data.string("reference") == nil)
            #expect((0..<2000).contains { data.exists("\(parent).k\($0)") } == false)
            // The body is still there for typed decoding and as a transaction.
            #expect(data.object(TopField.self)?.top == "t")
            #expect(data.webVariableTransaction()?.reference == "r")
        }
    }

    @Test func amplifiedBodyUnderTheLimitKeepsEveryKey() throws {
        // ~20 MB of keys: over the old 16 MiB budget, which kept only some of them.
        let (body, parent) = prefixAmplified(children: 300)
        let data = consumeJSON(body)
        #expect((0..<300).allSatisfy { data.string("\(parent).k\($0)") == "1" })
        #expect(data.string("top") == "t")
        #expect(data.string("reference") == "r")
    }

    @Test func arrayDescriptionOverTheLimitKeepsNoFields() throws {
        // Darwin's description of a nested NSDictionary indents every line by its depth, so each
        // element below grows from ~18 KB of JSON to ~500 KB of description.
        let leaves = "{" + (0..<2000).map { "\"k\($0)\":1" }.joined(separator: ",") + "}"
        let element = nested(60, leaf: leaves)
        let body = Data(("{\"x\":[" + Array(repeating: element, count: 100).joined(separator: ",") + "],\"top\":\"t\"}").utf8)
        let dict = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(JSONFlattenBudget.flattenedSize(of: dict, limit: .max) > JSONFlattenBudget.limit(forBodyBytes: body.count))

        let data = consumeJSON(body)
        #expect(data.exists("x") == false)
        #expect(data.exists("top") == false)
        #expect(data.object(TopField.self)?.top == "t")
    }

    /// `count` records of five numbers under data.records, keyed by a UUID-shaped id: about 71
    /// bytes of body per record, about four times that once flattened.
    private func nestedRecords(_ count: Int) -> (body: Data, ids: [String]) {
        func hex(_ value: Int, width: Int) -> String {
            let digits = String(value, radix: 16, uppercase: true)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        let ids = (0..<count).map { "\(hex($0, width: 8))-0000-4000-8000-\(hex($0 &* 7919, width: 12))" }
        let records = ids.map { #""\#($0)":{"a":1,"b":2,"c":3,"d":4,"e":5}"# }.joined(separator: ",")
        return (Data((#"{"data":{"records":{"# + records + "}}}").utf8), ids)
    }

    @Test func severalMegabytesOfNestedRecordsKeepEveryKey() {
        // Before, a body like this (7.1 MB) lost a different ~8% of its keys on every run.
        let (body, ids) = nestedRecords(100_000)
        #expect(body.count > 7_000_000)
        let data = consumeJSON(body)
        var missing = 0
        for id in ids {
            for (key, value) in [("a", "1"), ("b", "2"), ("c", "3"), ("d", "4"), ("e", "5")]
            where data.string("data.records.\(id).\(key)") != value {
                missing += 1
            }
        }
        #expect(missing == 0)
    }

    @Test func largeArrayValuesAreKept() {
        // The previous bound charged 8 bytes per string byte and ~100 bytes per node, so both
        // of these arrays were left out, although their descriptions are 3 MB and 1.4 MB.
        let base64 = String(repeating: "a", count: 3 * 1024 * 1024)
        let attachments = Data(#"{"title":"t","attachments":[{"name":"a.png","base64":"\#(base64)"}]}"#.utf8)
        let matrix = Data(("{\"matrix\":[[" + (0..<200_000).map { String($0 % 10) }.joined(separator: ",") + "]]}").utf8)
        for (body, key) in [(attachments, "attachments"), (matrix, "matrix")] {
            let data = consumeJSON(body)
            let legacy = MultipartLegacyJSONFlatten.flatten(body)
            #expect(data.exists(key), "\(key)")
            #expect(data.string(key) == legacy[key], "\(key)")
        }
    }

    @Test func validateDataStillSeesLargeArrays() throws {
        let server = TestHTTP.server()
        server.register(MultipartValidateAPI())
        let base64 = String(repeating: "a", count: 3 * 1024 * 1024)
        let body = Data(#"{"title":"t","attachments":[{"name":"a.png","base64":"\#(base64)"}]}"#.utf8)
        let request = TestHTTP.request(.POST, "/multipart-validate",
                                       headers: [("Content-Type", "application/json")], body: body)
        let response = server.respond(to: request)
        #expect(response.status.code == 200)
        let result = try JSONDecoder().decode([String: String].self, from: response.bodyBytes)
        #expect(result["notEmpty"] == "true")
    }

    @Test func flattenedSizeCoversWhatFlattenStores() throws {
        var random = MultipartRandom(seed: 0xF1A7_7E25)
        for _ in 0..<500 {
            let body = try JSONSerialization.data(withJSONObject: MultipartRandomJSON.object(&random, depth: 0))
            let dict = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let stored = MultipartLegacyJSONFlatten.flatten(body).reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            #expect(JSONFlattenBudget.flattenedSize(of: dict, limit: .max) >= stored)
        }

        // Exact for keys and scalars: "a"+"x", "n"+"1", the nested prefix "o", then "o.b"+"yz".
        let exact = try #require(try JSONSerialization.jsonObject(with: Data(#"{"a":"x","n":1,"o":{"b":"yz"}}"#.utf8)) as? [String: Any])
        #expect(JSONFlattenBudget.flattenedSize(of: exact, limit: .max) == 2 + 2 + 1 + 5)
        // Counting stops once the limit is passed.
        #expect(JSONFlattenBudget.flattenedSize(of: exact, limit: 3) > 3)
        #expect(JSONFlattenBudget.flattenedSize(of: [:], limit: 0) == 0)
    }

    @Test func descriptionSizeBoundIsAnUpperBound() throws {
        var random = MultipartRandom(seed: 0x15_0B0D)
        for _ in 0..<600 {
            let object = MultipartRandomJSON.object(&random, depth: 0)
            let parsed = try JSONSerialization.jsonObject(with: try JSONSerialization.data(withJSONObject: object))
            for value in (parsed as? [String: Any] ?? [:]).values {
                let actual = "\(value)".utf8.count
                #expect(JSONFlattenBudget.descriptionSizeBound(of: value, limit: .max) >= actual)
            }
        }
        let deep = try JSONSerialization.jsonObject(with: Data(nested(60, leaf: #"{"é\"\\":"😀\n","b":[1,null,true,"x"]}"#).utf8))
        #expect(JSONFlattenBudget.descriptionSizeBound(of: deep, limit: .max) >= "\(deep)".utf8.count)

        // Deep mixed chains, as deep as the nesting limit allows.
        for _ in 0..<200 {
            var value: Any = MultipartRandomJSON.value(&random, depth: 4)
            for _ in 0..<random.int(below: JSONBodyLimits.maxNestingDepth - 2) {
                if random.bool() {
                    value = [random.pick(MultipartRandomJSON.keys): value, "s": MultipartRandomJSON.string(&random)]
                } else {
                    value = [value, MultipartRandomJSON.string(&random), random.int(below: 99)]
                }
            }
            let parsed = try JSONSerialization.jsonObject(with: try JSONSerialization.data(withJSONObject: ["v": value]))
            let inner = (parsed as? [String: Any])?["v"] ?? NSNull()
            #expect(JSONFlattenBudget.descriptionSizeBound(of: inner, limit: .max) >= "\(inner)".utf8.count)
        }
    }

    @Test func descriptionSizeBoundHoldsForTheWorstEscapes() throws {
        // Strings that escape the most on either platform, and numbers with long descriptions.
        func scalar(_ value: UInt32) -> String { String(Character(Unicode.Scalar(value)!)) }
        let pieces = [scalar(0), scalar(1), scalar(0x1F), scalar(0x7F), scalar(0x85), scalar(0xAD), scalar(0x200B),
                      scalar(0x2028), scalar(0xFEFF), scalar(0xE0001), scalar(0x1F600), "é", "e" + scalar(0x301),
                      "\"", "\\", "\n", "\t", "\r", "'", "<null>", "a.b", " "]
        var random = MultipartRandom(seed: 0xE5CA_9E5)
        for _ in 0..<300 {
            func text() -> String { (0..<random.int(below: 40)).map { _ in random.pick(pieces) }.joined() }
            let element: Any
            if random.bool() {
                var dictionary: [String: Any] = [:]
                dictionary[text()] = [text(), [text(): text()]] as [Any]
                dictionary[text()] = [text()]
                element = dictionary
            } else {
                element = [[text(), text()], [text(): [[text()]]]] as [Any]
            }
            let parsed = try JSONSerialization.jsonObject(with: try JSONSerialization.data(withJSONObject: ["v": element]))
            let inner = try #require((parsed as? [String: Any])?["v"])
            #expect(JSONFlattenBudget.descriptionSizeBound(of: inner, limit: .max) >= "\(inner)".utf8.count)
        }
        for piece in pieces {
            let repeated = String(repeating: piece, count: 50)
            // Swift describes a string inside a container by its debug description.
            #expect(JSONFlattenBudget.quotedStringBound(repeated) >= String(reflecting: repeated).utf8.count)
            // And the Foundation containers JSONSerialization returns, as a value and as a key.
            for json in [["v": [[repeated]]], ["v": [[repeated: 1]]]] as [[String: Any]] {
                let parsed = try JSONSerialization.jsonObject(with: try JSONSerialization.data(withJSONObject: json))
                let inner = try #require(((parsed as? [String: Any])?["v"] as? [Any])?.first)
                #expect(JSONFlattenBudget.descriptionSizeBound(of: inner, limit: .max) >= "\(inner)".utf8.count)
            }
        }

        let numbers = #"{"v":[[123456789012345678901234567890123456789e100,1234567890123456789012345678901234567890123456789012345678901234567890,1e-300,-0.0,1.7976931348623157e308,0.1,-1,true,false,null],{"n":[123456789012345678901234567890123456789e100]}]}"#
        let parsed = try JSONSerialization.jsonObject(with: Data(numbers.utf8))
        let inner = try #require((parsed as? [String: Any])?["v"] as? [Any])
        for element in inner {
            #expect(JSONFlattenBudget.descriptionSizeBound(of: element, limit: .max) >= "\(element)".utf8.count)
        }
    }

    @Test func limitScalesWithBodySize() {
        #expect(JSONFlattenBudget.limit(forBodyBytes: 0) == JSONFlattenBudget.minimumBytes)
        #expect(JSONFlattenBudget.limit(forBodyBytes: -1) == JSONFlattenBudget.minimumBytes)
        #expect(JSONFlattenBudget.limit(forBodyBytes: 10) == JSONFlattenBudget.minimumBytes)
        #expect(JSONFlattenBudget.limit(forBodyBytes: 10 * 1024 * 1024) == 160 * 1024 * 1024)
        #expect(JSONFlattenBudget.limit(forBodyBytes: .max) == .max)
    }

    // MARK: Ordinary bodies

    @Test func ordinaryBodiesFlattenAsBefore() throws {
        var random = MultipartRandom(seed: 0x0DD_B0D1)
        var samples = [
            Data(#"{"reference":"r1","read":true,"write":false,"delay":5,"data":{"a":1,"b":"two"}}"#.utf8),
            Data(#"{"a":{"b":{"c":[1,2.5,"x",true,null,[1,[2]],{"k":"v"}]}},"t":"naïve","e":"","z":-0.0,"big":12345678901234567890}"#.utf8),
            Data(#"{"list":[{"id":1},{"id":2}],"nested":{"empty":{},"arr":[]}}"#.utf8),
        ]
        for _ in 0..<300 {
            samples.append(try JSONSerialization.data(withJSONObject: MultipartOrderStableJSON.object(&random, depth: 0)))
        }
        for body in samples {
            let data = consumeJSON(body)
            let legacy = MultipartLegacyJSONFlatten.flatten(body)
            for (key, value) in legacy {
                #expect(data.string(key) == value, "key \(key)")
            }
        }

        let transaction = consumeJSON(samples[0]).webVariableTransaction()
        #expect(transaction?.reference == "r1")
        #expect(transaction?.data["a"] == .int(1))
    }

    // MARK: On the server's worker threads

    @Test func deepBodiesAreAnsweredOnAWorkerThread() {
        // Production requests run on GCD worker threads with 512 KiB stacks.
        let codes = multipartOnWorkerThread { () -> [Int] in
            let server = TestHTTP.server()
            server.register(MultipartEchoAPI())
            var codes: [Int] = []
            for depth in [600, 5_000, 100_000] {
                for (open, close) in [("{\"a\":", "}"), ("[", "]")] {
                    let body = #"{"reference":"r","read":true,"write":true,"data":{"k":"# + nested(depth, open: open, close: close) + "}}"
                    let request = TestHTTP.request(.POST, "/multipart-echo",
                                                   headers: [("Content-Type", "application/json")],
                                                   body: Data(body.utf8))
                    codes.append(server.respond(to: request).status.code)
                }
            }
            return codes
        }
        #expect(codes == Array(repeating: 200, count: 6))
    }

    @Test func requestJSONHelperRefusesDeepInputOnAWorkerThread() {
        // validateData(.validJSON) and CoreWebEndpoint parse request field values with
        // JSONSerialization directly; this is the helper they should use instead. The value here
        // arrives as an url-encoded form field, so it never passes through consumeJSON.
        let outcomes = multipartOnWorkerThread { () -> [String] in
            var outcomes: [String] = []
            for depth in [600, 5_000, 100_000] {
                for (open, close) in [("{\"a\":", "}"), ("[", "]")] {
                    let json = nested(depth, open: open, close: close)
                    let encoded = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                    let data = WebData()
                    data.consume(["content-type": "application/x-www-form-urlencoded"])
                    data.consume(Data("payload=\(encoded)".utf8))
                    let value = data.string("payload") ?? ""
                    do {
                        _ = try JSONBodyLimits.jsonObject(with: Data(value.utf8))
                        outcomes.append("parsed")
                    } catch JSONBodyLimits.ParseError.nestingTooDeep {
                        outcomes.append(value == json ? "refused" : "garbled")
                    } catch {
                        outcomes.append("other error")
                    }
                }
            }
            return outcomes
        }
        #expect(outcomes == Array(repeating: "refused", count: 6))
    }

    @Test func requestJSONHelperParsesOrdinaryInput() throws {
        let limit = JSONBodyLimits.maxNestingDepth
        let atLimit = try JSONBodyLimits.jsonObject(with: Data(nested(limit - 1, leaf: "[1]").utf8))
        #expect(atLimit is [String: Any])
        let fragment = try JSONBodyLimits.jsonObject(with: Data("\"x\"".utf8), options: [.fragmentsAllowed])
        #expect(fragment as? String == "x")
        #expect(throws: JSONBodyLimits.ParseError.nestingTooDeep) {
            try JSONBodyLimits.jsonObject(with: Data(nested(limit, leaf: "[1]").utf8))
        }
        // Invalid JSON still throws JSONSerialization's own error.
        #expect(throws: (any Error).self) { try JSONBodyLimits.jsonObject(with: Data("{".utf8)) }
        #expect((try? JSONBodyLimits.jsonObject(with: Data("{".utf8))) == nil)
    }
}

/// Answers whether validateData accepts the request's "attachments" field.
final class MultipartValidateAPI: CoreWebEndpoint, WebEndpoint, WebApiEndpoint {
    var controller: String? = "multipart-validate"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    func acceptedRoles() -> [String]? { nil }

    func call() -> Any? {
        let valid = validateData([.named("attachments", [.notEmpty])])
        return HttpResponse().status(.ok).content(.json).body(json: ["notEmpty": valid ? "true" : "false"])
    }
}

/// Holds a result handed from a worker thread back to the waiting test.
final class MultipartResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// Runs `work` on a GCD worker thread, the kind that serves requests (512 KiB stack), and waits
/// for its result. `async` is used because `sync` would run the block on the calling thread.
func multipartOnWorkerThread<T>(_ work: @escaping @Sendable () -> T) -> T {
    let queue = DispatchQueue(label: "multipart.tests.worker", qos: .userInitiated, attributes: .concurrent)
    let box = MultipartResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    queue.async {
        box.value = work()
        done.signal()
    }
    done.wait()
    return box.value!
}

/// The pre-fix flattening, copied verbatim apart from returning its results.
enum MultipartLegacyJSONFlatten {
    static func flatten(_ data: Data) -> [String: String] {
        var combined: [String: String] = [:]
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return combined }

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
        return combined
    }
}

/// Random JSON whose array elements describe the same way however a dictionary is ordered
/// (scalars, arrays, single-key objects), so two parses can be compared exactly.
enum MultipartOrderStableJSON {
    static func element(_ random: inout MultipartRandom, depth: Int) -> Any {
        switch random.int(below: depth > 3 ? 4 : 6) {
            case 0: return MultipartRandomJSON.string(&random)
            case 1: return random.int(below: 100_000) - 50_000
            case 2: return random.bool()
            case 3: return NSNull()
            case 4: return [random.pick(MultipartRandomJSON.keys): element(&random, depth: depth + 1)]
            default: return (0..<random.int(below: 4)).map { _ in element(&random, depth: depth + 1) }
        }
    }

    static func object(_ random: inout MultipartRandom, depth: Int) -> [String: Any] {
        var out: [String: Any] = [:]
        for _ in 0..<(1 + random.int(below: 5)) {
            let key = random.pick(MultipartRandomJSON.keys)
            switch random.int(below: depth > 3 ? 2 : 4) {
                case 0: out[key] = element(&random, depth: depth)
                case 1: out[key] = Double(random.int(below: 10_000)) / 8
                case 2: out[key] = object(&random, depth: depth + 1)
                default: out[key] = (0..<random.int(below: 5)).map { _ in element(&random, depth: depth + 1) }
            }
        }
        return out
    }
}
