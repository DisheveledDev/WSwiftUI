//
//  Phase0ReviewFixTests.swift
//  WSwiftUITests
//
//  Regression tests for the findings of the adversarial review of the merged Phase 0 patch:
//   - request heads are bounded and an over-long line is refused, never split (SECURITY-2/3)
//   - legacy file bodies get a Content-Type from their extension and nosniff (SECURITY-1)
//   - `.data("name=value")` keeps rendering data-name="value" (CORRECTNESS-2)
//   - one implementation per escaping helper (API-PORTABILITY-4/5), Foundation numbers keep their type (-6)
//   - a SecureField never writes a value the app seeded its binding with (exploit replay PWv)
//

import Foundation
import Testing
@testable import WSwiftUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Request head limits

@Suite("Phase 0 review: request head limits")
struct RequestHeadLimitTests {

    /// One parser instance; readHead only reads from the descriptor it is given.
    nonisolated(unsafe) static let parser = HTTPServer(onRequestHead: { _ in .accept },
                                                      onBeforeBody: { _ in .accept },
                                                      handler: { _ in HttpResponse() })

    /// Writes `raw` into one end of a socketpair (buffers sized to hold it), closes the writing side,
    /// and parses the head from the other end.
    private func parse(_ raw: String) throws -> HttpRequestHead {
        signal(SIGPIPE, SIG_IGN)
        var fds: [Int32] = [-1, -1]
#if canImport(Darwin)
        let streamType = SOCK_STREAM
#else
        let streamType = Int32(SOCK_STREAM.rawValue)
#endif
        guard socketpair(AF_UNIX, streamType, 0, &fds) == 0 else { throw Err.socket("socketpair") }
        defer { _ = close(fds[0]) }
        var size: Int32 = 1 << 20
        _ = setsockopt(fds[1], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fds[0], SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let bytes = Array(raw.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
            guard n > 0 else { _ = close(fds[1]); throw Err.io("write") }
            sent += n
        }
        _ = close(fds[1])
        return try Self.parser.readHead(fd: fds[0])
    }

    private func requestLine(targetLength: Int) -> String {
        // "GET " + target + " HTTP/1.1" with the whole line `targetLength + 13` bytes
        return "GET /" + String(repeating: "a", count: targetLength - 1) + " HTTP/1.1"
    }

    @Test func ordinaryRequestsParse() throws {
        let head = try parse("GET /x?y=1 HTTP/1.1\r\nHost: example\r\nCookie: auth=abc\r\n\r\n")
        #expect(head.uri == "/x?y=1")
        #expect(head.headers.count == 2)
    }

    @Test func requestLineAtTheLimitParsesAndOneByteMoreIsRefused() throws {
        let limit = HTTPServer.maxHeadLineBytes
        let atLimit = requestLine(targetLength: limit - 13)
        #expect(atLimit.utf8.count == limit)
        #expect(try parse(atLimit + "\r\nHost: x\r\n\r\n").uri.utf8.count == limit - 13)
        #expect(throws: HTTPServer.RequestHeadTooLarge.requestLine) {
            try parse(requestLine(targetLength: limit - 12) + "\r\nHost: x\r\n\r\n")
        }
    }

    @Test func overLongHeaderLineIsRefusedNotSplit() {
        // Before, the line was cut at 16 KiB and its tail parsed as a second header a proxy never saw.
        let pad = String(repeating: "A", count: HTTPServer.maxHeadLineBytes - "X-Pad: ".utf8.count)
        #expect(throws: HTTPServer.RequestHeadTooLarge.headerFields) {
            try parse("GET / HTTP/1.1\r\nX-Pad: \(pad)X-Forwarded-Host: evil.example\r\n\r\n")
        }
    }

    @Test func headerCountIsBounded() throws {
        let max = HTTPServer.maxHeaderCount
        let ok = (0..<max).map { "X-H\($0): v" }.joined(separator: "\r\n")
        #expect(try parse("GET / HTTP/1.1\r\n\(ok)\r\n\r\n").headers.count == max)
        let tooMany = (0...max).map { "X-H\($0): v" }.joined(separator: "\r\n")
        #expect(throws: HTTPServer.RequestHeadTooLarge.headerFields) {
            try parse("GET / HTTP/1.1\r\n\(tooMany)\r\n\r\n")
        }
    }

    @Test func headerSectionSizeIsBounded() {
        let line = "X-Big: " + String(repeating: "b", count: 15_000)
        let fiveLines = Array(repeating: line, count: 5).joined(separator: "\r\n")   // about 75 KB
        #expect(throws: HTTPServer.RequestHeadTooLarge.headerFields) {
            try parse("GET / HTTP/1.1\r\n\(fiveLines)\r\n\r\n")
        }
    }
}

