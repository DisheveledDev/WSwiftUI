//
//  MultipartParsingTests.swift
//  WSwiftUITests
//
//  Phase 0 / C4: multipart parsing must never trap, and must parse well-formed
//  bodies exactly as before.
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Shared helpers for the multipart slice's tests

enum MultipartTestKit {

    struct Part {
        var headers: [String]
        var body: Data

        init(_ headers: [String], _ body: Data) {
            self.headers = headers
            self.body = body
        }

        init(_ headers: [String], _ body: String) {
            self.init(headers, Data(body.utf8))
        }
    }

    /// A multipart body: each part is `--boundary`, its header lines, a blank line, the content.
    static func body(boundary: String,
                     _ parts: [Part],
                     closing: Bool = true,
                     eol: String = "\r\n",
                     preamble: String = "",
                     epilogue: String = "") -> Data {
        var data = Data(preamble.utf8)
        for part in parts {
            data.append(Data("--\(boundary)\(eol)".utf8))
            for header in part.headers {
                data.append(Data("\(header)\(eol)".utf8))
            }
            data.append(Data(eol.utf8))
            data.append(part.body)
            data.append(Data(eol.utf8))
        }
        if closing {
            data.append(Data("--\(boundary)--\(eol)".utf8))
            data.append(Data(epilogue.utf8))
        }
        return data
    }

    static func consume(_ body: Data, contentType: String) -> WebData {
        let data = WebData()
        data.consume(["content-type": contentType])
        data.consume(body)
        return data
    }

    static func consume(_ body: String, contentType: String) -> WebData {
        consume(Data(body.utf8), contentType: contentType)
    }

    static func disposition(_ name: String, filename: String? = nil) -> String {
        var header = "Content-Disposition: form-data; name=\"\(name)\""
        if let filename {
            header += "; filename=\"\(filename)\""
        }
        return header
    }
}

/// Echoes what the endpoint's WebData parsed, so tests can drive the real dispatch path.
final class MultipartEchoAPI: CoreWebEndpoint, WebEndpoint, WebApiEndpoint {
    var controller: String? = "multipart-echo"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    func acceptedRoles() -> [String]? { nil }

    func call() -> Any? {
        var out: [String: String] = [:]
        for key in ["", "title", "after"] {
            if let value = data.string(key) {
                out["field:\(key)"] = value
            }
        }
        for key in ["", "file", "files[]"] {
            if let file = data.file(key) {
                out["file:\(key):filename"] = file.filename ?? "<nil>"
                out["file:\(key):contentType"] = file.contentType ?? "<nil>"
                out["file:\(key):size"] = String(file.data?.count ?? -1)
            }
        }
        return HttpResponse().status(.ok).content(.json).body(json: out)
    }
}

// MARK: - Crash regressions

@Suite("Multipart crash regressions (C4)")
struct MultipartCrashRegressionTests {

    let contentType = "multipart/form-data; boundary=x"

    /// The ~60-byte request that killed the process, sent through the real dispatch path.
    @Test func observedAttackPayloadIsAnsweredNotFatal() throws {
        let server = TestHTTP.server()
        server.register(MultipartEchoAPI())

        let payloads = [
            "--x\r\nContent-Disposition: form-data; name=\r\n\r\nv\r\n--x--\r\n",
            "--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\r\n\r\nv\r\n--x--\r\n",
            "--x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a\"\r\nContent-Type:\r\n\r\nv\r\n--x--\r\n",
        ]
        for payload in payloads {
            let request = TestHTTP.request(.POST, "/multipart-echo",
                                           headers: [("Content-Type", contentType)],
                                           body: Data(payload.utf8))
            let response = server.respond(to: request)
            #expect(response.status.code == 200)
        }

        let request = TestHTTP.request(.POST, "/multipart-echo",
                                       headers: [("Content-Type", contentType)],
                                       body: Data(payloads[0].utf8))
        let echoed = try JSONDecoder().decode([String: String].self, from: server.respond(to: request).bodyBytes)
        #expect(echoed["field:"] == "v")
    }

    @Test func emptyUnquotedNameIsAnEmptyName() {
        let body = MultipartTestKit.body(boundary: "x", [
            .init(["Content-Disposition: form-data; name="], "v"),
            .init([MultipartTestKit.disposition("after")], "still parsed"),
        ])
        let data = MultipartTestKit.consume(body, contentType: contentType)
        #expect(data.string("") == "v")
        #expect(data.string("after") == "still parsed")
    }

