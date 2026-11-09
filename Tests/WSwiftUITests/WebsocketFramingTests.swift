//
//  WebsocketFramingTests.swift
//  WSwiftUITests
//
//  RFC 6455 frame parsing, size limits and close handling for WebSocketConnection.
//  Each test plays a raw client on one end of a socketpair(AF_UNIX, SOCK_STREAM) and
//  reads back the bytes the connection writes, so close codes are checked on the wire.
//

import Foundation
import Testing
@testable import WSwiftUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Raw client helpers

/// A lock-protected value shared between a test and a background thread.
final class WebsocketTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Runs `body` on a new thread (not the Swift concurrency pool); the semaphore fires when it ends.
@discardableResult
func websocketTestThread(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        body()
        done.signal()
    }
    thread.start()
    return done
}

/// A frame as the server wrote it (servers never mask).
struct WebsocketServerFrame: Equatable {
    let fin: Bool
    let opcode: UInt8
    let masked: Bool
    let payload: [UInt8]

    var text: String { String(decoding: payload, as: UTF8.self) }

    var closeCode: UInt16? {
        guard opcode == 0x8, payload.count >= 2 else { return nil }
        return UInt16(payload[0]) << 8 | UInt16(payload[1])
    }
}

/// Builds client frames byte by byte, so tests can produce malformed ones too.
enum WebsocketWireBuilder {
    static let key: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]

    /// - Parameters:
    ///   - declaredLength: length written in the header, when it should differ from `payload.count`.
    ///   - rsv: reserved bits to set in the first byte (0x40, 0x20, 0x10).
    static func frame(opcode: UInt8,
                      payload: [UInt8] = [],
                      fin: Bool = true,
                      masked: Bool = true,
                      rsv: UInt8 = 0,
                      declaredLength: UInt64? = nil) -> [UInt8] {
        var out: [UInt8] = [(fin ? 0x80 : 0x00) | rsv | (opcode & 0x0F)]
        let maskBit: UInt8 = masked ? 0x80 : 0x00
        let length = declaredLength ?? UInt64(payload.count)
        if length <= 125 {
            out.append(maskBit | UInt8(length))
        } else if length <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(UInt8(length >> 8))
            out.append(UInt8(length & 0xFF))
        } else {
            out.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }
        if masked {
            out.append(contentsOf: key)
            for (i, byte) in payload.enumerated() {
                out.append(byte ^ key[i & 3])
            }
        } else {
            out.append(contentsOf: payload)
        }
        return out
    }

    static func text(_ s: String, fin: Bool = true) -> [UInt8] {
        frame(opcode: 0x1, payload: Array(s.utf8), fin: fin)
    }

    static func continuation(_ s: String, fin: Bool) -> [UInt8] {
        frame(opcode: 0x0, payload: Array(s.utf8), fin: fin)
    }

    static func close(_ code: UInt16, _ reason: String = "") -> [UInt8] {
        frame(opcode: 0x8, payload: [UInt8(code >> 8), UInt8(code & 0xFF)] + Array(reason.utf8))
    }
}

/// The client end of a socketpair; the other end is handed to `WebSocketConnection(fd:)`.
final class RawWebsocketPeer: @unchecked Sendable {
    /// Given to the connection under test, which owns (and closes) it.
    let serverFD: Int32
    /// The raw client end, owned by this object.
    let clientFD: Int32

    init(serverReadTimeout: Int = 5) throws {
        // Writes to a socket whose other end is gone must fail with EPIPE, not kill the test run.
        signal(SIGPIPE, SIG_IGN)
        var fds: [Int32] = [-1, -1]
#if canImport(Darwin)
        let streamType = SOCK_STREAM
#else
        let streamType = Int32(SOCK_STREAM.rawValue)
#endif
        guard socketpair(AF_UNIX, streamType, 0, &fds) == 0 else {
            throw Err.socket("socketpair failed: errno \(errno)")
        }
        serverFD = fds[0]
        clientFD = fds[1]
        // Timeouts make a missing reply fail the test instead of hanging the run.
        RawWebsocketPeer.setReadTimeout(clientFD, seconds: 5)
        RawWebsocketPeer.setReadTimeout(serverFD, seconds: serverReadTimeout)
#if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(serverFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
#endif
    }

