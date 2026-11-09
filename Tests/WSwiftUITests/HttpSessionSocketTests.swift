//
//  HttpSessionSocketTests.swift
//  WSwiftUITests
//
//  End-to-end checks over a real TCP socket (C1, C6, H7), plus unit tests of
//  the response framing that decides Content-Length / Content-Range / status.
//

import Foundation
import Testing
@testable import WSwiftUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Fixture

enum HttpSessionFixture {

    static let fileBytes: Data = Data((0..<5000).map { UInt8($0 % 251) })

    /// Shared by every socket and framing test:
    /// - <tmp>/binaries/app.bin (5000 bytes) and <tmp>/secret.txt;
    /// - <tmp>/binaries/link.bin -> app.bin, <tmp>/binaries/dangling.bin -> a missing file,
    ///   <tmp>/binaries/dir-link -> <tmp>/binaries;
    /// - <tmp>/docfiles/ with "my file.txt", `docAccentedName`, logo.svg, page.html, icon.png and
    ///   blob.unknownext, for the HttpResponse.file doc example and its Content-Type defaults.
    static let root: URL = {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("wswiftui-socket-\(UUID().uuidString)")
        let binaries = base.appendingPathComponent("binaries")
        let docfiles = base.appendingPathComponent("docfiles")
        try! fm.createDirectory(at: binaries, withIntermediateDirectories: true)
        try! fm.createDirectory(at: docfiles, withIntermediateDirectories: true)
        try! fileBytes.write(to: binaries.appendingPathComponent("app.bin"))
        try! Data("top secret".utf8).write(to: base.appendingPathComponent("secret.txt"))
        try! fm.createSymbolicLink(atPath: binaries.appendingPathComponent("link.bin").path, withDestinationPath: "app.bin")
        try! fm.createSymbolicLink(atPath: binaries.appendingPathComponent("dangling.bin").path, withDestinationPath: "missing.bin")
        try! fm.createSymbolicLink(atPath: binaries.appendingPathComponent("dir-link").path, withDestinationPath: binaries.path)
        try! Data("spaced".utf8).write(to: docfiles.appendingPathComponent("my file.txt"))
        try! Data("accented".utf8).write(to: docfiles.appendingPathComponent(docAccentedName))
        try! Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>".utf8)
            .write(to: docfiles.appendingPathComponent("logo.svg"))
        try! Data("<script>alert(1)</script>".utf8).write(to: docfiles.appendingPathComponent("page.html"))
        try! Data([0x89, 0x50, 0x4E, 0x47]).write(to: docfiles.appendingPathComponent("icon.png"))
        try! Data("data".utf8).write(to: docfiles.appendingPathComponent("blob.unknownext"))
        return base
    }()

    /// "café.txt", built from scalars so no escape sequence has to survive in the source.
    static let docAccentedName = "caf" + String(Character(Unicode.Scalar(0xE9)!)) + ".txt"

    static var appFile: URL { root.appendingPathComponent("binaries/app.bin") }
    static var linkFile: URL { root.appendingPathComponent("binaries/link.bin") }
    static var danglingLink: URL { root.appendingPathComponent("binaries/dangling.bin") }
    static var directoryLink: URL { root.appendingPathComponent("binaries/dir-link") }

    /// One listening server on an ephemeral port for all socket tests.
    nonisolated(unsafe) static let server: WSwiftServer = {
        let server = WSwiftServer(port: 0)
        server.register(HttpSessionBinariesEndpoint())
        server.register(HttpSessionRangedEndpoint())
        server.register(HttpSessionBadRangeEndpoint())
        server.register(HttpSessionDocFilesEndpoint())
        server.register(HttpSessionProbePage())
        return server
    }()

    /// The port the shared server listens on. WSwiftServer keeps its HTTPServer private, so it
    /// is reached by reflection instead of adding a test-only hook to WebServer.swift.
    static var port: Int? {
        let listener = Mirror(reflecting: server).children.first(where: { $0.label == "svr" })?.value
        guard let http = listener as? HTTPServer, let port = http.boundPort else { return nil }
        return Int(port)
    }
}