    @Test func emptyUnquotedFilenameIsAnEmptyFilename() {
        let body = MultipartTestKit.body(boundary: "x", [
            .init(["Content-Disposition: form-data; name=\"file\"; filename="], "bytes"),
            .init([MultipartTestKit.disposition("after")], "still parsed"),
        ])
        let data = MultipartTestKit.consume(body, contentType: contentType)
        #expect(data.file("file")?.filename == "")
        #expect(data.file("file")?.data == Data("bytes".utf8))
        #expect(data.string("after") == "still parsed")
    }

    @Test func emptyContentTypeLineGivesAnEmptyContentType() {
        for line in ["Content-Type:", "Content-Type: ", "content-type:\t"] {
            let body = MultipartTestKit.body(boundary: "x", [
                .init([MultipartTestKit.disposition("file", filename: "a.bin"), line], "bytes"),
            ])
            let data = MultipartTestKit.consume(body, contentType: contentType)
            #expect(data.file("file")?.contentType == "")
            #expect(data.file("file")?.data == Data("bytes".utf8))
        }
    }

    @Test func otherEmptyParametersDoNotTrap() {
        let lines = [
            "Content-Disposition:",
            "Content-Disposition: ",
            "Content-Disposition: form-data;",
            "Content-Disposition: form-data; ;;; =; name",
            "Content-Disposition: form-data; =\"x\"",
            "Content-Disposition: form-data; name=\"",
            "Content-Disposition: form-data; filename=; name=",
            "Content-Disposition: form-data; filename*=",
            "Content-Disposition: form-data; filename*=utf-8''",
            "Content-Disposition: form-data; filename*=''",
            "Content-Disposition: form-data; name=\"a\"; filename*=utf-8'en'%ZZ",
            ":",
            "::::",
            "Content-Type::",
        ]
        for line in lines {
            let body = MultipartTestKit.body(boundary: "x", [
                .init([line], "v"),
                .init([MultipartTestKit.disposition("after")], "ok"),
            ])
            let data = MultipartTestKit.consume(body, contentType: contentType)
            #expect(data.string("after") == "ok", "line: \(line)")
        }
    }

    @Test func partWithoutContentDispositionIsIgnored() {
        let body = MultipartTestKit.body(boundary: "x", [
            .init(["Content-Type: text/plain"], "orphan"),
            .init([], "no headers at all"),
            .init([MultipartTestKit.disposition("after")], "ok"),
        ])
        let data = MultipartTestKit.consume(body, contentType: contentType)
        #expect(data.string("after") == "ok")
        #expect(data.files.isEmpty)
    }

    @Test func headerLineWithoutColonIsIgnored() {
        let body = MultipartTestKit.body(boundary: "x", [
            .init(["garbage line without a colon", MultipartTestKit.disposition("title"), "another one"], "hello"),
        ])
        let data = MultipartTestKit.consume(body, contentType: contentType)
        #expect(data.string("title") == "hello")
    }

    @Test func missingOrEmptyBoundaryKeepsTheRawBody() {
        // As before, a multipart body without a usable boundary is kept as plain text under "body".
        let raw = "--x\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello\r\n--x--\r\n"
        for type in ["multipart/form-data", "multipart/form-data; boundary=", "multipart/form-data; boundary=\"\"",
                     "multipart/form-data; charset=utf-8", "multipart/form-data; boundary"] {
            let data = MultipartTestKit.consume(raw, contentType: type)
            #expect(data.string("title") == nil, "type: \(type)")
            #expect(data.string("body") == raw, "type: \(type)")
        }
    }

    @Test func implausiblyLongBoundaryIsNotUsed() {
        let boundary = String(repeating: "b", count: MultipartParser.maxBoundaryLength + 1)
        let body = MultipartTestKit.body(boundary: boundary, [.init([MultipartTestKit.disposition("title")], "hello")])
        let data = MultipartTestKit.consume(body, contentType: "multipart/form-data; boundary=\(boundary)")
        #expect(data.string("title") == nil)

        let longest = String(repeating: "b", count: MultipartParser.maxBoundaryLength)
        let accepted = MultipartTestKit.body(boundary: longest, [.init([MultipartTestKit.disposition("title")], "hello")])
        #expect(MultipartTestKit.consume(accepted, contentType: "multipart/form-data; boundary=\(longest)").string("title") == "hello")
    }