    /// Wraps an already connected client socket (for example a TCP connection to a real
    /// server). There is no server end in this process to hand out, so `serverFD` is -1.
    init(connectedClientFD fd: Int32) {
        signal(SIGPIPE, SIG_IGN)
        serverFD = -1
        clientFD = fd
    }

    deinit {
        _ = close(clientFD)
    }

    private static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes all bytes; returns false if the server end went away first.
    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let w = bytes[offset...].withUnsafeBytes { p in
                write(clientFD, p.baseAddress, p.count)
            }
            if w < 0 {
                if errno == EINTR { continue }
                return false
            }
            if w == 0 { return false }
            offset += w
        }
        return true
    }

    /// Writes from a background thread, for payloads larger than the socket buffer.
    func sendInBackground(_ bytes: [UInt8]) -> DispatchSemaphore {
        return websocketTestThread { [self] in
            _ = self.send(bytes)
        }
    }

    /// Reads exactly `count` bytes, or nil on EOF / timeout.
    func readExactly(_ count: Int) -> [UInt8]? {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: max(1, min(count, 65536)))
        while out.count < count {
            let want = min(buf.count, count - out.count)
            let r = buf.withUnsafeMutableBytes { p in read(clientFD, p.baseAddress, want) }
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { return nil }
            out.append(contentsOf: buf[0..<r])
        }
        return out
    }

    /// Reads the next frame the server wrote, or nil on EOF / timeout.
    func readFrame() -> WebsocketServerFrame? {
        guard let head = readExactly(2) else { return nil }
        let masked = (head[1] & 0x80) != 0
        var length = UInt64(head[1] & 0x7F)
        if length == 126 {
            guard let ext = readExactly(2) else { return nil }
            length = UInt64(ext[0]) << 8 | UInt64(ext[1])
        } else if length == 127 {
            guard let ext = readExactly(8) else { return nil }
            length = ext.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        var key: [UInt8] = []
        if masked {
            guard let k = readExactly(4) else { return nil }
            key = k
        }
        guard length < 16 << 20, var payload = length == 0 ? [] : readExactly(Int(length)) else { return nil }
        if masked {
            for i in payload.indices { payload[i] ^= key[i & 3] }
        }
        return WebsocketServerFrame(fin: (head[0] & 0x80) != 0, opcode: head[0] & 0x0F, masked: masked, payload: payload)
    }

    /// True when the server end has shut down: the next read returns EOF.
    func readsEOF() -> Bool {
        var byte: UInt8 = 0
        while true {
            let r = read(clientFD, &byte, 1)
            if r < 0 && errno == EINTR { continue }
            return r == 0
        }
    }

    /// Reads whatever the server wrote until EOF (`sawEOF`) or the read timeout.
    func drain(limit: Int = 16 << 20) -> (bytes: [UInt8], sawEOF: Bool) {
        websocketDrain(clientFD, limit: limit)
    }

    /// True when the server end has shut down, after skipping anything it wrote first.
    func readsEOFAfterDraining() -> Bool {
        drain().sawEOF
    }

    /// Reads frames until EOF or timeout.
    func readAllFrames() -> [WebsocketServerFrame] {
        var frames: [WebsocketServerFrame] = []
        while let frame = readFrame() { frames.append(frame) }
        return frames
    }
}

/// Reads from `fd` until EOF (`sawEOF`), an error or timeout, or `limit` bytes.
func websocketDrain(_ fd: Int32, limit: Int = 16 << 20) -> (bytes: [UInt8], sawEOF: Bool) {
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65536)
    while out.count < limit {
        let r = buf.withUnsafeMutableBytes { p in read(fd, p.baseAddress, p.count) }
        if r < 0 && errno == EINTR { continue }
        if r == 0 { return (out, true) }
        if r < 0 { return (out, false) }
        out.append(contentsOf: buf[0..<r])
    }
    return (out, false)
}

