//
//  MultipartFuzzTests.swift
//  WSwiftUITests
//
//  Seeded, deterministic fuzzing of every WebData body path: hostile input may lose
//  fields, but it must never trap.
//

import Foundation
import Testing
@testable import WSwiftUI

@Suite("Request body fuzzing")
struct MultipartFuzzTests {

    /// Pieces that steer mutations towards the parser's decision points.
    private static func tokens(boundary: String) -> [Data] {
        let text = ["\r\n", "\n", "\r", "\r\n\r\n", "--", "-", "\"", ";", "=", ":", " ", "\t",
                    boundary, "--\(boundary)", "\r\n--\(boundary)", "--\(boundary)--", "\n--\(boundary)",
                    "name=", "name=\"", "filename=", "filename*=", "filename*=utf-8''%", "Content-Disposition:",
                    "content-disposition: form-data;", "Content-Type:", "Content-Type: ", "form-data", "%", "é", "名"]
        return text.map { Data($0.utf8) } + [Data([0xFF]), Data([0xC3]), Data([0x00]), Data([0xE2, 0x80])]
    }

    private static func mutate(_ body: inout Data, _ random: inout MultipartRandom, tokens: [Data], donors: [Data]) {
        for _ in 0..<(1 + random.int(below: 6)) {
            let count = body.count
            let at = random.int(below: count + 1)
            switch random.int(below: 9) {
                case 0 where count > 0:
                    body[random.int(below: count)] = random.byte()
                case 1:
                    body.insert(contentsOf: random.pick(tokens), at: at)
                case 2 where count > 0:
                    let end = min(count, at + 1 + random.int(below: 64))
                    body.removeSubrange(at..<end)
                case 3:
                    body = body.prefix(at)
                case 4 where count > 0:
                    let start = random.int(below: count)
                    let slice = body[start..<min(count, start + 1 + random.int(below: 128))]
                    body.insert(contentsOf: Data(slice), at: at)
                case 5:
                    let donor = random.pick(donors)
                    guard donor.isEmpty == false else { continue }
                    let start = random.int(below: donor.count)
                    let slice = donor[start..<min(donor.count, start + 1 + random.int(below: 256))]
                    body.replaceSubrange(at..<min(count, at + random.int(below: 64)), with: slice)
                case 6:
                    body.insert(contentsOf: (0..<random.int(below: 16)).map { _ in random.byte() }, at: at)
                case 7 where random.int(below: 4) == 0:
                    // Switch every CRLF to a bare LF.
                    var out = Data()
                    var index = body.startIndex
                    while index < body.endIndex {
                        let next = body.index(after: index)
                        if body[index] == 0x0D, next < body.endIndex, body[next] == 0x0A {
                            index = next
                            continue
                        }
                        out.append(body[index])
                        index = next
                    }
                    body = out
                default:
                    body.append(random.pick(tokens))
            }
        }
    }

    private static func contentType(for boundary: String, _ random: inout MultipartRandom) -> String {
        let variants = [
            "multipart/form-data; boundary=\(boundary)",
            "multipart/form-data; boundary=\"\(boundary)\"",
            "multipart/form-data;boundary=\(boundary);charset=utf-8",
            "multipart/form-data; BOUNDARY=\(boundary)",
            "multipart/form-data",
            "multipart/form-data; boundary=",
            "multipart/form-data; boundary=\"",
            "multipart/form-data; boundary=\"\"",
            "multipart/form-data; boundary=\"\(boundary)",
            "multipart/form-data; boundary=\(boundary)\"; x=\"",
            "multipart/form-data; boundary=-",
            "multipart/form-data; boundary=\(boundary.prefix(1))",
            "multipart/form-data; boundary=\(String(repeating: "z", count: 300))",
            "multipart/form-data; ;;;=;=x; boundary",
            "multipart/form-data; boundary=\r\n",
            "application/x-www-form-urlencoded",
            "application/json",
            "text/plain",
            "",
        ]
        var type = random.pick(variants)
        if random.int(below: 5) == 0 {
            var bytes = Array(type.utf8)
            if bytes.isEmpty == false {
                bytes[random.int(below: bytes.count)] = UInt8(32 + random.int(below: 95))
            }
            type = String(decoding: bytes, as: UTF8.self)
        }
        return type
    }

