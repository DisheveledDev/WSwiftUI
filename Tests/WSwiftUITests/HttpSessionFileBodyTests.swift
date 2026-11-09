//
//  HttpSessionFileBodyTests.swift
//  WSwiftUITests
//
//  File bodies (H7 / C6 follow-ups):
//  - body(URL) follows symlinks the way FileHandle does, so a link to a regular
//    file is served with the target's size and a dangling link is 404;
//  - the documented HttpResponse.file example decodes the path, so encoded names work;
//  - HttpResponse.file never guesses an active Content-Type (HTML, SVG, XML, JS).
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Symlinked file bodies (framing, unit)

@Suite("HTTP session: symlinked file bodies")
struct HttpSessionSymlinkBodyTests {

    private func values(_ prepared: HTTPServer.PreparedResponse, _ name: String) -> [String] {
        return prepared.headers.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map { $0.1 }
    }

    @Test func symlinkToARegularFileIsServedWithTheTargetsSize() throws {
        let link = HttpSessionFixture.linkFile
        // the fixture really is a link (attributesOfItem does not follow the last component)
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect((attributes[.type] as? FileAttributeType) == .typeSymbolicLink)

        let prepared = HTTPServer.prepare(HttpResponse().status(.ok).body(link))
        #expect(prepared.status.code == 200)
        #expect(values(prepared, "Content-Length") == ["5000"])
        #expect(prepared.body == .file(link, offset: 0, length: 5000))
    }

    @Test func symlinkRangeIsPartialContent() {
        let link = HttpSessionFixture.linkFile
        let prepared = HTTPServer.prepare(HttpResponse().status(.ok).body(link, from: 10, to: 20))
        #expect(prepared.status.code == 206)
        #expect(values(prepared, "Content-Length") == ["10"])
        #expect(values(prepared, "Content-Range") == ["bytes 10-19/5000"])
        #expect(prepared.body == .file(link, offset: 10, length: 10))
    }

    @Test func danglingOrDirectorySymlinkIs404() {
        for url in [HttpSessionFixture.danglingLink, HttpSessionFixture.directoryLink] {
            let prepared = HTTPServer.prepare(HttpResponse().status(.ok).body(url))
            #expect(prepared.status.code == 404, "\(url.lastPathComponent)")
            #expect(values(prepared, "Content-Length") == ["9"], "\(url.lastPathComponent)")
            #expect(prepared.body == .bytes(Data("Not Found".utf8)), "\(url.lastPathComponent)")
        }
    }

    @Test func fileReachedThroughASymlinkedDirectoryIsServed() {
        let url = HttpSessionFixture.directoryLink.appendingPathComponent("app.bin")
        let prepared = HTTPServer.prepare(HttpResponse().status(.ok).body(url))
        #expect(prepared.status.code == 200)
        #expect(values(prepared, "Content-Length") == ["5000"])
    }
}

// MARK: - Over a socket

@Suite("HTTP session: file bodies over a socket")
struct HttpSessionFileBodySocketTests {

    /// An AppGrill-style endpoint (`fileExists` then `body(URL)`) serving a `latest.apk`-style alias.
    @Test func appGrillStyleSymlinkIsServed() throws {
        let port = try #require(HttpSessionFixture.port, "server did not start")
        let response = try HttpSessionSocket.get("/binaries/link.bin", port: port)
        #expect(response.statusCode == 200)
        #expect(response.values("Content-Length") == ["5000"])
        #expect(response.body == HttpSessionFixture.fileBytes)
    }

    @Test func appGrillStyleDanglingSymlinkIsNotFound() throws {
        let port = try #require(HttpSessionFixture.port, "server did not start")
        let response = try HttpSessionSocket.get("/binaries/dangling.bin", port: port)
        #expect(response.statusCode == 404)
        #expect(response.values("Content-Length") == ["\(response.body.count)"])
    }

    /// The doc example on HttpResponse.file, run as written: names that need percent-encoding are found.
    @Test func documentedFileExampleServesEncodedNames() throws {
        let port = try #require(HttpSessionFixture.port, "server did not start")

        let spaced = try HttpSessionSocket.get("/docfiles/my%20file.txt", port: port)
        #expect(spaced.statusCode == 200)
        #expect(String(decoding: spaced.body, as: UTF8.self) == "spaced")
        #expect(spaced.values("Content-Type") == ["text/plain; charset=utf-8"])
        #expect(spaced.values("Content-Length") == ["6"])
        #expect(spaced.values("Content-Disposition").isEmpty)

        let accented = try HttpSessionSocket.get("/docfiles/caf%C3%A9.txt", port: port)
        #expect(accented.statusCode == 200)
        #expect(String(decoding: accented.body, as: UTF8.self) == "accented")

        let missing = try HttpSessionSocket.get("/docfiles/nope.txt", port: port)
        #expect(missing.statusCode == 404)

        let traversal = try HttpSessionSocket.get("/docfiles/%2e%2e/secret.txt", port: port)
        #expect(traversal.statusCode == 400)
        #expect(String(decoding: traversal.body, as: UTF8.self).contains("top secret") == false)
    }