    @Test func quotedBoundaryIsUnquoted() {
        for (type, boundary) in [("multipart/form-data; boundary=\"simple\"", "simple"),
                                 ("multipart/form-data; boundary=\"with space:and=equals\"", "with space:and=equals"),
                                 ("multipart/form-data; BOUNDARY=\"upper\"; charset=utf-8", "upper")] {
            let body = MultipartTestKit.body(boundary: boundary, [.init([MultipartTestKit.disposition("title")], "hello")])
            let data = MultipartTestKit.consume(body, contentType: type)
            #expect(data.string("title") == "hello", "type: \(type)")
        }
    }

    @Test func truncatedBodiesKeepOnlyCompleteParts() {
        let full = MultipartTestKit.body(boundary: "x", [
            .init([MultipartTestKit.disposition("first")], "one"),
            .init([MultipartTestKit.disposition("second")], "two"),
        ])
        // Every prefix of a valid body parses without trapping; a part counts only once the
        // delimiter after it has arrived.
        for length in 0...full.count {
            let data = MultipartTestKit.consume(full.prefix(length), contentType: contentType)
            let firstComplete = full.prefix(length).range(of: Data("one\r\n--x".utf8)) != nil
            let secondComplete = full.prefix(length).range(of: Data("two\r\n--x".utf8)) != nil
            #expect(data.string("first") == (firstComplete ? "one" : nil))
            #expect(data.string("second") == (secondComplete ? "two" : nil))
        }
    }

    @Test func missingFinalBoundaryDropsOnlyTheUnterminatedPart() {
        let body = MultipartTestKit.body(boundary: "x", [
            .init([MultipartTestKit.disposition("first")], "one"),
            .init([MultipartTestKit.disposition("second")], "two"),
        ], closing: false)
        let data = MultipartTestKit.consume(body, contentType: contentType)
        #expect(data.string("first") == "one")
        #expect(data.string("second") == nil)
    }

    @Test func degenerateBodiesDoNotTrap() {
        let bodies = ["", "-", "--", "--x", "--x--", "--x\r", "--x\r\n", "--x\r\n\r\n", "--x\r\n\r\n\r\n--x",
                      "--x\r\n\r\n--x\r\n\r\n--x--", "--x\n", "--x\n\n--x", "\r\n--x\r\n", "--x--x--x",
                      "--x\r\nContent-Disposition: form-data; name=\"a\"\r\n--x--",
                      "--x\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n--x--",
                      "--x\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n"]
        for body in bodies {
            _ = MultipartTestKit.consume(body, contentType: contentType)
        }
        // Headers followed directly by the delimiter: the part has empty content.
        let direct = MultipartTestKit.consume("--x\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n--x\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nB\r\n--x--",
                                              contentType: contentType)
        #expect(direct.string("a") == "")
        #expect(direct.string("b") == "B")
    }

    @Test func nonUTF8HeaderBlockSkipsOnlyThatPart() {
        var bad = Data("--x\r\nContent-Disposition: form-data; name=\"bad".utf8)
        bad.append(contentsOf: [0xFF, 0xFE])
        bad.append(Data("\"\r\n\r\nv\r\n".utf8))
        bad.append(MultipartTestKit.body(boundary: "x", [.init([MultipartTestKit.disposition("after")], "ok")]))
        let data = MultipartTestKit.consume(bad, contentType: contentType)
        #expect(data.string("after") == "ok")
    }

    @Test func dataSliceWithNonZeroStartIndexParses() {
        let body = MultipartTestKit.body(boundary: "x", [
            .init([MultipartTestKit.disposition("title")], "hello"),
            .init([MultipartTestKit.disposition("file", filename: "a.bin")], Data([0, 1, 2, 3])),
        ])
        var padded = Data(repeating: 0x41, count: 37)
        padded.append(body)
        padded.append(Data(repeating: 0x42, count: 11))
        let slice = padded[37..<(37 + body.count)]
        #expect(slice.startIndex == 37)

        let data = MultipartTestKit.consume(slice, contentType: contentType)
        #expect(data.string("title") == "hello")
        #expect(data.file("file")?.data == Data([0, 1, 2, 3]))
        #expect(data.file("file")?.data?.startIndex == 0)
    }

    @Test func partsBeyondTheCapAreNotParsed() {
        let count = MultipartParser.maxParts + 5
        let parts = (0..<count).map { MultipartTestKit.Part([MultipartTestKit.disposition("f\($0)")], "v\($0)") }
        let data = MultipartTestKit.consume(MultipartTestKit.body(boundary: "x", parts), contentType: contentType)
        #expect(data.string("f0") == "v0")
        #expect(data.string("f\(MultipartParser.maxParts - 1)") == "v\(MultipartParser.maxParts - 1)")
        #expect(data.string("f\(MultipartParser.maxParts)") == nil)
        #expect(data.string("f\(count - 1)") == nil)
    }