/// Asserts that `body` throws `WebSocketProtocolError` with `code`.
func expectWebsocketFailure(_ code: UInt16,
                            sourceLocation: SourceLocation = #_sourceLocation,
                            _ body: () throws -> WebSocketFrame) {
    do {
        let frame = try body()
        Issue.record("expected close \(code), but read a frame with opcode \(frame.opcode)", sourceLocation: sourceLocation)
    } catch let error as WebSocketProtocolError {
        #expect(error.closeCode == code, sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected close \(code), got \(error)", sourceLocation: sourceLocation)
    }
}

/// Asserts the server wrote one Close frame with `code` and then shut the socket down.
func expectServerClosed(_ peer: RawWebsocketPeer, with code: UInt16,
                        sourceLocation: SourceLocation = #_sourceLocation) {
    let frame = peer.readFrame()
    #expect(frame?.opcode == 0x8, "expected a Close frame", sourceLocation: sourceLocation)
    #expect(frame?.fin == true, sourceLocation: sourceLocation)
    #expect(frame?.masked == false, sourceLocation: sourceLocation)
    #expect(frame?.closeCode == code, sourceLocation: sourceLocation)
    #expect(peer.readsEOF(), "expected the server to close the TCP stream", sourceLocation: sourceLocation)
}

let websocketEchoHandler: WebSocketConnection.FrameHandler = { frame in
    guard frame.opcode == .text else { return nil }
    return [WebSocketFrame(fin: true, opcode: .text, payload: Data("Echo: ".utf8) + frame.payload)]
}

/// Starts `conn.run` on its own thread. The box holds the error it threw, if any.
func startWebsocketRunLoop(_ conn: WebSocketConnection,
                           handler: @escaping WebSocketConnection.FrameHandler = websocketEchoHandler)
    -> (done: DispatchSemaphore, error: WebsocketTestBox<Error?>) {
    let error = WebsocketTestBox<Error?>(nil)
    let done = websocketTestThread {
        do {
            try conn.run(handle: handler)
        } catch let thrown {
            error.value = thrown
        }
    }
    return (done, error)
}

// MARK: - Frame length and size limits

@Suite("WebSocket frame limits")
struct WebsocketFrameLimitTests {

    @Test func defaultsAreOneMebibyte() {
        #expect(WebSocketConnection.defaultMaxFrameBytes == 1_048_576)
        #expect(WebSocketConnection.defaultMaxMessageBytes == 1_048_576)
        let conn = WebSocketConnection(fd: -1)
        #expect(conn.maxFrameBytes == 1_048_576)
        #expect(conn.maxMessageBytes == 1_048_576)
        conn.maxFrameBytes = 10
        conn.maxMessageBytes = 20
        #expect(conn.maxFrameBytes == 10)
        #expect(conn.maxMessageBytes == 20)
    }