/// The documented HttpResponse.file example, verbatim: validate (and decode) the URI, then serve.
final class HttpSessionDocFilesEndpoint: CoreWebEndpoint, WebEndpoint, WebApiEndpoint {
    var controller: String? = "docfiles"
    var method: String? = "*"
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles() -> [String]? { nil }
    func call() -> Any? {
        let root = HttpSessionFixture.root
        guard case .success(let path) = RequestPathValidator.validate(uri: request.head.uri) else {
            return HttpResponse().status(.badRequest)
        }
        return HttpResponse.file(relativePath: path, under: root)
    }
}

/// Copy of AppGrill's Filestore/Binaries.swift: it maps the raw URI straight onto the disk.
final class HttpSessionBinariesEndpoint: CoreWebEndpoint, WebEndpoint, WebApiEndpoint {
    var controller: String? = "binaries"
    var method: String? = "*"
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles() -> [String]? { nil }
    func call() -> Any? {
        let path = HttpSessionFixture.root.path + request.head.uri
        if FileManager.default.fileExists(atPath: path) {
            return HttpResponse().status(.ok).body(URL(fileURLWithPath: path))
        }
        return HttpResponse().status(.notFound)
    }
}

final class HttpSessionRangedEndpoint: CoreWebEndpoint, WebEndpoint, WebApiEndpoint {
    var controller: String? = "ranged"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles() -> [String]? { nil }
    func call() -> Any? {
        return HttpResponse().status(.ok).body(HttpSessionFixture.appFile, from: 100, to: 200)
    }
}

final class HttpSessionBadRangeEndpoint: CoreWebEndpoint, WebEndpoint, WebApiEndpoint {
    var controller: String? = "badrange"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles() -> [String]? { nil }
    func call() -> Any? {
        return HttpResponse().status(.ok).body(HttpSessionFixture.appFile, from: 6000, to: 7000)
    }
}

// MARK: - Raw socket client

struct HttpSessionRawResponse {
    var statusLine: String
    var headerLines: [String]
    var body: Data

    var statusCode: Int? {
        let parts = statusLine.split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }

    func values(_ name: String) -> [String] {
        return headerLines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            guard line[..<colon].caseInsensitiveCompare(name) == .orderedSame else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }
}

enum HttpSessionSocket {

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Sends `raw` byte-for-byte (no client-side path normalisation) and reads until the server closes.
    static func send(_ raw: String, port: Int) throws -> HttpSessionRawResponse {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw Failure(description: "socket() failed") }
        defer { close(fd) }

        var tv = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw Failure(description: "connect() failed") }

        let bytes = Array(raw.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw Failure(description: "write() failed") }
            sent += n
        }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
        }

        guard let split = received.range(of: Data("\r\n\r\n".utf8)) else {
            throw Failure(description: "no header terminator in \(received.count) bytes: \(String(decoding: received, as: UTF8.self))")
        }
        let head = String(decoding: received[received.startIndex..<split.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        return HttpSessionRawResponse(statusLine: statusLine, headerLines: lines, body: Data(received[split.upperBound...]))
    }

    static func get(_ target: String, port: Int, extraHeaders: String = "") throws -> HttpSessionRawResponse {
        return try send("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\(extraHeaders)\r\n", port: port)
    }
}

// MARK: - End-to-end

@Suite("HTTP session: over a socket")
struct HttpSessionSocketTests {

    @Test func traversalOfAnAppGrillStyleEndpointIsRejected() throws {
        let port = try #require(HttpSessionFixture.port, "server did not start")
        let deep = String(repeating: "../", count: 16)
        for target in ["/binaries/../secret.txt",
                       "/binaries/\(deep)etc/hosts",
                       "/binaries/%2e%2e/secret.txt",
                       "/binaries/%2E%2E/%2e%2e/\(deep)etc/hosts",
                       "/binaries/..%2Fsecret.txt",
                       "/binaries/..%5Csecret.txt",
                       "/binaries/..\\secret.txt",
                       "/binaries/app.bin%00.png"] {
            let response = try HttpSessionSocket.get(target, port: port)
            #expect(response.statusCode == 400, "\(target)")
            #expect(String(decoding: response.body, as: UTF8.self).contains("top secret") == false, "\(target)")
            #expect(response.values("Content-Length") == ["\(response.body.count)"], "\(target)")
        }
    }