    @Test func oversizedHeaderBlockStopsParsing() {
        let padding = "X-Padding: " + String(repeating: "p", count: MultipartParser.maxHeaderBytesPerPart)
        let body = MultipartTestKit.body(boundary: "x", [
            .init([MultipartTestKit.disposition("before")], "kept"),
            .init([MultipartTestKit.disposition("big"), padding], "dropped"),
            .init([MultipartTestKit.disposition("after")], "dropped too"),
        ])
        let data = MultipartTestKit.consume(body, contentType: contentType)
        #expect(data.string("before") == "kept")
        #expect(data.string("big") == nil)
        #expect(data.string("after") == nil)

        // Just under the cap is still fine.
        let fits = "X-Padding: " + String(repeating: "p", count: MultipartParser.maxHeaderBytesPerPart - 200)
        let ok = MultipartTestKit.body(boundary: "x", [.init([MultipartTestKit.disposition("big"), fits], "kept")])
        #expect(MultipartTestKit.consume(ok, contentType: contentType).string("big") == "kept")
    }

    @Test func partWithoutBlankLineIsSkipped() {
        let body = "--x\r\nContent-Disposition: form-data; name=\"a\"\r\nno blank line here\r\n--x\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nB\r\n--x--\r\n"
        let data = MultipartTestKit.consume(body, contentType: contentType)
        #expect(data.string("a") == nil)
        #expect(data.string("b") == "B")
    }

    @Test func closingDelimiterEndsParsing() {
        let late = "--x\r\nContent-Disposition: form-data; name=\"late\"\r\n\r\nv\r\n--x--\r\n"
        // Straight after the closing delimiter, the original parser read the "late" part.
        let direct = MultipartTestKit.body(boundary: "x", [.init([MultipartTestKit.disposition("title")], "hello")],
                                           epilogue: late)
        #expect(MultipartLegacyParser.parse(direct, contentType: contentType).fields["late"] == "v")
        // After a blank line it swallowed it into an unnamed part instead.
        let afterBlankLine = MultipartTestKit.body(boundary: "x", [.init([MultipartTestKit.disposition("title")], "hello")],
                                                   epilogue: "\r\n" + late)
        for body in [direct, afterBlankLine] {
            let data = MultipartTestKit.consume(body, contentType: contentType)
            #expect(data.string("title") == "hello")
            #expect(data.string("late") == nil)
        }
    }

    @Test func hostileSearchPatternsStayFast() {
        // Near-miss delimiters everywhere; the KMP search keeps this linear.
        let boundary = String(repeating: "-", count: 60) + "z"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a\"\r\n\r\n".utf8)
        let nearMiss = Data(("\r\n--" + String(repeating: "-", count: 60)).utf8)
        for _ in 0..<20_000 { body.append(nearMiss) }
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let start = Date()
        let data = MultipartTestKit.consume(body, contentType: "multipart/form-data; boundary=\(boundary)")
        #expect(data.file("f")?.data?.count == nearMiss.count * 20_000)
        #expect(Date().timeIntervalSince(start) < 10)
    }
}

// MARK: - Parameter parsing

@Suite("Multipart header parameters")
struct MultipartHeaderParameterTests {

    private func params(_ text: String, skipFirst: Bool = true) -> [String: String] {
        var out: [String: String] = [:]
        for p in MultipartHeaderParameters.parse(text, skippingFirstSegment: skipFirst) {
            out[p.name] = p.value
        }
        return out
    }