// MARK: - Legacy file bodies

@Suite("Phase 0 review: legacy file bodies are typed")
struct LegacyFileBodyTypeTests {

    static let dir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wsui-legacy-types-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["icon.png", "page.html", "app.ipa", "noextension", "doc.SVG", "feed.xml", "site.js"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path,
                                           contents: Data("<html><script>alert(1)</script></html>".utf8))
        }
        return dir
    }()

    private func headers(_ name: String, contentType: String? = nil) -> [(String, String)] {
        let response = HttpResponse().body(Self.dir.appendingPathComponent(name))
        if let contentType { response.header("Content-Type", contentType) }
        return HTTPServer.prepare(response).headers
    }

    private func values(_ headers: [(String, String)], _ name: String) -> [String] {
        headers.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map { $0.1 }
    }

    @Test(arguments: [
        ("icon.png", "image/png"),
        // documents that could run script on this origin download instead of rendering
        ("page.html", "application/octet-stream"),
        ("doc.SVG", "application/octet-stream"),
        ("feed.xml", "application/octet-stream"),
        ("site.js", "text/javascript; charset=utf-8"),
        ("app.ipa", "application/octet-stream"),
        ("noextension", "application/octet-stream"),
    ])
    func typeComesFromTheExtensionAndSniffingIsOff(name: String, expected: String) {
        let h = headers(name)
        #expect(values(h, "Content-Type") == [expected])
        #expect(values(h, "X-Content-Type-Options") == ["nosniff"])
    }

    @Test func anAppSetContentTypeIsKept() {
        let h = headers("app.ipa", contentType: "application/x-itunes-ipa")
        #expect(values(h, "Content-Type") == ["application/x-itunes-ipa"])
        #expect(values(h, "X-Content-Type-Options") == ["nosniff"])
        // the opt-in for serving a trusted document inline
        #expect(values(headers("page.html", contentType: "text/html; charset=utf-8"), "Content-Type") == ["text/html; charset=utf-8"])
        // any casing of the header name counts as set
        let lower = HttpResponse().body(Self.dir.appendingPathComponent("page.html"))
        lower.header("content-type", "text/plain; charset=utf-8")
        #expect(values(HTTPServer.prepare(lower).headers, "Content-Type") == ["text/plain; charset=utf-8"])
    }
}

// MARK: - .data(_:)

@Suite("Phase 0 review: data attributes", .serialized)
struct DataAttributeTests {

    @Test func dataKeepsItsLegacyNameValueForm() {
        #expect(CoreWebEndpoint.dataAttribute("bs-toggle=\"modal\"") == "data-bs-toggle=\"modal\"")
        #expect(CoreWebEndpoint.dataAttribute("bs-toggle='modal'") == "data-bs-toggle=\"modal\"")
        #expect(CoreWebEndpoint.dataAttribute("count=3") == "data-count=\"3\"")
        #expect(CoreWebEndpoint.dataAttribute("flag") == "data-flag")
    }

    @Test func dataValueCannotBreakOutOfTheAttribute() {
        #expect(CoreWebEndpoint.dataAttribute("x=\"><script>alert(1)</script>") ==
                "data-x=\"&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;\"")
        #expect(CoreWebEndpoint.dataAttribute("a b\"=c") == "data-ab=\"c\"")
    }

    @Test func dataRendersThroughThePage() {
        let html = renderHTML { page in
            page.Text("x").data("bs-toggle=\"modal\"")
        }
        #expect(html.contains("data-bs-toggle=\"modal\""))
    }
}

// MARK: - Script literal helpers

@Suite("Phase 0 review: script literal helpers")
struct ScriptLiteralHelperTests {