    @Test func fileResponseSendsItsRealLengthOnce() throws {
        let port = try #require(HttpSessionFixture.port, "server did not start")
        let response = try HttpSessionSocket.get("/binaries/app.bin", port: port)
        #expect(response.statusCode == 200)
        #expect(response.values("Content-Length") == ["5000"])
        #expect(response.body == HttpSessionFixture.fileBytes)
        #expect(response.values("Connection") == ["close"])
    }

    @Test func missingFileIsNotFound() throws {
        let port = try #require(HttpSessionFixture.port, "server did not start")
        let response = try HttpSessionSocket.get("/binaries/nope.bin", port: port)
        #expect(response.statusCode == 404)
        #expect(response.values("Content-Length") == ["\(response.body.count)"])
    }

    @Test func rangedFileResponseIsPartialContentWithOneLength() throws {
        let port = try #require(HttpSessionFixture.port, "server did not start")
        let response = try HttpSessionSocket.get("/ranged", port: port)
        #expect(response.statusCode == 206)
        #expect(response.values("Content-Length") == ["100"])
        #expect(response.values("Content-Range") == ["bytes 100-199/5000"])
        #expect(response.body == HttpSessionFixture.fileBytes.subdata(in: 100..<200))
    }

    @Test func unsatisfiableRangeIs416() throws {
        let port = try #require(HttpSessionFixture.port, "server did not start")
        let response = try HttpSessionSocket.get("/badrange", port: port)
        #expect(response.statusCode == 416)
        #expect(response.values("Content-Range") == ["bytes */5000"])
        #expect(response.values("Content-Length") == ["0"])
        #expect(response.body.isEmpty)
    }

    @Test func crlfQueryTokenCannotSplitTheResponse() throws {
        let port = try #require(HttpSessionFixture.port, "server did not start")
        let response = try HttpSessionSocket.get("/session-probe?token=\(HttpSessionHelpers.crlfToken)", port: port)
        #expect(response.statusCode == 200)
        #expect(response.values("X-Injected").isEmpty)
        #expect(response.values("Set-Cookie") == [HttpSessionHelpers.anonymousCookie])
        #expect(response.values("Content-Length") == ["\(response.body.count)"])
    }

    @Test func bareLineFeedInsideARequestHeaderIsRejected() throws {
        let port = try #require(HttpSessionFixture.port, "server did not start")
        // the bad header is the last thing sent, so the server has nothing left unread when it closes
        let response = try HttpSessionSocket.send("GET /session-probe HTTP/1.1\r\nHost: 127.0.0.1\r\nCookie: auth=abc\nX-Injected: yes\r\n", port: port)
        #expect(response.statusCode == 400)
        #expect(response.values("X-Injected").isEmpty)
    }

    @Test func normalPagesStillWork() throws {
        let port = try #require(HttpSessionFixture.port, "server did not start")
        let response = try HttpSessionSocket.get("/session-probe?name=caf%C3%A9&x=%2F..%2F", port: port,
                                                 extraHeaders: "Cookie: auth=tok-123\r\n")
        #expect(response.statusCode == 200)
        #expect(response.values("Set-Cookie") == [HttpSessionHelpers.cookie("tok-123")])
        #expect(response.values("Content-Length") == ["\(response.body.count)"])
        #expect(response.body.isEmpty == false)
    }
}

// MARK: - Framing (unit)

@Suite("HTTP session: response framing")
struct HttpSessionFramingTests {

    private func values(_ prepared: HTTPServer.PreparedResponse, _ name: String) -> [String] {
        return prepared.headers.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map { $0.1 }
    }

    @Test func fullFileHasItsSize() {
        let prepared = HTTPServer.prepare(HttpResponse().status(.ok).body(HttpSessionFixture.appFile))
        #expect(prepared.status.code == 200)
        #expect(values(prepared, "Content-Length") == ["5000"])
        #expect(values(prepared, "Content-Range").isEmpty)
        #expect(prepared.body == .file(HttpSessionFixture.appFile, offset: 0, length: 5000))
    }

