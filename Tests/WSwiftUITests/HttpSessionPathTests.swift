//
//  HttpSessionPathTests.swift
//  WSwiftUITests
//
//  C6: request path validation and the safe file-serving helper.
//

import Foundation
import Testing
@testable import WSwiftUI

@Suite("HTTP session: request path validator")
struct HttpSessionPathValidatorTests {

    @Test func traversalIsRejected() {
        let cases: [(String, RequestPathValidator.Rejection)] = [
            ("/binaries/../../etc/hosts", .dotSegment),
            ("/binaries/../../../../../../etc/hosts", .dotSegment),
            ("/binaries/%2e%2e/%2e%2e/etc/hosts", .dotSegment),
            ("/binaries/%2E%2E/etc/hosts", .dotSegment),
            ("/binaries/%2e%2E/etc/hosts", .dotSegment),
            ("/binaries/.%2e/etc/hosts", .dotSegment),
            ("/binaries/%2e./etc/hosts", .dotSegment),
            ("/binaries/..", .dotSegment),
            ("/..", .dotSegment),
            ("/a/./b", .dotSegment),
            ("/a/.", .dotSegment),
            ("/a/%2e/b", .dotSegment),
            ("/binaries/../../etc/hosts?x=1", .dotSegment),
        ]
        for (uri, reason) in cases {
            #expect(RequestPathValidator.validate(uri: uri) == .failure(reason), "\(uri)")
        }
    }

    @Test func encodedSeparatorsAreRejected() {
        for uri in ["/binaries/..%2Fetc%2Fhosts", "/a%2fb", "/a%2Fb", "/a%5Cb", "/a%5cb", "/binaries/..%5C..%5Cetc"] {
            #expect(RequestPathValidator.validate(uri: uri) == .failure(.encodedSeparator), "\(uri)")
        }
    }

    @Test func backslashIsRejected() {
        for uri in ["/a\\b", "/binaries/..\\..\\etc\\hosts", "\\"] {
            let result = RequestPathValidator.validate(uri: uri)
            #expect(result == .failure(.backslash) || result == .failure(.notOriginForm), "\(uri)")
        }
        #expect(RequestPathValidator.validate(uri: "/a\\b") == .failure(.backslash))
    }

    @Test func nulAndControlCharactersAreRejected() {
        for uri in ["/a%00b", "/binaries/x.png%00.txt", "/a%0d%0aX-Injected:%20yes", "/a%0A", "/a%7F", "/a%09b"] {
            #expect(RequestPathValidator.validate(uri: uri) == .failure(.controlCharacter), "\(uri)")
        }
    }

    @Test func malformedPercentEncodingIsRejected() {
        for uri in ["/a%zz", "/a%", "/a%2", "/a%%32%65", "/a%u002e"] {
            #expect(RequestPathValidator.validate(uri: uri) == .failure(.invalidPercentEncoding), "\(uri)")
        }
        for uri in ["/a%c3%28", "/%c0%ae%c0%ae/etc/hosts", "/a%ff"] {
            #expect(RequestPathValidator.validate(uri: uri) == .failure(.invalidUTF8), "\(uri)")
        }
    }

    @Test func targetsThatAreNotOriginFormAreRejected() {
        for uri in ["binaries/x", "../etc/hosts", "?a=b", "http://example.com/../etc"] {
            #expect(RequestPathValidator.validate(uri: uri) == .failure(.notOriginForm), "\(uri)")
        }
    }

    @Test func normalPathsAreAccepted() {
        let cases: [(String, String)] = [
            ("/", "/"),
            ("*", "*"),
            ("/binaries/77cd1659-94a7-4fd4-a0ea-3e302e10c446_fa79bc22-c7b7-407c-9497-0d6dd16a2a1b_icon.png",
             "/binaries/77cd1659-94a7-4fd4-a0ea-3e302e10c446_fa79bc22-c7b7-407c-9497-0d6dd16a2a1b_icon.png"),
            ("/files/my%20file.txt", "/files/my file.txt"),
            ("/caf%C3%A9/menu", "/café/menu"),
            ("/café/menu", "/café/menu"),
            ("/a/b?x=../../etc&token=%0d%0a%2F", "/a/b"),
            ("/a/...b/..c/.d/e./...", "/a/...b/..c/.d/e./..."),
            ("/a//b/", "/a//b/"),
            ("/a/%252e%252e/x", "/a/%2e%2e/x"),
            ("/sitemap.xml", "/sitemap.xml"),
            ("/controls?token=abc", "/controls"),
        ]
        for (uri, decoded) in cases {
            #expect(RequestPathValidator.validate(uri: uri) == .success(decoded), "\(uri)")
            #expect(RequestPathValidator.isAcceptable(uri: uri), "\(uri)")
        }
    }
}