    @Test func quotedValuesMayContainSemicolonsAndEquals() {
        let p = params(#"form-data; name="a;b=c"; filename="x; y=z.txt""#)
        #expect(p["name"] == "a;b=c")
        #expect(p["filename"] == "x; y=z.txt")
    }

    @Test func namesAreCaseInsensitiveAndTrimmed() {
        let p = params(#"form-data; NAME="x" ;  FileName = "y.txt""#)
        #expect(p["name"] == "x")
        #expect(p["filename"] == "y.txt")
    }

    @Test func unquotedAndEmptyValues() {
        #expect(params("form-data; name=plain")["name"] == "plain")
        #expect(params("form-data; name= spaced out ")["name"] == "spaced out")
        #expect(params("form-data; name=")["name"] == "")
        #expect(params(#"form-data; name="""#)["name"] == "")
        #expect(params("form-data; name=;filename=")["filename"] == "")
    }

    @Test func legacyQuoteHandlingIsKept() {
        // Unterminated quote: trimmed like before.
        #expect(params(#"form-data; name="abc"#)["name"] == "abc")
        // Backslashes are kept as sent (Windows paths, escaped quotes).
        #expect(params(#"form-data; filename="C:\dir\a.txt""#)["filename"] == #"C:\dir\a.txt"#)
        #expect(params(#"form-data; filename="a\"b.txt""#)["filename"] == #"a\"b.txt"#)
        // Percent-encoded quotes, as browsers send them, are not decoded.
        #expect(params(#"form-data; filename="a%22b.txt""#)["filename"] == "a%22b.txt")
    }

    @Test func firstSegmentIsSkippedOnlyWhenAsked() {
        #expect(params(#"name="x""#, skipFirst: true)["name"] == nil)
        #expect(params(#"name="x""#, skipFirst: false)["name"] == "x")
    }

    @Test func manyUnterminatedQuotesParseInLinearTime() {
        let hostile = "form-data" + String(repeating: #"; a="x"#, count: 4_000)
        let start = Date()
        let parsed = MultipartHeaderParameters.parse(hostile, skippingFirstSegment: true)
        #expect(parsed.count == 4_000)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func boundaryExtraction() {
        #expect(MultipartParser.boundary(fromContentType: "multipart/form-data; boundary=----WebKitFormBoundaryAbC123") == "----WebKitFormBoundaryAbC123")
        #expect(MultipartParser.boundary(fromContentType: "multipart/form-data;boundary=abc") == "abc")
        #expect(MultipartParser.boundary(fromContentType: "multipart/form-data; boundary=abc ; charset=utf-8") == "abc")
        #expect(MultipartParser.boundary(fromContentType: "multipart/form-data; Boundary=abc") == "abc")
        #expect(MultipartParser.boundary(fromContentType: #"multipart/form-data; boundary="a;b=c""#) == "a;b=c")
        #expect(MultipartParser.boundary(fromContentType: "multipart/form-data; boundary=first; boundary=second") == "first")
        #expect(MultipartParser.boundary(fromContentType: "multipart/form-data") == nil)
        #expect(MultipartParser.boundary(fromContentType: "multipart/form-data; boundary=") == nil)
        #expect(MultipartParser.boundary(fromContentType: "") == nil)
    }

    @Test func extendedFilenameDecoding() {
        #expect(MultipartHeaderParameters.decodeExtendedValue("UTF-8''na%C3%AFve%20file.txt") == "naïve file.txt")
        #expect(MultipartHeaderParameters.decodeExtendedValue("utf-8'en'a.txt") == "a.txt")
        #expect(MultipartHeaderParameters.decodeExtendedValue("iso-8859-1''%A3.txt") == nil)
        #expect(MultipartHeaderParameters.decodeExtendedValue("no quotes") == nil)
        #expect(MultipartHeaderParameters.decodeExtendedValue("utf-8''%ZZ") == nil)
    }
}

// MARK: - Valid input parses as before

@Suite("Multipart valid input")
struct MultipartValidInputTests {

    @Test func textFieldAndFilePart() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x2D, 0x2D, 0x0D, 0x0A, 0xFF])
        let boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
        let body = MultipartTestKit.body(boundary: boundary, [
            .init([MultipartTestKit.disposition("title")], "Hello, World"),
            .init([MultipartTestKit.disposition("notes")], "\r\n\r\nline one\r\nline two\n\r\n"),
            .init([MultipartTestKit.disposition("files[]", filename: "pic.png"), "Content-Type: image/png"], png),
        ])
        let data = MultipartTestKit.consume(body, contentType: "multipart/form-data; boundary=\(boundary)")

        #expect(data.string("title") == "Hello, World")
        // Values are still trimmed of surrounding newlines (changing that is Phase 2).
        #expect(data.string("notes") == "line one\r\nline two")
        let file = data.file("files[]")
        #expect(file?.fieldName == "files[]")
        #expect(file?.filename == "pic.png")
        #expect(file?.contentType == "image/png")
        #expect(file?.data == png)
        #expect(data.string("files[]") == nil)
        #expect(data.raw("files[]") is WebData.FilePart)
    }

    @Test func multipleFilesUnderFilesArrayKeepTheLast() {
        let body = MultipartTestKit.body(boundary: "b", [
            .init([MultipartTestKit.disposition("files[]", filename: "one.txt"), "Content-Type: text/plain"], "1"),
            .init([MultipartTestKit.disposition("files[]", filename: "two.bin"), "Content-Type: application/octet-stream"], "22"),
            .init([MultipartTestKit.disposition("files[]", filename: "three.ipa"), "Content-Type: application/octet-stream"], "333"),
        ])
        let data = MultipartTestKit.consume(body, contentType: "multipart/form-data; boundary=b")
        #expect(data.files.count == 1)
        let file = data.file("files[]")
        #expect(file?.filename == "three.ipa")
        #expect(file?.data == Data("333".utf8))
    }