    /// The original code passed this length to reserveCapacity and the process died (exit 133).
    @Test func hugeDeclaredLengthIsRefusedBeforeAnyAllocation() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        defer { conn.closeSocket() }
        // Header only: FIN+binary, 64-bit length 0x7FFF_FFFF_FFFF_FFFF, masking key, no payload.
        peer.send(WebsocketWireBuilder.frame(opcode: 0x2, declaredLength: 0x7FFF_FFFF_FFFF_FFFF))
        let started = Date()
        expectWebsocketFailure(1009) { try conn.readMessage() }
        #expect(Date().timeIntervalSince(started) < 2, "the frame must be refused from its header")
        expectServerClosed(peer, with: 1009)
        #expect(conn.isClosed)
    }

    @Test func lengthWithMostSignificantBitSetIsProtocolError() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        defer { conn.closeSocket() }
        peer.send(WebsocketWireBuilder.frame(opcode: 0x2, declaredLength: 0x8000_0000_0000_0000))
        expectWebsocketFailure(1002) { try conn.readMessage() }
        expectServerClosed(peer, with: 1002)
    }

    @Test func frameAtConfiguredLimitIsAccepted() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD, maxFrameBytes: 1024)
        defer { conn.closeSocket() }
        let payload = (0..<1024).map { UInt8($0 & 0xFF) }
        peer.send(WebsocketWireBuilder.frame(opcode: 0x2, payload: payload))
        let frame = try conn.readMessage()
        #expect(frame.opcode == .binary)
        #expect(frame.fin)
        #expect([UInt8](frame.payload) == payload)
        #expect(!conn.isClosed)
    }

    @Test func frameOneByteOverConfiguredLimitIsRefused() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        conn.maxFrameBytes = 1024
        defer { conn.closeSocket() }
        peer.send(WebsocketWireBuilder.frame(opcode: 0x2, payload: [UInt8](repeating: 7, count: 1025)))
        expectWebsocketFailure(1009) { try conn.readMessage() }
        expectServerClosed(peer, with: 1009)
    }

    @Test func frameAtDefaultLimitIsAccepted() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        defer { conn.closeSocket() }
        let payload = (0..<WebSocketConnection.defaultMaxFrameBytes).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let writer = peer.sendInBackground(WebsocketWireBuilder.frame(opcode: 0x2, payload: payload))
        let frame = try conn.readMessage()
        #expect(writer.wait(timeout: .now() + 5) == .success)
        #expect(frame.payload.count == payload.count)
        #expect([UInt8](frame.payload) == payload)
    }

    @Test func frameOneByteOverDefaultLimitIsRefused() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        defer { conn.closeSocket() }
        // Only the header is needed: the frame is refused before its payload is read.
        peer.send(WebsocketWireBuilder.frame(opcode: 0x2, declaredLength: UInt64(WebSocketConnection.defaultMaxFrameBytes + 1)))
        expectWebsocketFailure(1009) { try conn.readMessage() }
        expectServerClosed(peer, with: 1009)
    }

    @Test func singleFrameOverMessageLimitIsRefused() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD, maxFrameBytes: 4096, maxMessageBytes: 100)
        defer { conn.closeSocket() }
        peer.send(WebsocketWireBuilder.frame(opcode: 0x2, payload: [UInt8](repeating: 1, count: 101)))
        expectWebsocketFailure(1009) { try conn.readMessage() }
        expectServerClosed(peer, with: 1009)
    }

    @Test func fragmentedMessageOverMessageLimitIsRefused() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD, maxFrameBytes: 100, maxMessageBytes: 150)
        defer { conn.closeSocket() }
        let chunk = [UInt8](repeating: 0x41, count: 100)
        peer.send(WebsocketWireBuilder.frame(opcode: 0x2, payload: chunk, fin: false))
        peer.send(WebsocketWireBuilder.frame(opcode: 0x0, payload: chunk, fin: true))
        expectWebsocketFailure(1009) { try conn.readMessage() }
        expectServerClosed(peer, with: 1009)
    }

    @Test func endlessFragmentsHitTheDefaultMessageLimit() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        let chunk = [UInt8](repeating: 0x42, count: 600 * 1024)
        var bytes = WebsocketWireBuilder.frame(opcode: 0x2, payload: chunk, fin: false)
        bytes += WebsocketWireBuilder.frame(opcode: 0x0, payload: chunk, fin: false)
        let writer = peer.sendInBackground(bytes)
        expectWebsocketFailure(1009) { try conn.readMessage() }
        expectServerClosed(peer, with: 1009)
        // The second fragment's payload was never read. Once the owner releases the
        // descriptor, the client's blocked write fails instead of hanging.
        conn.closeSocket()
        #expect(conn.isDescriptorReleased)
        #expect(writer.wait(timeout: .now() + 5) == .success)
    }

    @Test func fragmentedMessageWithinLimitReassembles() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD, maxFrameBytes: 100, maxMessageBytes: 150)
        defer { conn.closeSocket() }
        // "wörld" has a two-byte character; split it across fragments to check that
        // UTF-8 is validated on the whole message, not per fragment.
        let tail = Array("wörld".utf8)
        peer.send(WebsocketWireBuilder.text("Hel", fin: false))
        peer.send(WebsocketWireBuilder.frame(opcode: 0x0, payload: Array("lo, ".utf8) + tail[0..<2], fin: false))
        peer.send(WebsocketWireBuilder.frame(opcode: 0x0, payload: Array(tail[2...]), fin: true))
        let frame = try conn.readMessage()
        #expect(frame.opcode == .text)
        #expect(frame.fin)
        #expect(String(decoding: frame.payload, as: UTF8.self) == "Hello, wörld")
        // The next message starts cleanly after the reassembled one.
        peer.send(WebsocketWireBuilder.text("next"))
        let next = try conn.readMessage()
        #expect(String(decoding: next.payload, as: UTF8.self) == "next")
    }

    @Test func fragmentsExactlyAtMessageLimitAreAccepted() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD, maxFrameBytes: 100, maxMessageBytes: 150)
        defer { conn.closeSocket() }
        peer.send(WebsocketWireBuilder.frame(opcode: 0x2, payload: [UInt8](repeating: 1, count: 100), fin: false))
        peer.send(WebsocketWireBuilder.frame(opcode: 0x0, payload: [UInt8](repeating: 2, count: 50), fin: true))
        let frame = try conn.readMessage()
        #expect(frame.payload.count == 150)
    }
}