    @Test func makeScriptSafeHasTheSameGuaranteesAsScriptString() throws {
        let json = #"{"k":"it's `x` </script>  "}"#
        let safe = WebJSON.makeScriptSafe(json)
        for forbidden in ["'", "`", "<", ">", "&", "\u{2028}"] {
            #expect(safe.contains(forbidden) == false, "\(forbidden)")
        }
        let decoded = try JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: String]
        #expect(decoded?["k"] == "it's `x` </script> \u{2028}")
        #expect(ScriptValue.json(json) == safe)
    }

    @Test func javascriptConditionIsScriptSafeCondition() {
        for op: Operator in [.equals(Double.nan), .equals(Double.infinity), .equals("a'b</script>"), .equals(3), .equals(true)] {
            #expect(op.javascriptCondition == op.scriptSafeCondition)
        }
        #expect(Operator.equals(Double.nan).javascriptCondition.contains("NaN"))
    }

    @Test func foundationNumbersKeepTheirType() throws {
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(#"{"one":1,"zero":0,"t":true,"f":false,"half":1.5}"#.utf8)) as? [String: Any])
        #expect(WebJSON.scriptLiteral(any: parsed["one"]!) == "1")
        #expect(WebJSON.scriptLiteral(any: parsed["zero"]!) == "0")
        #expect(WebJSON.scriptLiteral(any: parsed["t"]!) == "true")
        #expect(WebJSON.scriptLiteral(any: parsed["f"]!) == "false")
        #expect(WebJSON.scriptLiteral(any: parsed["half"]!) == "1.5")
        // native Swift values are unchanged
        #expect(WebJSON.scriptLiteral(any: 1) == "1")
        #expect(WebJSON.scriptLiteral(any: true) == "true")
        #expect(WebJSON.scriptLiteral(any: 2.5) == "2.5")
        #expect(WebJSON.scriptLiteral(any: Double.nan) == "NaN")
        #expect(WebJSON.scriptLiteral(any: NSNumber(value: Double.infinity)) == "Infinity")
        // Foundation arrays keep boolean elements boolean
        let array = try #require(try JSONSerialization.jsonObject(with: Data("[true,false,1,0,1.5]".utf8)))
        #expect(WebJSON.scriptLiteral(any: array) == "[true,false,1,0,1.5]")
        #expect(WebJSON.scriptLiteral(any: NSArray(array: [true, 2, "</x>"])) == #"[true,2,"\u003c/x\u003e"]"#)
        #expect(WebJSON.scriptLiteral(any: [true, false]) == "[true,false]")
        #expect(WebJSON.scriptLiteral(any: [1, 0]) == "[1,0]")
    }

    @Test func scriptElementBodyHandlesMultiByteText() {
        let js = "x = 'café ✓ </script> 𝄞 </SCRIPT'; y = 'ſcript </scrip'"
        #expect(WebJSON.scriptElementBody(js) == #"x = 'café ✓ <\/script> 𝄞 <\/SCRIPT'; y = 'ſcript </scrip'"#)
        // HTML matches the tag name ASCII case-insensitively only, so U+017F (long s) is not a match
        #expect(WebJSON.scriptElementBody("</ſcript>") == "</ſcript>")
    }
}

// MARK: - Seeded secret bindings

final class SeededSecretPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "phase0-seeded-secret"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }

    override func content() -> Any? {
        return webpage {
            Form {
                TextField("Email", text: WString(data.string("email") ?? "").name("email"))
                SecureField("Password", text: WString(data.string("password") ?? "").name("password"))
            }
        }
    }
}

@Suite("Phase 0 review: seeded secret bindings", .serialized)
struct SeededSecretBindingTests {

    @Test func appSeededPasswordIsNeverWrittenIntoThePage() {
        let server = TestHTTP.server()
        server.register(SeededSecretPage())
        let html = server.respond(to: TestHTTP.request(.GET, "/phase0-seeded-secret?email=me%40example.com&password=SeededSecret123")).bodyString
        #expect(html.contains("SeededSecret123") == false)
        // the ordinary field still round-trips
        #expect(html.contains("me@example.com"))
    }

    @Test func boundSecretVariableStartsEmpty() {
        let box = HtmlCtxBox()
        let html = renderHTML { page in
            let secret = page.WString("bound-secret-xyz")
            box.ids = [secret.builderId]
            page.SecureField("Password", text: secret)
        }
        #expect(html.contains("bound-secret-xyz") == false)
        #expect(html.contains("var \(box.ids[0]) = \"\";"))
    }
}