/// A scratch directory tree, removed when the value is discarded.
final class HttpSessionTempTree {
    let base: URL
    let root: URL
    let outside: URL

    init() throws {
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent("wswiftui-files-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("root-secrets")
        try fm.createDirectory(at: root.appendingPathComponent("binaries/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("app bytes".utf8).write(to: root.appendingPathComponent("binaries/app.bin"))
        try Data("<p>hi</p>".utf8).write(to: root.appendingPathComponent("binaries/page.html"))
        try Data("top secret".utf8).write(to: outside.appendingPathComponent("key.txt"))
        // a symlink inside the root that points outside it, and one that stays inside
        try fm.createSymbolicLink(at: root.appendingPathComponent("binaries/escape"),
                                  withDestinationURL: outside.appendingPathComponent("key.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("binaries/escape-dir"),
                                  withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("binaries/inner"),
                                  withDestinationURL: root.appendingPathComponent("binaries/app.bin"))
        // a symlink to the root itself
        try fm.createSymbolicLink(at: base.appendingPathComponent("root-link"), withDestinationURL: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }
}

@Suite("HTTP session: safe file helper")
struct HttpSessionFileHelperTests {

    private func served(_ response: HttpResponse) -> String? {
        guard response.status.code == 200, let url = response.bodyFileUrl else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    @Test func filesInsideTheRootAreServed() throws {
        let tree = try HttpSessionTempTree()
        let response = HttpResponse.file(relativePath: "/binaries/app.bin", under: tree.root)
        #expect(served(response) == "app bytes")
        #expect(response.header(named: "Content-Type") == "application/octet-stream")
        #expect(response.header(named: "X-Content-Type-Options") == "nosniff")

        #expect(served(HttpResponse.file(relativePath: "binaries/app.bin", under: tree.root)) == "app bytes")
        #expect(served(HttpResponse.file(relativePath: "/binaries/sub/../app.bin", under: tree.root)) == "app bytes")
        #expect(served(HttpResponse.file(relativePath: "/binaries/inner", under: tree.root)) == "app bytes")

        // HTML is never guessed inline (see HttpSessionFileBodyTests for the full rule)
        let html = HttpResponse.file(relativePath: "/binaries/page.html", under: tree.root)
        #expect(html.header(named: "Content-Type") == "application/octet-stream")
        #expect(html.header(named: "Content-Disposition") == "attachment")
        let forced = HttpResponse.file(relativePath: "/binaries/page.html", under: tree.root, contentType: "text/plain")
        #expect(forced.header(named: "Content-Type") == "text/plain")
        #expect(forced.header(named: "Content-Disposition") == nil)
    }

    @Test func aSymlinkedRootStillWorks() throws {
        let tree = try HttpSessionTempTree()
        let response = HttpResponse.file(relativePath: "/binaries/app.bin", under: tree.base.appendingPathComponent("root-link"))
        #expect(served(response) == "app bytes")
    }

    @Test func escapesAreRefused() throws {
        let tree = try HttpSessionTempTree()
        let attempts = [
            "/../root-secrets/key.txt",          // sibling whose name starts with the root's name
            "/binaries/../../root-secrets/key.txt",
            "/binaries/../../../../../../../../../../etc/hosts",
            "/binaries/escape",                  // symlink to a file outside
            "/binaries/escape-dir/key.txt",      // symlink to a directory outside
            "/binaries/sub",                     // a directory
            "/binaries",
            "",
            "/",
            "/binaries/missing.bin",
            "/binaries/app.bin\0.png",
        ]
        for path in attempts {
            let response = HttpResponse.file(relativePath: path, under: tree.root)
            #expect(response.status.code == 404, "\(path.debugDescription)")
            #expect(response.bodyFileUrl == nil, "\(path.debugDescription)")
        }
    }

    @Test func aMissingRootIsRefused() throws {
        let tree = try HttpSessionTempTree()
        let response = HttpResponse.file(relativePath: "/app.bin", under: tree.base.appendingPathComponent("nope"))
        #expect(response.status.code == 404)
    }
}
