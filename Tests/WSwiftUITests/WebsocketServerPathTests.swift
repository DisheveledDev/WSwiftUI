//
//  WebsocketServerPathTests.swift
//  WSwiftUITests
//
//  WebSocket paths the socketpair tests in WebsocketFramingTests.swift do not reach:
//  a protocol error while another thread is blocked writing (the write-lock timeout in
//  failConnection), and the full server path over TCP (HTTP upgrade through
//  WSwiftServer.registerWebSocket and HTTPServer.handleConnection, then the frame that
//  used to kill the process with exit 133).
//

import Foundation
import Testing
@testable import WSwiftUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Protocol error while a tick writer holds the write lock

/// Its first tick sends one frame far larger than the socket buffers. The peer never reads,
/// so the tick thread blocks in write() while holding the connection's write lock.
final class FloodingWebsocketEndpoint: CoreWebsocketEndpoint, @unchecked Sendable {
    override var tickInterval: TimeInterval { get { 0.01 } set {} }

    static let floodBytes = 4 << 20
    static let floodByte: UInt8 = 0x5A

    let tickEntered = DispatchSemaphore(value: 0)
    let tickReturned = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    /// nil while the flood is still being written; then whether the send succeeded.
    let floodResult = WebsocketTestBox<Bool?>(nil)
    let closeInfo = WebsocketTestBox<(code: UInt16?, at: Date)?>(nil)
    let connection = WebsocketTestBox<WebSocketConnection?>(nil)
    private let flooded = WebsocketTestBox(false)

    override func onOpen(connection: WebSocketConnection, request: HttpRequest) {
        self.connection.value = connection
    }

    override func onTick(connection: WebSocketConnection) {
        // Ticks from one timer never overlap, so this check-then-set is safe.
        guard !flooded.value else { return }
        flooded.value = true
        tickEntered.signal()
        let payload = Data(repeating: Self.floodByte, count: Self.floodBytes)
        floodResult.value = connection.safeSend(frame: WebSocketFrame(fin: true, opcode: .binary, payload: payload))
        tickReturned.signal()
    }

    override func onClose(connection: WebSocketConnection, code: UInt16?, reason: String?) {
        closeInfo.value = (code, Date())
        closed.signal()
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func websocketEventually(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

@Suite("WebSocket failure while a writer is blocked")
struct WebsocketBlockedWriterTests {

    /// The reader waits at most about 1 s for the write lock, then skips the Close frame
    /// (so it is never spliced into the half-written frame), shuts the socket down, which
    /// wakes the blocked writer, and reports 1002. The descriptor is then released once.
    @Test func protocolErrorWhileATickWriterIsBlockedClosesWithinTheLockTimeout() throws {
        let peer = try RawWebsocketPeer(serverReadTimeout: 30)
        let endpoint = FloodingWebsocketEndpoint()
        endpoint.startWebSocket(WebSocketUpgrade(key: "dGhlIHNhbXBsZSBub25jZQ==", protocols: [],
                                                 version: 13, extensions: nil, socketFD: peer.serverFD))

        #expect(endpoint.tickEntered.wait(timeout: .now() + 5) == .success, "the first tick never ran")
        Thread.sleep(forTimeInterval: 0.2)
        try #require(endpoint.floodResult.value == nil, "the flood must still be blocked in write()")

        let sent = Date()
        peer.send(WebsocketWireBuilder.frame(opcode: 0x1, payload: Array("bad".utf8), masked: false))

        #expect(endpoint.closed.wait(timeout: .now() + 5) == .success, "the reader hung behind the blocked writer")
        let info = try #require(endpoint.closeInfo.value)
        #expect(info.code == 1002)
        let waited = info.at.timeIntervalSince(sent)
        #expect(waited >= 0.9, "the reader should have waited for the write lock first (waited \(waited)s)")
        #expect(waited < 3, "the reader waited too long for the write lock (\(waited)s)")

        // shutdown() woke the blocked writer, and its send failed.
        #expect(endpoint.tickReturned.wait(timeout: .now() + 5) == .success, "the blocked writer was not woken")
        #expect(endpoint.floodResult.value == false)

        let conn = try #require(endpoint.connection.value)
        #expect(websocketEventually { conn.descriptorReleaseCount == 1 }, "the descriptor was not released")
        #expect(conn.descriptorReleaseCount == 1)

        // The peer got a prefix of the flood frame and then EOF: no Close frame was spliced in.
        let (bytes, sawEOF) = peer.drain()
        #expect(sawEOF)
        let length = UInt64(FloodingWebsocketEndpoint.floodBytes)
        let header: [UInt8] = [0x82, 127] + (0..<8).reversed().map { UInt8((length >> (8 * UInt64($0))) & 0xFF) }
        #expect(bytes.count >= header.count)
        #expect(Array(bytes.prefix(header.count)) == header)
        #expect(bytes.dropFirst(header.count).allSatisfy { $0 == FloodingWebsocketEndpoint.floodByte },
                "bytes other than the flood payload reached the peer")
    }
}

// MARK: - Full server path over TCP

/// Records the close code `onClose` saw for each connection, keyed by the
/// X-Test-Token header the client sent with its upgrade request.
final class WebsocketCloseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [String: UInt16?] = [:]

    func record(_ token: String, _ code: UInt16?) {
        lock.lock()
        codes[token] = code
        lock.unlock()
    }

    /// The code recorded for `token`, waiting up to `timeout` for `onClose` to run.
    /// Returns `.some(nil)` when onClose ran without a code, nil when it never ran.
    func code(for token: String, timeout: TimeInterval = 5) -> UInt16?? {
        var result: UInt16?? = nil
        _ = websocketEventually(timeout: timeout) {
            lock.lock()
            defer { lock.unlock() }
            result = codes[token]
            return result != nil
        }
        return result
    }
}

/// The default echo endpoint, served by WSwiftServer over TCP.
final class TCPEchoWebsocketEndpoint: CoreWebsocketEndpoint, WebEndpoint, @unchecked Sendable {
    var controller: String? = "websocket-slice-tcp-echo"
    var method: String? = nil
    override var tickInterval: TimeInterval { get { 0 } set {} }

