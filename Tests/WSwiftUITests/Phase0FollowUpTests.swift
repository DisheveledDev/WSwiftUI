//
//  Phase0FollowUpTests.swift
//  WSwiftUITests
//
//  Regression tests for the cross-slice follow-ups applied after the five Phase 0 slices merged:
//   - the WebSocket loop starts only after the 101 has been written (onUpgraded hand-off)
//   - request JSON parsed by validateData(.validJSON) and HttpRequest.decodeBody is depth-limited
//   - raw script bodies can't contain a literal `</script` (renderer defence in depth)
//

import Foundation
import Testing
@testable import WSwiftUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - WebSocket upgrade hand-off

final class HandoffUnitWebsocketEndpoint: CoreWebsocketEndpoint, WebEndpoint, @unchecked Sendable {
    var controller: String? = "phase0-handoff-unit"
    var method: String? = nil
    override var tickInterval: TimeInterval { get { 0 } set {} }

    static let opened = DispatchSemaphore(value: 0)

    override func onOpen(connection: WebSocketConnection, request: HttpRequest) {
        _ = connection.safeSend(frame: WebSocketFrame(fin: true, opcode: .text, payload: Data("hello-from-onOpen".utf8)))
        Self.opened.signal()
    }
}

final class HandoffTCPWebsocketEndpoint: CoreWebsocketEndpoint, WebEndpoint, @unchecked Sendable {
    var controller: String? = "phase0-handoff-tcp"
    var method: String? = nil
    override var tickInterval: TimeInterval { get { 0 } set {} }

    override func onOpen(connection: WebSocketConnection, request: HttpRequest) {
        // Sent as early as possible: before the fix this could reach the wire ahead of the 101.
        _ = connection.safeSend(frame: WebSocketFrame(fin: true, opcode: .text, payload: Data("hello-from-onOpen".utf8)))
    }
}

@Suite("Phase 0 follow-up: WebSocket upgrade hand-off", .serialized)
struct WebsocketUpgradeHandoffTests {

    static let key = "dGhlIHNhbXBsZSBub25jZQ=="

    @Test func loopDoesNotStartUntilTheUpgradeHookRuns() throws {
        let peer = try RawWebsocketPeer()
        let server = TestHTTP.server()
        server.registerWebSocket(HandoffUnitWebsocketEndpoint())

        let head = HttpRequestHead(method: .GET, uri: "/phase0-handoff-unit", version: "HTTP/1.1", headers: [
            ("Upgrade", "websocket"), ("Connection", "Upgrade"),
            ("Sec-WebSocket-Key", Self.key), ("Sec-WebSocket-Version", "13"),
        ])
        let upgrade = WebSocketUpgrade(key: Self.key, protocols: [], version: 13, extensions: nil, socketFD: peer.serverFD)
        let response = server.respond(to: HttpRequest(head: head, body: .none, kind: .websocket(upgrade)))

        #expect(response.status.code == 101)
        // The handler alone must not start the loop: nothing has been written yet.
        #expect(HandoffUnitWebsocketEndpoint.opened.wait(timeout: .now() + 0.5) == .timedOut,
                "onOpen ran before the 101 was written")

        let hook = try #require(response.onUpgraded, "a 101 response must carry the hand-off hook")
        hook()
        #expect(HandoffUnitWebsocketEndpoint.opened.wait(timeout: .now() + 5) == .success)
        #expect(peer.readFrame()?.text == "hello-from-onOpen")