    @Test func rangeIsPartialContent() {
        let prepared = HTTPServer.prepare(HttpResponse().status(.ok).body(HttpSessionFixture.appFile, from: 0, to: 100))
        #expect(prepared.status.code == 206)
        #expect(values(prepared, "Content-Length") == ["100"])
        #expect(values(prepared, "Content-Range") == ["bytes 0-99/5000"])
        #expect(prepared.body == .file(HttpSessionFixture.appFile, offset: 0, length: 100))
    }

    @Test func rangePastTheEndIsClamped() {
        let prepared = HTTPServer.prepare(HttpResponse().body(HttpSessionFixture.appFile, from: 4990, to: 6000))
        #expect(prepared.status.code == 206)
        #expect(values(prepared, "Content-Length") == ["10"])
        #expect(values(prepared, "Content-Range") == ["bytes 4990-4999/5000"])
    }

    @Test func unsatisfiableRangesAre416() {
        for (from, to) in [(5000, 5100), (10, 5), (-5, 10), (7, 7)] {
            let prepared = HTTPServer.prepare(HttpResponse().status(.ok).body(HttpSessionFixture.appFile, from: from, to: to))
            #expect(prepared.status.code == 416, "\(from)-\(to)")
            #expect(values(prepared, "Content-Range") == ["bytes */5000"], "\(from)-\(to)")
            #expect(values(prepared, "Content-Length") == ["0"], "\(from)-\(to)")
            #expect(prepared.body == .none, "\(from)-\(to)")
        }
    }

    @Test func missingOrDirectoryFileIs404() {
        for url in [HttpSessionFixture.root.appendingPathComponent("binaries/missing.bin"),
                    HttpSessionFixture.root.appendingPathComponent("binaries")] {
            let prepared = HTTPServer.prepare(HttpResponse().status(.ok).body(url))
            #expect(prepared.status.code == 404, "\(url.path)")
            #expect(values(prepared, "Content-Length") == ["9"], "\(url.path)")
        }
    }

    @Test func appSuppliedLengthsAreReplaced() {
        let memory = HttpResponse().header("Content-Length", "999").header("Transfer-Encoding", "chunked").body("hello")
        let prepared = HTTPServer.prepare(memory)
        #expect(values(prepared, "Content-Length") == ["5"])
        #expect(values(prepared, "Transfer-Encoding").isEmpty)
        #expect(prepared.body == .bytes(Data("hello".utf8)))

        let file = HttpResponse().header("Content-Length", "0").header("Content-Range", "bytes 0-0/1").body(HttpSessionFixture.appFile)
        let preparedFile = HTTPServer.prepare(file)
        #expect(values(preparedFile, "Content-Length") == ["5000"])
        #expect(values(preparedFile, "Content-Range").isEmpty)
    }

    @Test func bodylessStatusesHaveNoLength() {
        let noContent = HTTPServer.prepare(HttpResponse().status(.noContent))
        #expect(values(noContent, "Content-Length").isEmpty)
        #expect(noContent.body == .none)

        let upgrade = HTTPServer.prepare(HttpResponse().acceptWebSocket(key: "dGhlIHNhbXBsZSBub25jZQ=="))
        #expect(values(upgrade, "Content-Length").isEmpty)
        #expect(values(upgrade, "Connection") == ["Upgrade"])
        #expect(values(upgrade, "Sec-WebSocket-Accept") == ["s3pPLMBiTxaQ9kYGzzhZRbK+xOo="])
    }

    @Test func inMemoryBodiesAreUnchanged() {
        let prepared = HTTPServer.prepare(HttpResponse().status(.ok).content(.html).body("<p>hi</p>"))
        #expect(prepared.status.code == 200)
        #expect(values(prepared, "Content-Length") == ["9"])
        #expect(values(prepared, "Content-Type") == ["text/html; charset=utf-8"])
        #expect(values(prepared, "Connection") == ["close"])
        #expect(values(prepared, "Server") == ["MicroHTTP/1.0"])
        #expect(values(prepared, "Date").count == 1)
    }

    @Test func statusReasonCannotSplitTheResponse() {
        let prepared = HTTPServer.prepare(HttpResponse().status(HttpStatus(200, "OK\r\nX-Injected: yes")))
        #expect(prepared.status.reason.utf8.contains(where: { $0 == 13 || $0 == 10 }) == false)
        #expect(prepared.status.code == 200)
    }
}