    @Test func mutatedMultipartBodiesNeverTrap() {
        var random = MultipartRandom(seed: 0xC4_F022_0001)
        var samples: [(body: Data, boundary: String, contentType: String)] = []
        while samples.count < 24 {
            let sample = WellFormedMultipart.generate(&random)
            guard let boundary = MultipartParser.boundary(fromContentType: sample.contentType) else { continue }
            samples.append((sample.body, boundary, sample.contentType))
        }
        let donors = samples.map(\.body)
        var iterationsWithParts = 0

        for _ in 0..<20_000 {
            let sample = random.pick(samples)
            var body = sample.body
            Self.mutate(&body, &random, tokens: Self.tokens(boundary: sample.boundary), donors: donors)
            let type = random.int(below: 3) == 0 ? Self.contentType(for: sample.boundary, &random) : sample.contentType

            // Sometimes hand over a slice whose indices do not start at zero.
            let input: Data
            if random.bool() {
                var padded = Data((0..<(1 + random.int(below: 40))).map { _ in random.byte() })
                let offset = padded.count
                padded.append(body)
                input = padded[offset...]
            } else {
                input = body
            }

            let data = WebData()
            data.consume(["content-type": type])
            data.consume(input)
            #expect(data.files.count <= MultipartParser.maxParts)
            for file in data.files.values {
                #expect((file.data?.count ?? 0) <= body.count)
            }

            if Self.checkLocatedParts(in: input, boundary: sample.boundary) > 0 {
                iterationsWithParts += 1
            }
        }
        // The mutations must leave enough structure for the parser to get past the delimiters.
        #expect(iterationsWithParts > 5_000)
    }

    /// Ranges handed back by the splitter stay inside the body, in order, without overlap.
    @discardableResult
    private static func checkLocatedParts(in data: Data, boundary: String) -> Int {
        let parts = MultipartParser.locateParts(in: data, boundary: boundary)
        #expect(parts.count <= MultipartParser.maxParts)
        var previousEnd = 0
        for part in parts {
            #expect(part.headers.lowerBound >= previousEnd)
            #expect(part.headers.upperBound <= part.body.lowerBound)
            #expect(part.body.upperBound <= data.count)
            #expect(part.headers.count <= MultipartParser.maxHeaderBytesPerPart)
            previousEnd = part.body.upperBound
        }
        return parts.count
    }

    @Test func randomHeaderParameterStringsNeverTrap() {
        var random = MultipartRandom(seed: 0xC4_F022_0002)
        let pieces = ["name", "filename", "filename*", "boundary", "=", ";", "\"", "\\", " ", "\t", "a", "é", "名",
                      "''", "utf-8''%C3%A9", "%", ":", "form-data", "\r", "\n"]
        for _ in 0..<20_000 {
            let text = (0..<random.int(below: 24)).map { _ in random.pick(pieces) }.joined()
            let parameters = MultipartHeaderParameters.parse(text, skippingFirstSegment: random.bool())
            #expect(parameters.count <= text.unicodeScalars.filter { $0 == "=" }.count)
            _ = MultipartParser.boundary(fromContentType: text)
            _ = MultipartPartHeaders(parsing: "Content-Disposition:" + text + "\r\nContent-Type:" + text)
            for parameter in parameters {
                _ = MultipartHeaderParameters.decodeExtendedValue(parameter.value)
            }
        }
    }

    @Test func urlEncodedBodiesNeverTrap() {
        var random = MultipartRandom(seed: 0xC4_F022_0003)
        let pieces = ["a", "key", "=", "&", "&&", "==", "%", "%2", "%41", "%ZZ", "%C3", "%A9", "%C3%A9", "%00", "%FF", "+",
                      "é", "名", " ", ";", "\r\n", "x[]", "content-type"]
        for _ in 0..<20_000 {
            var body = Data((0..<random.int(below: 30)).map { _ in random.pick(pieces) }.joined().utf8)
            if random.int(below: 4) == 0 {
                body.insert(contentsOf: (0..<random.int(below: 6)).map { _ in random.byte() }, at: random.int(below: body.count + 1))
            }
            let data = WebData()
            data.consume(["content-type": "application/x-www-form-urlencoded"])
            data.consume(random.bool() ? body : (Data([0x26]) + body).dropFirst())
            _ = data.string("a")
            _ = data.int("key")
            _ = data.double("key")
            _ = data.bool("key")
            _ = data.uuid("key")
        }

        // Well-formed pairs still decode as before.
        let data = WebData()
        data.consume(["content-type": "application/x-www-form-urlencoded"])
        data.consume(Data("name=Ada%20Lovelace&n=42&flag=on&empty=&=orphan&bad=%ZZ".utf8))
        #expect(data.string("name") == "Ada Lovelace")
        #expect(data.int("n") == 42)
        #expect(data.bool("flag") == true)
        #expect(data.exists("empty") == false)
        #expect(data.string("bad") == "%ZZ")
    }