        peer.send(WebsocketWireBuilder.close(1000))
        #expect(peer.readFrame()?.closeCode == 1000)
    }

    @Test func overTCPTheHandshakeAlwaysPrecedesOnOpenFrames() throws {
        signal(SIGPIPE, SIG_IGN)
        var started: (WSwiftServer, UInt16)? = nil
        for _ in 0..<5 {
            guard let port = WebsocketTCP.freePort() else { continue }
            let server = WSwiftServer(port: Int(port))
            server.registerWebSocket(HandoffTCPWebsocketEndpoint())
            if websocketEventually(timeout: 2, { () -> Bool in
                guard let fd = WebsocketTCP.connect(port: port) else { return false }
                _ = close(fd)
                return true
            }) {
                started = (server, port)
                break
            }
        }
        // WSwiftServer has no public stop(); like the other TCP fixtures it lives until the process exits.
        let (server, port) = try #require(started, "could not start a WSwiftServer on a free port")
        defer { withExtendedLifetime(server) {} }

        for attempt in 0..<25 {
            let fd = try #require(WebsocketTCP.connect(port: port))
            let peer = RawWebsocketPeer(connectedClientFD: fd)
            let request = "GET /phase0-handoff-tcp HTTP/1.1\r\n"
                + "Host: 127.0.0.1:\(port)\r\n"
                + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Key: \(Self.key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
            #expect(peer.send(Array(request.utf8)))
            let head = try #require(peer.readHTTPHead(), "attempt \(attempt): no HTTP head")
            #expect(head.hasPrefix("HTTP/1.1 101"), "attempt \(attempt): stream did not start with the 101: \(head.prefix(40))")
            #expect(peer.readFrame()?.text == "hello-from-onOpen", "attempt \(attempt)")
            peer.send(WebsocketWireBuilder.close(1000))
            _ = peer.readFrame()
        }
    }
}

// MARK: - Request JSON depth limits

struct Phase0SmallBody: Decodable, Equatable { var a: Int }

final class Phase0ValidJSONPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "phase0-validjson"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }

    override func content() -> Any? { webpage { } }

    override func persist() -> Any? {
        let ok = validateData([.named("payload", [.validJSON])])
        return HttpResponse().status(.ok).content(.text).body(ok ? "valid" : "invalid")
    }
}

@Suite("Phase 0 follow-up: request JSON depth limits")
struct RequestJSONDepthTests {

    private static func nested(_ depth: Int) -> String {
        String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
    }

    @Test func decodeBodyRefusesDeepJSONInsteadOfOverflowing() {
        let outcome = multipartOnWorkerThread { () -> String in
            let body = Data(Self.nested(100_000).utf8)
            let request = TestHTTP.request(.POST, "/x", headers: [("Content-Type", "application/json")], body: body)
            do {
                _ = try request.decodeBody([Int].self)
                return "decoded"
            } catch {
                return "refused"
            }
        }
        #expect(outcome == "refused")
    }

    @Test func decodeBodyStillDecodesOrdinaryJSON() throws {
        let request = TestHTTP.request(.POST, "/x", headers: [("Content-Type", "application/json")], body: Data(#"{"a":7}"#.utf8))
        #expect(try request.decodeBody(Phase0SmallBody.self) == Phase0SmallBody(a: 7))
    }

    @Test func validJSONValidationRefusesDeepJSONOnAWorkerThread() {
        let results = multipartOnWorkerThread { () -> [String] in
            let server = TestHTTP.server()
            server.register(Phase0ValidJSONPage())
            return [Self.nested(100_000), #"{"a":[1,2,{"b":null}]}"#, "not json"].map { json in
                let encoded = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                let response = server.respond(to: TestHTTP.request(
                    .POST, "/phase0-validjson",
                    headers: [("Content-Type", "application/x-www-form-urlencoded")],
                    body: Data("payload=\(encoded)".utf8)))
                return response.bodyString
            }
        }
        #expect(results == ["invalid", "valid", "invalid"])
    }
}

// MARK: - Raw script bodies

@Suite("Phase 0 follow-up: raw script bodies", .serialized)
struct ScriptElementBodyTests {

    @Test func closingScriptTagsAreNeutralisedInAnyCase() {
        #expect(WebJSON.scriptElementBody("a('</script>'); b('</SCRIPT >'); c('</ScRiPt')") ==
                #"a('<\/script>'); b('<\/SCRIPT >'); c('<\/ScRiPt')"#)
    }

    @Test func ordinaryScriptsAreUnchanged() {
        let js = "if (a < b && c > d) { x = '</div>'; y = /<\\/p>/; }"
        #expect(WebJSON.scriptElementBody(js) == js)
        #expect(WebJSON.scriptElementBody("") == "")
    }

    @Test func rawElementScriptCannotEndTheScriptElement() {
        let html = renderHTML { page in
            _ = page.create { el in
                el.elementName = "div"
                el.addAttribute(.script("console.log('</script><img src=x onerror=alert(1)>');"))
            }
        }
        #expect(html.contains("</script><img") == false)
        #expect(html.contains(#"console.log('<\/script><img src=x onerror=alert(1)>');"#))
    }
}
