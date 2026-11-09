//
//  TestSupport.swift
//  WSwiftUITests
//
//  Shared helpers for in-process request dispatch and page rendering.
//  Slice-specific helpers belong in the slice's own test file, not here.
//

import Foundation
@testable import WSwiftUI

enum TestHTTP {

    /// Builds an in-memory request.
    static func request(_ method: HttpMethod = .GET,
                        _ uri: String,
                        headers: [(String, String)] = [],
                        body: Data? = nil) -> HttpRequest {
        var allHeaders = headers
        if let body, allHeaders.contains(where: { $0.0.lowercased() == "content-length" }) == false {
            allHeaders.append(("Content-Length", "\(body.count)"))
        }
        let head = HttpRequestHead(method: method, uri: uri, version: "HTTP/1.1", headers: allHeaders)
        return HttpRequest(head: head, body: body.map { HttpBody.inMemory($0) } ?? HttpBody.none)
    }

    /// A server that never opens a socket; dispatch with `server.respond(to:)`.
    static func server(publicBaseURL: String? = nil) -> WSwiftServer {
        return WSwiftServer(port: 0, bindAddressv4: nil, publicBaseURL: publicBaseURL, autoStart: false)
    }
}

extension HttpResponse {
    var bodyString: String { String(decoding: bodyBytes, as: UTF8.self) }

    func header(named name: String) -> String? {
        headers.first(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame })?.1
    }

    func allHeaders(named name: String) -> [String] {
        headers.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map { $0.1 }
    }
}

/// A content endpoint whose body is supplied by a closure, so tests can render arbitrary DSL.
/// Register a fresh subclass per route if you need several in one server.
final class ClosurePage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "test"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    nonisolated(unsafe) static var body: ((ClosurePage) -> Void)? = nil

    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }

    override func content() -> Any? {
        return webpage {
            ClosurePage.body?(self)
        }
    }
}

private let renderLock = NSLock()

/// Renders DSL built inside `body` to a full HTML page string, through the real dispatch path.
/// Calls are serialized with a global lock, so it is safe to use from parallel tests.
func renderHTML(uri: String = "/test", _ body: @escaping (ClosurePage) -> Void) -> String {
    renderLock.lock()
    defer { renderLock.unlock() }
    ClosurePage.body = body
    defer { ClosurePage.body = nil }
    let server = TestHTTP.server()
    server.register(ClosurePage())
    let response = server.respond(to: TestHTTP.request(.GET, uri))
    return response.bodyString
}