    @Test func emptyFileInputIsAFilePartWithEmptyFilename() {
        let body = MultipartTestKit.body(boundary: "b", [
            .init([MultipartTestKit.disposition("file", filename: ""), "Content-Type: application/octet-stream"], Data()),
        ])
        let file = MultipartTestKit.consume(body, contentType: "multipart/form-data; boundary=b").file("file")
        #expect(file?.filename == "")
        #expect(file?.data == Data())
    }

    @Test func nonUTF8TextFieldIsDropped() {
        let body = MultipartTestKit.body(boundary: "b", [.init([MultipartTestKit.disposition("bin")], Data([0xC3, 0x28]))])
        #expect(MultipartTestKit.consume(body, contentType: "multipart/form-data; boundary=b").string("bin") == nil)
    }

    @Test func filenameWithSemicolonIsKeptWhole() {
        let body = MultipartTestKit.body(boundary: "b", [
            .init([#"Content-Disposition: form-data; name="file"; filename="report; final=v2.pdf""#], "pdf"),
        ])
        let file = MultipartTestKit.consume(body, contentType: "multipart/form-data; boundary=b").file("file")
        #expect(file?.filename == "report; final=v2.pdf")
    }

    @Test func parameterNamesAreCaseInsensitive() {
        let body = MultipartTestKit.body(boundary: "b", [
            .init([#"content-disposition: form-data; NAME="file"; FILENAME="a.txt""#, "CONTENT-TYPE: text/plain"], "x"),
        ])
        let file = MultipartTestKit.consume(body, contentType: "multipart/form-data; boundary=b").file("file")
        #expect(file?.filename == "a.txt")
        #expect(file?.contentType == "text/plain")
    }

    @Test func extendedFilenameIsUsedOnlyWhenFilenameIsMissing() {
        let only = MultipartTestKit.body(boundary: "b", [
            .init([#"Content-Disposition: form-data; name="file"; filename*=UTF-8''na%C3%AFve.txt"#], "x"),
        ])
        #expect(MultipartTestKit.consume(only, contentType: "multipart/form-data; boundary=b").file("file")?.filename == "naïve.txt")

        let both = MultipartTestKit.body(boundary: "b", [
            .init([#"Content-Disposition: form-data; name="file"; filename*=UTF-8''other.txt; filename="plain.txt""#], "x"),
        ])
        #expect(MultipartTestKit.consume(both, contentType: "multipart/form-data; boundary=b").file("file")?.filename == "plain.txt")
    }

    @Test func bareLineFeedBodyIsParsed() {
        let body = MultipartTestKit.body(boundary: "b", [
            .init([MultipartTestKit.disposition("title")], "hello"),
            .init([MultipartTestKit.disposition("file", filename: "a.txt"), "Content-Type: text/plain"], "line\nline"),
        ], eol: "\n")
        let data = MultipartTestKit.consume(body, contentType: "multipart/form-data; boundary=b")
        #expect(data.string("title") == "hello")
        #expect(data.file("file")?.data == Data("line\nline".utf8))
        #expect(data.file("file")?.contentType == "text/plain")
    }

    @Test func preambleAndTransportPaddingAreTolerated() {
        let body = "This is the preamble.\r\n--b   \r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello\r\n--b--\r\nepilogue"
        #expect(MultipartTestKit.consume(body, contentType: "multipart/form-data; boundary=b").string("title") == "hello")
    }

    @Test func largeFilePartRoundTripsByteForByte() {
        var generator = MultipartRandom(seed: 0xF11E)
        let bytes = Data((0..<(3 * 1024 * 1024)).map { _ in generator.byte() })
        let boundary = "----WebKitFormBoundaryLargeFileTest01"
        let body = MultipartTestKit.body(boundary: boundary, [
            .init([MultipartTestKit.disposition("files[]", filename: "big.ipa"), "Content-Type: application/octet-stream"], bytes),
            .init([MultipartTestKit.disposition("resign")], "true"),
        ])
        let data = MultipartTestKit.consume(body, contentType: "multipart/form-data; boundary=\(boundary)")
        #expect(data.file("files[]")?.data == bytes)
        #expect(data.bool("resign") == true)
    }

    @Test func dispatchPathParsesAnUpload() throws {
        let server = TestHTTP.server()
        server.register(MultipartEchoAPI())
        let boundary = "----geckoformboundary1a2b3c4d"
        let body = MultipartTestKit.body(boundary: boundary, [
            .init([MultipartTestKit.disposition("title")], "My App"),
            .init([MultipartTestKit.disposition("files[]", filename: "My App.ipa"), "Content-Type: application/octet-stream"], Data(repeating: 7, count: 1000)),
        ])
        let response = server.respond(to: TestHTTP.request(.POST, "/multipart-echo",
                                                           headers: [("Content-Type", "multipart/form-data; boundary=\(boundary)")],
                                                           body: body))
        let echoed = try JSONDecoder().decode([String: String].self, from: response.bodyBytes)
        #expect(echoed["field:title"] == "My App")
        #expect(echoed["file:files[]:filename"] == "My App.ipa")
        #expect(echoed["file:files[]:contentType"] == "application/octet-stream")
        #expect(echoed["file:files[]:size"] == "1000")
    }

    /// Random well-formed bodies give exactly what the original parser gave.
    @Test func matchesTheOriginalParserOnWellFormedBodies() {
        var random = MultipartRandom(seed: 0x5EED_0001)
        for iteration in 0..<1_500 {
            let sample = WellFormedMultipart.generate(&random)
            let data = MultipartTestKit.consume(sample.body, contentType: sample.contentType)
            let legacy = MultipartLegacyParser.parse(sample.body, contentType: sample.contentType)

            for name in sample.names {
                #expect(data.string(name) == legacy.fields[name], "iteration \(iteration) field \(name)")
            }
            #expect(Set(data.files.keys) == Set(legacy.files.keys), "iteration \(iteration)")
            for (name, file) in legacy.files {
                let parsed = data.files[name]
                #expect(parsed?.fieldName == file.fieldName, "iteration \(iteration)")
                #expect(parsed?.filename == file.filename, "iteration \(iteration)")
                #expect(parsed?.contentType == file.contentType, "iteration \(iteration)")
                #expect(parsed?.data == file.data, "iteration \(iteration)")
            }
        }
    }
}

// MARK: - Reference copy of the original parser (valid input only)

/// The pre-fix parsing algorithm, copied verbatim apart from returning its results. It traps on
/// some malformed input, so only well-formed bodies are given to it.
enum MultipartLegacyParser {
    struct Result {
        var fields: [String: String] = [:]
        var files: [String: WebData.FilePart] = [:]
    }

    static func parse(_ data: Data, contentType: String) -> Result {
        var result = Result()
        guard contentType.contains("multipart/form-data"), let boundary = boundary(from: contentType) else { return result }
        let boundaryPrefix = "--" + boundary
        let boundaryData = boundaryPrefix.data(using: .utf8)!
        let endBoundaryData = ("\r\n" + boundaryPrefix).data(using: .utf8)!
        var idx = 0
        while idx < data.count {
            guard let startRange = data.range(of: boundaryData, options: [], in: idx..<data.count) else { break }
            idx = startRange.upperBound
            if data[idx..<min(idx + 2, data.count)] == "\r\n".data(using: .utf8)! {
                idx += 2
            }
            guard let headerEndRange = data.range(of: "\r\n\r\n".data(using: .utf8)!, options: [], in: idx..<data.count) else { break }
            let headerData = data[idx..<headerEndRange.lowerBound]
            idx = headerEndRange.upperBound
            guard let partEndRange = data.range(of: endBoundaryData, options: [], in: idx..<data.count) else { break }
            let partData = data[idx..<partEndRange.lowerBound]
            idx = partEndRange.lowerBound
            guard let headerText = String(data: headerData, encoding: .utf8) else { continue }
            var fieldName: String?
            var fileName: String?
            var contentType: String?
            for line in headerText.split(separator: "\r\n") {
                let header = String(line)
                if header.lowercased().hasPrefix("content-disposition:") {
                    let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                    for p in parts {
                        if p.hasPrefix("name=") {
                            fieldName = p.split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        } else if p.hasPrefix("filename=") {
                            fileName = p.split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        }
                    }
                } else if header.lowercased().hasPrefix("content-type:") {
                    contentType = header.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                }
            }
            guard let name = fieldName else { continue }
            if let fn = fileName {
                result.files[name] = WebData.FilePart(fieldName: name, filename: fn, contentType: contentType, data: Data(partData))
            } else if let text = String(data: partData, encoding: .utf8)?.trimmingCharacters(in: .newlines) {
                result.fields[name] = text
            }
        }
        return result
    }

    private static func boundary(from contentType: String) -> String? {
        for comp in contentType.split(separator: ";") {
            let trimmed = comp.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("boundary=") {
                return String(trimmed.dropFirst("boundary=".count))
            }
        }
        return nil
    }
}

/// Generates well-formed bodies in the shapes real clients send.
enum WellFormedMultipart {
    struct Sample {
        let body: Data
        let contentType: String
        let names: [String]
    }

    static let names = ["title", "files[]", "file", "description", "naïve name", "a=b", "x:y", "名前", "user[email]", "empty", " padded "]
    static let filenames = ["a.txt", "My App.ipa", "naïve.png", "C:\\fakepath\\a.txt", "a=b.bin", "", "x:y.zip", "报告.pdf", "a%22b.txt"]
    static let contentTypes = ["text/plain", "image/png", "application/octet-stream", " application/json ; charset=utf-8", ""]

    static func generate(_ random: inout MultipartRandom) -> Sample {
        let boundary = makeBoundary(&random)
        var parts: [MultipartTestKit.Part] = []
        var used: [String] = []
        for _ in 0..<random.int(below: 9) {
            let name = random.pick(names)
            used.append(name)
            var headers: [String] = []
            let dispositionName = random.pick(["Content-Disposition", "content-disposition", "CONTENT-DISPOSITION"])
            var disposition = "\(dispositionName): form-data\(random.pick([";", "; ", ";  "]))name=\"\(name)\""
            let isFile = random.bool()
            if isFile {
                disposition += "\(random.pick([";", "; ", " ; "]))filename=\"\(random.pick(filenames))\""
            }
            if random.int(below: 4) == 0 { disposition += " " }
            headers.append(disposition)
            if random.bool() {
                headers.append("\(random.pick(["Content-Type", "content-type"])): \(random.pick(contentTypes))")
            }
            if random.int(below: 5) == 0 { headers.append("Content-Transfer-Encoding: binary") }
            if random.int(below: 5) == 0 { headers.insert("X-Extra: a:b;c=d", at: 0) }
            parts.append(.init(headers, content(&random, avoiding: boundary)))
        }
        let preamble = random.int(below: 4) == 0 ? "preamble text\r\n" : ""
        let epilogue = random.pick(["", "\r\n", "epilogue\r\n\r\nmore"])
        let body = MultipartTestKit.body(boundary: boundary, parts, preamble: preamble, epilogue: epilogue)
        let contentType = random.pick(["multipart/form-data; boundary=\(boundary)",
                                       "multipart/form-data;boundary=\(boundary)",
                                       "multipart/form-data; boundary=\(boundary); charset=utf-8"])
        return Sample(body: body, contentType: contentType, names: used + ["missing"])
    }

    private static func makeBoundary(_ random: inout MultipartRandom) -> String {
        let alnum = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let bchars = alnum + Array("'()+_,-./:=?")
        func run(_ chars: [Character], _ count: Int) -> String {
            String((0..<count).map { _ in random.pick(chars) })
        }
        switch random.int(below: 4) {
            case 0: return "----WebKitFormBoundary" + run(alnum, 16)
            case 1: return "----geckoformboundary" + run(Array("0123456789abcdef"), 32)
            case 2: return "------------------------" + run(Array("0123456789abcdef"), 16)
            default: return run(bchars, 8 + random.int(below: 50))
        }
    }

    private static func content(_ random: inout MultipartRandom, avoiding boundary: String) -> Data {
        let delimiter = Data("--\(boundary)".utf8)
        while true {
            var data = Data()
            switch random.int(below: 4) {
                case 0:
                    data = Data((0..<random.int(below: 300)).map { _ in random.byte() })
                case 1:
                    data = Data(random.pick(["hello", "\r\nlead", "trail\r\n", "\n\nboth\r\n\r\n", "", "multi\r\nline\r\ntext",
                                             "naïve ünïcode 名前", "a--b", "-- dashes --"]).utf8)
                case 2:
                    let tokens = ["\r\n", "\n", "\r", "--", "-", "\"", ";", "=", ":", "x", " "]
                    data = Data((0..<random.int(below: 40)).map { _ in random.pick(tokens) }.joined().utf8)
                default:
                    data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            }
            if data.range(of: delimiter) == nil { return data }
        }
    }
}

/// Deterministic xorshift64* generator so failures reproduce.
struct MultipartRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    mutating func int(below bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(next() % UInt64(bound))
    }

    mutating func byte() -> UInt8 {
        UInt8(truncatingIfNeeded: next())
    }

    mutating func bool() -> Bool {
        next() & 1 == 1
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[int(below: items.count)]
    }
}