    @Test func jsonBodiesNeverTrap() throws {
        var random = MultipartRandom(seed: 0xC4_F022_0004)
        var samples: [Data] = [
            Data(#"{"reference":"r1","read":true,"write":false,"delay":5,"data":{"a":1,"b":"two","c":[1,2,{"d":null}]}}"#.utf8),
            Data(#"{"a":{"b":{"c":{"d":[true,false,1.5,-2e10,"x"]}}},"n":18446744073709551616,"m":-9223372036854775809}"#.utf8),
        ]
        while samples.count < 16 {
            samples.append(try JSONSerialization.data(withJSONObject: MultipartRandomJSON.object(&random, depth: 0)))
        }
        let backslashU = String(UnicodeScalar(92)) + "u"
        let tokens = ["{", "}", "[", "]", "\"", ",", ":", "1e999", "-", "0.", "null", "true", "{\"a\":",
                      "\(backslashU)0000", "\(backslashU)D800", "\(backslashU)", String(repeating: "[", count: 600),
                      String(repeating: "{\"k\":", count: 600)].map { Data($0.utf8) } + [Data([0xFF]), Data([0x00])]

        for _ in 0..<20_000 {
            var body = random.pick(samples)
            Self.mutate(&body, &random, tokens: tokens, donors: samples)
            let data = WebData()
            data.consume(["content-type": "application/json"])
            data.consume(body)
            _ = data.webVariableTransaction()
            _ = data.object([String: String].self)
            _ = data.string("a")
        }
    }

    @Test func deeplyNestedJSONDoesNotTrap() {
        for depth in [100, 511, 512, 513, 10_000, 200_000] {
            for (open, close) in [("[", "]"), ("{\"a\":", "}")] {
                let text = "{\"k\":" + String(repeating: open, count: depth) + "1" + String(repeating: close, count: depth) + "}"
                let data = WebData()
                data.consume(["content-type": "application/json"])
                data.consume(Data(text.utf8))
                _ = data.string("k")
            }
        }
    }
}

/// Random JSON-compatible values for fuzzing.
enum MultipartRandomJSON {
    static let keys = ["a", "b", "key", "naïve", "名", "with space", "dot.ted", "", "reference", "data"]

    static func string(_ random: inout MultipartRandom) -> String {
        let control = String(Character(Unicode.Scalar(UInt8(1))))
        let lineSeparator = String(Character(Unicode.Scalar(UInt32(0x2028))!))
        let pieces = ["x", "hello", "é", "名前", "😀", "\"", "\\", "\n", "\t", control, lineSeparator, "<script>", " "]
        return (0..<random.int(below: 6)).map { _ in random.pick(pieces) }.joined()
    }

    static func value(_ random: inout MultipartRandom, depth: Int) -> Any {
        switch random.int(below: depth > 3 ? 5 : 7) {
            case 0: return string(&random)
            case 1: return random.int(below: 1_000_000) - 500_000
            case 2: return Double(random.int(below: 10_000)) / 7
            case 3: return random.bool()
            case 4: return NSNull()
            case 5: return object(&random, depth: depth + 1)
            default: return (0..<random.int(below: 5)).map { _ in value(&random, depth: depth + 1) }
        }
    }

    static func object(_ random: inout MultipartRandom, depth: Int) -> [String: Any] {
        var out: [String: Any] = [:]
        for _ in 0..<random.int(below: 5) {
            out[random.pick(keys)] = value(&random, depth: depth)
        }
        return out
    }
}