    static let closes = WebsocketCloseRecorder()

    override func onClose(connection: WebSocketConnection, code: UInt16?, reason: String?) {
        if let token = request.head.headerMap["x-test-token"] {
            Self.closes.record(token, code)
        }
    }
}

extension RawWebsocketPeer {
    /// Reads the HTTP response head (up to and including the blank line).
    func readHTTPHead(limit: Int = 16 * 1024) -> String? {
        var head: [UInt8] = []
        while head.count < limit {
            guard let byte = readExactly(1) else { return nil }
            head += byte
            if head.count >= 4 && Array(head.suffix(4)) == [13, 10, 13, 10] {
                return String(decoding: head, as: UTF8.self)
            }
        }
        return nil
    }

    /// True when the server ended the connection: EOF, or a reset because the server
    /// closed with unread bytes (the rest of a refused frame) in its receive buffer.
    func readsEndOfStream() -> Bool {
        var byte: UInt8 = 0
        while true {
            let r = read(clientFD, &byte, 1)
            if r < 0 && errno == EINTR { continue }
            return r == 0 || (r < 0 && errno == ECONNRESET)
        }
    }
}

enum WebsocketTCP {
    static let path = "/websocket-slice-tcp-echo"
    static let key = "dGhlIHNhbXBsZSBub25jZQ=="
    /// RFC 6455 section 1.3's accept value for `key`.
    static let accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

    /// One server for the whole run, on a port that was free a moment before. nil if it
    /// could not be started. WSwiftServer has no stop(), so it lives until the process exits.
    nonisolated(unsafe) static let server: (server: WSwiftServer, port: UInt16)? = {
        signal(SIGPIPE, SIG_IGN)
        for _ in 0..<5 {
            guard let port = freePort() else { continue }
            let server = WSwiftServer(port: Int(port))
            server.registerWebSocket(TCPEchoWebsocketEndpoint())
            // Make sure the port is really ours: the upgrade must reach our endpoint.
            if let probe = upgrade(port: port, token: "probe-\(UUID().uuidString)") {
                probe.send(WebsocketWireBuilder.text("probe"))
                if probe.readFrame()?.text == "Echo: probe" {
                    return (server, port)
                }
            }
        }
        return nil
    }()

    /// A TCP port that nothing was listening on when it was picked.
    static func freePort() -> UInt16? {
#if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
#else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#endif
        guard fd >= 0 else { return nil }
        defer { _ = close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: 0) // INADDR_ANY, as WSwiftServer binds
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len) == 0 && getsockname(fd, sa, &len) == 0
            }
        }
        guard bound else { return nil }
        let port = UInt16(bigEndian: addr.sin_port)
        return port == 0 ? nil : port
    }

    /// Connects to 127.0.0.1:`port` with a 5 s read timeout.
    static func connect(port: UInt16) -> Int32? {
#if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
#else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#endif
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
#if canImport(Darwin)
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
#else
                Glibc.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
#endif
            }
        }
        guard connected else {
            _ = close(fd)
            return nil
        }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