// MARK: - RFC 6455 protocol errors

@Suite("WebSocket protocol errors")
struct WebsocketProtocolErrorTests {

    /// Each malformed input must get close 1002 (or 1007) on the wire, then EOF.
    private func expectRefused(_ bytes: [UInt8], code: UInt16 = 1002,
                               sourceLocation: SourceLocation = #_sourceLocation) throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        defer { conn.closeSocket() }
        peer.send(bytes)
        expectWebsocketFailure(code, sourceLocation: sourceLocation) { try conn.readMessage() }
        expectServerClosed(peer, with: code, sourceLocation: sourceLocation)
        #expect(conn.isClosed, sourceLocation: sourceLocation)
        #expect(throws: (any Error).self, sourceLocation: sourceLocation) { try conn.sendText("after failure") }
    }

    @Test func unmaskedClientFrameIsRefused() throws {
        try expectRefused(WebsocketWireBuilder.frame(opcode: 0x1, payload: Array("hello".utf8), masked: false))
    }

    @Test func reservedBitsAreRefused() throws {
        try expectRefused(WebsocketWireBuilder.frame(opcode: 0x1, payload: Array("hi".utf8), rsv: 0x40))
        try expectRefused(WebsocketWireBuilder.frame(opcode: 0x1, payload: Array("hi".utf8), rsv: 0x10))
    }

    @Test func unknownOpcodesAreRefused() throws {
        try expectRefused(WebsocketWireBuilder.frame(opcode: 0x3, payload: [1]))
        try expectRefused(WebsocketWireBuilder.frame(opcode: 0xB, payload: [1]))
    }

    @Test func oversizedControlFrameIsRefused() throws {
        try expectRefused(WebsocketWireBuilder.frame(opcode: 0x9, payload: [UInt8](repeating: 0x50, count: 126)))
    }