    @Test func activeFilesAreDownloadedNotRendered() throws {
        let port = try #require(HttpSessionFixture.port, "server did not start")
        for name in ["logo.svg", "page.html", "blob.unknownext"] {
            let response = try HttpSessionSocket.get("/docfiles/\(name)", port: port)
            #expect(response.statusCode == 200, "\(name)")
            #expect(response.values("Content-Type") == ["application/octet-stream"], "\(name)")
            #expect(response.values("Content-Disposition") == ["attachment"], "\(name)")
            #expect(response.values("X-Content-Type-Options") == ["nosniff"], "\(name)")
        }
        let png = try HttpSessionSocket.get("/docfiles/icon.png", port: port)
        #expect(png.statusCode == 200)
        #expect(png.values("Content-Type") == ["image/png"])
        #expect(png.values("Content-Disposition").isEmpty)
    }
}

// MARK: - Content-Type defaults (unit)

@Suite("HTTP session: file helper content types")
struct HttpSessionFileContentTypeTests {

    private var docfiles: URL { HttpSessionFixture.root.appendingPathComponent("docfiles") }

    @Test func activeFormatsAreNeverGuessed() {
        for ext in ["html", "HTML", "htm", "xhtml", "shtml", "svg", "SVG", "svgz", "xml", "xsl", "plist", "js", "mjs", "cjs"] {
            #expect(SafeFileResolver.contentType(forExtension: ext) == "application/octet-stream", "\(ext)")
        }
    }

    @Test func passiveFormatsKeepTheirType() {
        let expected: [(String, String)] = [
            ("png", "image/png"), ("PNG", "image/png"), ("jpg", "image/jpeg"), ("gif", "image/gif"),
            ("css", "text/css; charset=utf-8"), ("json", "application/json"), ("txt", "text/plain; charset=utf-8"),
            ("pdf", "application/pdf"), ("woff2", "font/woff2"), ("apk", "application/vnd.android.package-archive"),
            ("", "application/octet-stream"), ("bin", "application/octet-stream"),
        ]
        for (ext, type) in expected {
            #expect(SafeFileResolver.contentType(forExtension: ext) == type, "\(ext)")
        }
    }

    @Test func svgAndHtmlAreAttachmentsByDefault() {
        for name in ["/logo.svg", "/page.html", "/blob.unknownext"] {
            let response = HttpResponse.file(relativePath: name, under: docfiles)
            #expect(response.status.code == 200, "\(name)")
            #expect(response.header(named: "Content-Type") == "application/octet-stream", "\(name)")
            #expect(response.header(named: "Content-Disposition") == "attachment", "\(name)")
            #expect(response.header(named: "X-Content-Type-Options") == "nosniff", "\(name)")
        }
    }

    @Test func anExplicitContentTypeIsServedInline() {
        let response = HttpResponse.file(relativePath: "/logo.svg", under: docfiles, contentType: "image/svg+xml")
        #expect(response.header(named: "Content-Type") == "image/svg+xml")
        #expect(response.header(named: "Content-Disposition") == nil)
        #expect(response.header(named: "X-Content-Type-Options") == "nosniff")
    }

    @Test func passiveFilesAreInline() {
        let response = HttpResponse.file(relativePath: "/icon.png", under: docfiles)
        #expect(response.header(named: "Content-Type") == "image/png")
        #expect(response.header(named: "Content-Disposition") == nil)
    }

    /// The raw request path is still percent-encoded, which is why the doc example decodes it first.
    @Test func theRawPathIsNotDecoded() {
        #expect(HttpResponse.file(relativePath: "/my%20file.txt", under: docfiles).status.code == 404)
        guard case .success(let decoded) = RequestPathValidator.validate(uri: "/my%20file.txt?x=1") else {
            Issue.record("validator rejected a valid path")
            return
        }
        #expect(HttpResponse.file(relativePath: decoded, under: docfiles).status.code == 200)
    }
}