#if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
#endif
        return fd
    }

    /// Opens a WebSocket over TCP and waits for the whole 101 response before returning,
    /// so the HTTP side is done with the server's descriptor before any frame is sent.
    static func upgrade(port: UInt16, token: String) -> RawWebsocketPeer? {
        guard let fd = connect(port: port) else { return nil }
        let peer = RawWebsocketPeer(connectedClientFD: fd)
        let request = "GET \(path) HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\n"
            + "Sec-WebSocket-Version: 13\r\n"
            + "X-Test-Token: \(token)\r\n"
            + "\r\n"
        guard peer.send(Array(request.utf8)),
              let head = peer.readHTTPHead(),
              head.hasPrefix("HTTP/1.1 101"),
              head.contains(accept) else { return nil }
        return peer
    }
}

@Suite("WebSocket over TCP")
struct WebsocketTCPTests {

    /// The reported crash end to end: upgrade through WSwiftServer, then a frame header
    /// declaring 0x7000_0000_0000_0000 bytes. The original code died with exit 133; now the
    /// client gets close 1009, onClose sees 1009, and the server keeps serving.
    @Test func hugeDeclaredLengthOverTCPIsRefusedAndTheServerKeepsServing() throws {
        let port = try #require(WebsocketTCP.server?.port, "could not start a WSwiftServer on a free port")

        let attackerToken = "huge-\(UUID().uuidString)"
        let attacker = try #require(WebsocketTCP.upgrade(port: port, token: attackerToken))
        let started = Date()
        attacker.send(WebsocketWireBuilder.frame(opcode: 0x1, declaredLength: 0x7000_0000_0000_0000))
        let close = attacker.readFrame()
        #expect(close?.opcode == 0x8, "expected a Close frame")
        #expect(close?.masked == false)
        #expect(close?.closeCode == 1009)
        #expect(attacker.readsEndOfStream())
        #expect(Date().timeIntervalSince(started) < 2, "the frame must be refused from its header")
        #expect(TCPEchoWebsocketEndpoint.closes.code(for: attackerToken) == .some(1009))

        // The process survived and the server still accepts and serves new connections.
        let clientToken = "alive-\(UUID().uuidString)"
        let client = try #require(WebsocketTCP.upgrade(port: port, token: clientToken))
        client.send(WebsocketWireBuilder.text("alive"))
        #expect(client.readFrame()?.text == "Echo: alive")
        client.send(WebsocketWireBuilder.close(1000))
        #expect(client.readFrame()?.closeCode == 1000)
        #expect(client.readsEndOfStream())
        #expect(TCPEchoWebsocketEndpoint.closes.code(for: clientToken) == .some(1000))
    }

    /// Over TCP, a client that breaks the protocol gets 1002 and its endpoint's onClose
    /// gets 1002, while another open connection on the same server is unaffected.
    @Test func protocolErrorOverTCPLeavesOtherConnectionsWorking() throws {
        let port = try #require(WebsocketTCP.server?.port, "could not start a WSwiftServer on a free port")

        let bystanderToken = "bystander-\(UUID().uuidString)"
        let bystander = try #require(WebsocketTCP.upgrade(port: port, token: bystanderToken))
        let offenderToken = "unmasked-\(UUID().uuidString)"
        let offender = try #require(WebsocketTCP.upgrade(port: port, token: offenderToken))

        offender.send(WebsocketWireBuilder.frame(opcode: 0x1, payload: Array("bad".utf8), masked: false))
        #expect(offender.readFrame()?.closeCode == 1002)
        #expect(offender.readsEndOfStream())
        #expect(TCPEchoWebsocketEndpoint.closes.code(for: offenderToken) == .some(1002))

        bystander.send(WebsocketWireBuilder.text("still here"))
        #expect(bystander.readFrame()?.text == "Echo: still here")
        bystander.send(WebsocketWireBuilder.close(1001, "bye"))
        #expect(bystander.readFrame()?.closeCode == 1001)
        #expect(TCPEchoWebsocketEndpoint.closes.code(for: bystanderToken) == .some(1001))
    }
}