    @Test func controlFrameAtSizeLimitIsAccepted() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        defer { conn.closeSocket() }
        let payload = [UInt8](repeating: 0x50, count: 125)
        peer.send(WebsocketWireBuilder.frame(opcode: 0x9, payload: payload))
        let frame = try conn.readMessage()
        #expect(frame.opcode == .ping)
        #expect([UInt8](frame.payload) == payload)
    }

    @Test func fragmentedControlFrameIsRefused() throws {
        try expectRefused(WebsocketWireBuilder.frame(opcode: 0x9, payload: [1, 2], fin: false))
    }

    @Test func continuationWithoutMessageIsRefused() throws {
        try expectRefused(WebsocketWireBuilder.continuation("orphan", fin: true))
    }

    @Test func newDataFrameDuringFragmentedMessageIsRefused() throws {
        try expectRefused(WebsocketWireBuilder.text("part", fin: false) + WebsocketWireBuilder.text("other"))
    }

    @Test func invalidUTF8TextIsRefused() throws {
        // 0xC3 0x28 is an invalid two-byte sequence; 0xED 0xA0 0x80 encodes a UTF-16 surrogate.
        try expectRefused(WebsocketWireBuilder.frame(opcode: 0x1, payload: [0x61, 0xC3, 0x28]), code: 1007)
        try expectRefused(WebsocketWireBuilder.frame(opcode: 0x1, payload: [0xED, 0xA0, 0x80]), code: 1007)
    }

    @Test func invalidUTF8BinaryIsAccepted() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        defer { conn.closeSocket() }
        peer.send(WebsocketWireBuilder.frame(opcode: 0x2, payload: [0xC3, 0x28, 0xFF]))
        let frame = try conn.readMessage()
        #expect([UInt8](frame.payload) == [0xC3, 0x28, 0xFF])
    }

    @Test func malformedClosePayloadsAreRefused() throws {
        try expectRefused(WebsocketWireBuilder.frame(opcode: 0x8, payload: [0x03]))
        try expectRefused(WebsocketWireBuilder.close(1005))
        try expectRefused(WebsocketWireBuilder.close(999))
        try expectRefused(WebsocketWireBuilder.frame(opcode: 0x8, payload: [0x03, 0xE8, 0xC3, 0x28]), code: 1007)
    }
}

// MARK: - Run loop: echo, control frames between fragments, close handshake

@Suite("WebSocket run loop")
struct WebsocketRunLoopTests {

    @Test func maskedTextRoundTripsAndCloseHandshakeReportsCode() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        let loop = startWebsocketRunLoop(conn)

        peer.send(WebsocketWireBuilder.text("héllo 👋"))
        let echo = peer.readFrame()
        #expect(echo?.opcode == 0x1)
        #expect(echo?.fin == true)
        #expect(echo?.masked == false)
        #expect(echo?.text == "Echo: héllo 👋")

        peer.send(WebsocketWireBuilder.close(1001, "bye"))
        let closeEcho = peer.readFrame()
        #expect(closeEcho?.closeCode == 1001)

        #expect(loop.done.wait(timeout: .now() + 5) == .success)
        #expect(loop.error.value == nil)
        #expect(conn.receivedCloseCode == 1001)
        #expect(conn.receivedCloseReason == "bye")
        #expect(conn.isClosed)
        conn.closeSocket()
        #expect(peer.readsEOF())
    }

    @Test func pingBetweenFragmentsIsAnswered() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        let loop = startWebsocketRunLoop(conn)

        peer.send(WebsocketWireBuilder.text("ab", fin: false))
        peer.send(WebsocketWireBuilder.frame(opcode: 0x9, payload: Array("p!".utf8)))
        peer.send(WebsocketWireBuilder.frame(opcode: 0xA, payload: Array("unsolicited".utf8)))
        peer.send(WebsocketWireBuilder.continuation("cd", fin: true))

        let pong = peer.readFrame()
        #expect(pong?.opcode == 0xA)
        #expect(pong?.text == "p!")
        let echo = peer.readFrame()
        #expect(echo?.opcode == 0x1)
        #expect(echo?.text == "Echo: abcd")

        peer.send(WebsocketWireBuilder.close(1000))
        #expect(peer.readFrame()?.closeCode == 1000)
        #expect(loop.done.wait(timeout: .now() + 5) == .success)
        #expect(loop.error.value == nil)
        conn.closeSocket()
    }

    @Test func closeBetweenFragmentsEndsTheLoop() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        let loop = startWebsocketRunLoop(conn)

        peer.send(WebsocketWireBuilder.text("never finished", fin: false))
        peer.send(WebsocketWireBuilder.close(1000, "done"))
        let closeEcho = peer.readFrame()
        #expect(closeEcho?.closeCode == 1000)
        #expect(loop.done.wait(timeout: .now() + 5) == .success)
        #expect(loop.error.value == nil)
        #expect(conn.receivedCloseReason == "done")
        conn.closeSocket()
    }

    @Test func protocolErrorEndsTheLoopWithTheCloseCode() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        let loop = startWebsocketRunLoop(conn)

        peer.send(WebsocketWireBuilder.text("fine"))
        #expect(peer.readFrame()?.text == "Echo: fine")
        peer.send(WebsocketWireBuilder.frame(opcode: 0x1, payload: Array("bad".utf8), masked: false))
        expectServerClosed(peer, with: 1002)
        #expect(loop.done.wait(timeout: .now() + 5) == .success)
        #expect((loop.error.value as? WebSocketProtocolError)?.closeCode == 1002)
        conn.closeSocket()
    }
}

// MARK: - Close and descriptor lifecycle

@Suite("WebSocket close lifecycle")
struct WebsocketCloseLifecycleTests {

    /// Counts close() calls directly. Probing whether a new descriptor lands on the freed
    /// number is not reliable while other tests open descriptors in parallel.
    @Test func closeSocketTwiceClosesTheDescriptorOnce() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        #expect(conn.descriptorReleaseCount == 0)
        conn.closeSocket()
        #expect(conn.isClosed)
        #expect(conn.isDescriptorReleased)
        #expect(conn.descriptorReleaseCount == 1)
        // The descriptor really was closed: the client end sees EOF.
        #expect(peer.readsEOF())

        conn.closeSocket()
        conn.closeSocket()
        #expect(conn.descriptorReleaseCount == 1, "a later closeSocket() must not close the number again")
        #expect(throws: (any Error).self) { try conn.sendText("after closeSocket") }
        #expect(throws: (any Error).self) { try conn.readMessage() }
        #expect(conn.descriptorReleaseCount == 1)
    }

    @Test func closeSocketWakesABlockedReaderAndReleasesOnce() throws {
        let peer = try RawWebsocketPeer(serverReadTimeout: 20)
        let conn = WebSocketConnection(fd: peer.serverFD)
        let loop = startWebsocketRunLoop(conn)
        Thread.sleep(forTimeInterval: 0.2) // let the reader block in read()

        conn.closeSocket()
        conn.closeSocket()
        #expect(loop.done.wait(timeout: .now() + 3) == .success, "closeSocket() must wake the blocked reader")
        #expect(loop.error.value != nil)
        #expect(conn.isDescriptorReleased)
        #expect(conn.descriptorReleaseCount == 1)
        #expect(peer.readsEOF())
        conn.closeSocket()
        #expect(conn.descriptorReleaseCount == 1)
    }

    /// Readers, writers, close() and closeSocket() racing on one connection: the descriptor
    /// is closed exactly once, and only after every read and write has finished with it.
    @Test func racingClosersReleaseTheDescriptorOnce() throws {
        for round in 0..<50 {
            let peer = try RawWebsocketPeer(serverReadTimeout: 20)
            let conn = WebSocketConnection(fd: peer.serverFD)
            let loop = startWebsocketRunLoop(conn)
            let group = DispatchGroup()
            for worker in 0..<6 {
                group.enter()
                Thread {
                    switch (worker + round) % 3 {
                        case 0:
                            for _ in 0..<10 { _ = conn.safeSendText("tick") }
                        case 1:
                            try? conn.close(code: 1000, reason: "bye")
                        default:
                            break
                    }
                    conn.closeSocket()
                    group.leave()
                }.start()
            }
            peer.send(WebsocketWireBuilder.text("hello"))
            #expect(group.wait(timeout: .now() + 5) == .success)
            #expect(loop.done.wait(timeout: .now() + 5) == .success, "the reader must be woken")
            #expect(conn.isDescriptorReleased)
            #expect(conn.descriptorReleaseCount == 1)
            #expect(peer.readsEOFAfterDraining())
        }
    }

    @Test func closeIsIdempotent() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        try conn.close(code: 1000, reason: "done")
        try conn.close(code: 1000, reason: "done")
        #expect(conn.isClosed)
        #expect(throws: (any Error).self) { try conn.sendText("after close") }
        conn.closeSocket()
        conn.closeSocket()

        let frames = peer.readAllFrames()
        #expect(frames.count == 1)
        #expect(frames.first?.closeCode == 1000)
        #expect(frames.first.map { Array($0.payload.dropFirst(2)) } == Array("done".utf8))
    }

    @Test func closeReasonIsTruncatedAtACharacterBoundary() throws {
        let peer = try RawWebsocketPeer()
        let conn = WebSocketConnection(fd: peer.serverFD)
        // 122 ASCII bytes then a 2-byte character: 124 bytes, one more than fits.
        try conn.close(code: 1000, reason: String(repeating: "a", count: 122) + "é")
        conn.closeSocket()
        let frame = peer.readFrame()
        #expect(frame?.closeCode == 1000)
        #expect(frame?.payload.count == 124)
        #expect(frame.map { WebSocketWire.isValidUTF8($0.payload.dropFirst(2)) } == true)
    }
}

// MARK: - CoreWebsocketEndpoint wiring

/// Endpoint with small limits; records how the connection closed.
final class LimitedWebsocketEndpoint: CoreWebsocketEndpoint, @unchecked Sendable {
    override var tickInterval: TimeInterval { get { 0 } set {} }
    override var maxFrameBytes: Int { get { 64 } set {} }
    override var maxMessageBytes: Int { get { 96 } set {} }

    let closed = DispatchSemaphore(value: 0)
    let closeInfo = WebsocketTestBox<(code: UInt16?, reason: String?)?>(nil)

    override func onClose(connection: WebSocketConnection, code: UInt16?, reason: String?) {
        closeInfo.value = (code, reason)
        closed.signal()
    }
}

@Suite("CoreWebsocketEndpoint limits")
struct WebsocketEndpointTests {

    private func start(_ endpoint: CoreWebsocketEndpoint, peer: RawWebsocketPeer) {
        endpoint.startWebSocket(WebSocketUpgrade(key: "dGhlIHNhbXBsZSBub25jZQ==", protocols: [],
                                                 version: 13, extensions: nil, socketFD: peer.serverFD))
    }

    @Test func defaultsMatchTheConnectionDefaults() {
        let endpoint = CoreWebsocketEndpoint()
        #expect(endpoint.maxFrameBytes == WebSocketConnection.defaultMaxFrameBytes)
        #expect(endpoint.maxMessageBytes == WebSocketConnection.defaultMaxMessageBytes)
    }

    @Test func overriddenFrameLimitIsEnforced() throws {
        let peer = try RawWebsocketPeer()
        let endpoint = LimitedWebsocketEndpoint()
        start(endpoint, peer: peer)

        peer.send(WebsocketWireBuilder.text("hi"))
        #expect(peer.readFrame()?.text == "Echo: hi")
        peer.send(WebsocketWireBuilder.frame(opcode: 0x2, payload: [UInt8](repeating: 0, count: 65)))
        expectServerClosed(peer, with: 1009)
        #expect(endpoint.closed.wait(timeout: .now() + 5) == .success)
        #expect(endpoint.closeInfo.value?.code == 1009)
    }

    @Test func overriddenMessageLimitIsEnforced() throws {
        let peer = try RawWebsocketPeer()
        let endpoint = LimitedWebsocketEndpoint()
        start(endpoint, peer: peer)

        peer.send(WebsocketWireBuilder.frame(opcode: 0x2, payload: [UInt8](repeating: 0, count: 64), fin: false))
        peer.send(WebsocketWireBuilder.frame(opcode: 0x0, payload: [UInt8](repeating: 0, count: 64), fin: true))
        expectServerClosed(peer, with: 1009)
        #expect(endpoint.closed.wait(timeout: .now() + 5) == .success)
        #expect(endpoint.closeInfo.value?.code == 1009)
    }

    @Test func peerCloseCodeAndReasonReachOnClose() throws {
        let peer = try RawWebsocketPeer()
        let endpoint = LimitedWebsocketEndpoint()
        start(endpoint, peer: peer)

        peer.send(WebsocketWireBuilder.close(1001, "going away"))
        let echo = peer.readFrame()
        #expect(echo?.closeCode == 1001)
        #expect(peer.readsEOF())
        #expect(endpoint.closed.wait(timeout: .now() + 5) == .success)
        #expect(endpoint.closeInfo.value?.code == 1001)
        #expect(endpoint.closeInfo.value?.reason == "going away")
    }
}
