//
//  webserver2.swift
//  WSwiftUI
//
//  Created by Adrian Herridge on 28/09/2025.
//
// MicroHTTP.swift
// Swift 6, macOS & Linux (no external deps)

import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

// MARK: - Errors

public enum Err: Error, CustomStringConvertible {
    case socket(String)
    case bind(String)
    case listen(String)
    case accept(String)
    case io(String)
    case parse(String)
    case closed
    case rejected                      // gatekeeper rejected
    case timeout
    case tooLarge                      // body exceeded allowed limits
    case unsupported(String)
    
    public var description: String {
        switch self {
            case .socket(let s): return "Socket error: \(s)"
            case .bind(let s): return "Bind error: \(s)"
            case .listen(let s): return "Listen error: \(s)"
            case .accept(let s): return "Accept error: \(s)"
            case .io(let s): return "IO error: \(s)"
            case .parse(let s): return "Parse error: \(s)"
            case .closed: return "Connection closed"
            case .rejected: return "Rejected by gatekeeper"
            case .timeout: return "Timeout"
            case .tooLarge: return "Body too large"
            case .unsupported(let s): return "Unsupported: \(s)"
        }
    }
}

// MARK: - Request/Response models

@frozen
public struct HttpMethod: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: String
    
    @inlinable
    public init(_ v: String) {
        // Locale-invariant uppercasing to keep it deterministic
        self.rawValue = v.uppercased(with: Locale(identifier: "en_US_POSIX"))
    }
    
    @inlinable
    public init(rawValue: String) {
        self.init(rawValue)
    }
    
    // Static singletons (now concurrency-safe because the type is Sendable)
    public static let GET:    Self = .init("GET")
    public static let POST:   Self = .init("POST")
    public static let PUT:    Self = .init("PUT")
    public static let DELETE: Self = .init("DELETE")
    public static let PATCH:  Self = .init("PATCH")
    public static let HEAD:   Self = .init("HEAD")
    public static let OPTIONS: Self = .init("OPTIONS")
}

@frozen
public struct HttpStatus: Equatable, Hashable, Sendable {
    public let code: Int
    public let reason: String
    
    @inlinable
    public init(_ code: Int, _ reason: String) {
        self.code = code
        self.reason = reason
    }
    
    // Common statuses (concurrency-safe because HttpStatus is Sendable)
    public static let ok                 = HttpStatus(200, "OK")
    public static let created            = HttpStatus(201, "Created")
    public static let accepted           = HttpStatus(202, "Accepted")
    public static let noContent          = HttpStatus(204, "No Content")
    public static let redirect           = HttpStatus(302, "Redirect")
    public static let notModified        = HttpStatus(304, "Not Modified")
    public static let badRequest         = HttpStatus(400, "Bad Request")
    public static let unauthorized       = HttpStatus(401, "Unauthorized")
    public static let forbidden          = HttpStatus(403, "Forbidden")
    public static let notFound           = HttpStatus(404, "Not Found")
    public static let payloadTooLarge    = HttpStatus(413, "Payload Too Large")
    public static let unsupportedType    = HttpStatus(415, "Unsupported Media Type")
    public static let expectationFailed  = HttpStatus(417, "Expectation Failed")
    public static let internalError      = HttpStatus(500, "Internal Server Error")
    public static let serviceUnavailable = HttpStatus(503, "Service Unavailable")
    public static let switchingProtocols = HttpStatus(101, "Switching Protocols")
}


public enum HttpBody {
    case none
    case inMemory(Data)
}

public enum RequestKind: Sendable {
    case http
    case websocket(WebSocketUpgrade)
}

public struct WebSocketUpgrade: Sendable {
    public let key: String
    public let protocols: [String]
    public let version: Int?
    public let extensions: String?
    public let socketFD: Int32
}

public struct HttpRequestHead {
    public let method: HttpMethod
    public let uri: String
    public var path: String {
        get {
            // this could be "/auth-password?email=adrian@uncia.co.uk", return only the path part
            let u = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true).first ?? Substring("")
            return "\(u)"
        }
    }
    public let version: String
    public let headers: [(String, String)]
    public var headerMap: [String:String] {
        var m: [String:String] = [:]
        for (k,v) in headers { m[k.lowercased()] = v }
        return m
    }
    public var contentLength: Int? {
        if let s = headerMap["content-length"], let n = Int(s) { return n }
        return nil
    }
    public var isChunked: Bool {
        headerMap["transfer-encoding"]?.lowercased().contains("chunked") == true
    }
    public var expectContinue: Bool {
        headerMap["expect"]?.lowercased().contains("100-continue") == true
    }
    public var pathComponents: [String] {
        let u = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true).first ?? Substring("")
        return u.split(separator: "/", omittingEmptySubsequences: true).map { String($0) }
    }
    public var queryParams: [String:String] {
        get {
            var out: [String:String] = [:]
            let parts = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return out }
            let query = parts[1]
            for kv in query.split(separator: "&") {
                let pair = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
                if pair.count == 2 {
                    let key = String(pair[0]).removingPercentEncoding ?? String(pair[0])
                    let val = String(pair[1]).removingPercentEncoding ?? String(pair[1])
                    out[key] = val
                } else if pair.count == 1 {
                    let key = String(pair[0]).removingPercentEncoding ?? String(pair[0])
                    out[key] = ""
                }
            }
            return out
        }
    }
}

public final class HttpRequest {
    public let head: HttpRequestHead
    public let body: HttpBody
    public let kind: RequestKind
    public init(head: HttpRequestHead, body: HttpBody, kind: RequestKind) {
        self.head = head
        self.body = body
        self.kind = kind
    }
    public convenience init(head: HttpRequestHead, body: HttpBody) {
        self.init(head: head, body: body, kind: .http)
    }
    public var cookies: [String:String] {
        guard let raw = head.headerMap["cookie"] else { return [:] }
        var out: [String:String] = [:]
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }
    
    /// Decode JSON from the request body
    public func decodeBody<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data: Data
        switch body {
        case .none:
            throw Err.parse("No body to decode")
        case .inMemory(let d):
            data = d
        }
        // JSONDecoder recurses once per nesting level; refuse hostile depth instead of overflowing the stack
        guard JSONBodyLimits.nestingExceedsLimit(data) == false else {
            throw Err.parse("JSON nested too deeply")
        }
        return try decoder.decode(type, from: data)
    }
}

public final class HttpResponse {
    
    public private(set) var status = HttpStatus.ok
    public private(set) var headers: [(String, String)] = []
    public private(set) var bodyBytes: Data = Data()
    public private(set) var bodyFileUrl: URL?
    public private(set) var bodyFileHandleRange: Range<Int>?
    /// Runs after a 101 response has been completely written. From then on the socket
    /// belongs to whatever the hook starts; the HTTP server never touches it again.
    /// It never runs when the 101 could not be written (the server then closes the socket).
    ///
    /// Start a WebSocket loop (`CoreWebsocketEndpoint.startWebSocket(_:)` or
    /// `WebSocketConnection(fd:)`) from this hook, never directly from the route handler:
    /// before the 101 is on the wire the descriptor still belongs to the HTTP server.
    /// The hook runs synchronously on the HTTP worker thread, so dispatch long-running work
    /// to another queue, as `WSwiftServer.registerWebSocket` does.
    public var onUpgraded: (() -> Void)?
    
    public init() {}

    /// A field-for-field copy, made without going back through the validating builders (everything here
    /// was validated when it was first set). Kept next to the stored properties so a new one can't be missed.
    internal func copy() -> HttpResponse {
        let copy = HttpResponse()
        copy.status = status
        copy.headers = headers
        copy.bodyBytes = bodyBytes
        copy.bodyFileUrl = bodyFileUrl
        copy.bodyFileHandleRange = bodyFileHandleRange
        copy.onUpgraded = onUpgraded
        return copy
    }
    
    // Fluent
    @discardableResult public func status(_ s: HttpStatus) -> Self { self.status = s; return self }
    /// Adds a header. A header whose name is not an RFC 7230 token, or whose value contains
    /// CR, LF or NUL, would let the value split the response, so it is dropped (and logged).
    @discardableResult public func header(_ k: String, _ v: String) -> Self {
        guard HTTPHeaderValidation.isToken(k) else {
            HTTPHeaderValidation.logDropped("response header", name: k, reason: "name is not an RFC 7230 token")
            return self
        }
        guard HTTPHeaderValidation.isSafeFieldValue(v) else {
            HTTPHeaderValidation.logDropped("response header", name: k, reason: "value contains CR, LF or NUL")
            return self
        }
        headers.append((k, v))
        return self
    }
    /// Adds each header with the same rules as `header(_:_:)`.
    @discardableResult public func headers(_ items: [(String,String)]) -> Self {
        for (k, v) in items { header(k, v) }
        return self
    }
    
    public enum ImageType {
        case jpg
        case png
        case svg
        case custom(String)
        var contentType: String {
            switch self {
                case .jpg:
                    return "image/jpeg"
                case .png:
                    return "image/png"
                case .svg:
                    return "image/svg+xml"
                case .custom(let s):
                    return s
            }
        }
    }
    
    public enum ContentStyle { case json, html, text, bytes, octetStream, image(ImageType) }
    @discardableResult public func content(_ style: ContentStyle) -> Self {
        switch style {
            case .json:        return header("Content-Type", "application/json; charset=utf-8")
            case .html:        return header("Content-Type", "text/html; charset=utf-8")
            case .text:        return header("Content-Type", "text/plain; charset=utf-8")
            case .bytes:       return self // caller should set their own type if desired
            case .octetStream: return header("Content-Type", "application/octet-stream")
            case .image(let type):
                return header("Content-Type", type.contentType)
        }
    }
    
    // Auto body -> sets Content-Type if not present and defaults status to .ok
    @discardableResult public func body(_ s: String) -> Self {
        if headers.first(where: { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }) == nil {
            _ = content(.text)
        }
        self.bodyBytes = Data(s.utf8)
        return self
    }
    
    @discardableResult public func body<T: Encodable>(json object: T, encoder: JSONEncoder = JSONEncoder()) -> Self {
        do {
            let data = try encoder.encode(object)
            if headers.first(where: { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }) == nil {
                _ = content(.json)
            }
            self.bodyBytes = data
        } catch {
            self.status = .internalError
            _ = content(.text)
            self.bodyBytes = Data("JSON encode error: \(error.localizedDescription)".utf8)
        }
        return self
    }
    
    @discardableResult public func body(_ data: Data) -> Self {
        if headers.first(where: { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }) == nil {
            _ = content(.octetStream)
        }
        self.status = .ok
        self.bodyBytes = data
        return self
    }
    
    /// Streams `file` as the body without reading it into memory.
    /// With `from` and `to` (byte offsets, `to` exclusive) only that range is sent, as
    /// 206 Partial Content with a Content-Range header; a range that does not overlap the
    /// file is answered 416 when the response is written. Content-Length is always set
    /// from the file's size (or the range length) when the response is written, and a
    /// missing or unreadable file is answered 404.
    @discardableResult public func body(_ file: URL, from: Int? = nil, to: Int? = nil) -> Self {
        // we will pass the file URL directly for super efficient streaming of binary data so it doesn't have to be read into memory before transmission
        self.bodyFileUrl = file
        if let from, let to {
            // `from..<to` traps when to < from; store an empty range instead, which is answered 416
            self.bodyFileHandleRange = to >= from ? from..<to : from..<from
        }
        return self
    }
    
    // Cookies
    /// Adds a Set-Cookie header. The cookie is not emitted (and the drop is logged) unless
    /// `name` is an RFC 7230 token, `value` is made of RFC 6265 cookie-octets (optionally
    /// wrapped in double quotes; empty is allowed), and `path`, `domain` and `sameSite`
    /// contain no ';' and no control characters.
    @discardableResult public func setCookie(
        name: String, value: String,
        path: String = "/", domain: String? = nil,
        maxAge: Int? = nil, expires: Date? = nil,
        httpOnly: Bool = true, secure: Bool = false, sameSite: String? = "Lax"
    ) -> Self {
        guard HTTPHeaderValidation.isToken(name) else {
            HTTPHeaderValidation.logDropped("cookie", name: name, reason: "name is not an RFC 7230 token")
            return self
        }
        guard HTTPHeaderValidation.isCookieValue(value) else {
            HTTPHeaderValidation.logDropped("cookie", name: name, reason: "value is not made of RFC 6265 cookie-octets")
            return self
        }
        guard HTTPHeaderValidation.isSafeCookieAttribute(path),
              domain.map(HTTPHeaderValidation.isSafeCookieAttribute) ?? true,
              sameSite.map(HTTPHeaderValidation.isSafeCookieAttribute) ?? true else {
            HTTPHeaderValidation.logDropped("cookie", name: name, reason: "Path, Domain or SameSite contains ';', a control character or non-ASCII text")
            return self
        }
        var parts = ["\(name)=\(value)"]
        parts.append("Path=\(path)")
        if let d = domain { parts.append("Domain=\(d)") }
        if let a = maxAge { parts.append("Max-Age=\(a)") }
        if let e = expires {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            fmt.dateFormat = "E, dd MMM yyyy HH:mm:ss 'GMT'"
            parts.append("Expires=\(fmt.string(from: e))")
        }
        if httpOnly { parts.append("HttpOnly") }
        if secure { parts.append("Secure") }
        if let ss = sameSite { parts.append("SameSite=\(ss)") }
        return header("Set-Cookie", parts.joined(separator: "; "))
    }
    
    @discardableResult public func clearCookie(name: String, path: String = "/", domain: String? = nil) -> Self {
        let past = Date(timeIntervalSince1970: 0)
        return setCookie(name: name, value: "", path: path, domain: domain, maxAge: 0, expires: past, httpOnly: true, secure: false, sameSite: "Lax")
    }
    
    /// Sets a 301/302 status and a Location header. A `url` containing CR, LF or NUL is
    /// not written: the Location header is dropped (and logged), as for `header(_:_:)`.
    @discardableResult public func redirect(to url: String, permanent: Bool = false) -> Self {
        self.status = permanent ? HttpStatus(301, "Moved Permanently") : HttpStatus(302, "Found")
        _ = header("Location", url)
        return self
    }
    
    @discardableResult public func acceptWebSocket(key: String, protocol proto: String? = nil) -> Self {
        self.status = .switchingProtocols
        _ = header("Upgrade", "websocket")
        _ = header("Connection", "Upgrade")
        let accept = wsAcceptKey(for: key)
        _ = header("Sec-WebSocket-Accept", accept)
        if let proto, !proto.isEmpty { _ = header("Sec-WebSocket-Protocol", proto) }
        return self
    }
    
}

// MARK: - Gatekeeper decisions

extension HttpRequestHead: Sendable {}
extension HttpMethod: Sendable {}
extension HttpStatus: Sendable {}

extension HttpRequest: @unchecked Sendable {}
extension HttpResponse: @unchecked Sendable {}

public enum GateDecision: Sendable {
    case accept
    case reject(HttpResponse)
}

public typealias HeadCallback       = @Sendable (HttpRequestHead) -> GateDecision
public typealias BeforeBodyCallback = @Sendable (HttpRequestHead) -> GateDecision
public typealias Handler            = @Sendable (HttpRequest) -> HttpResponse


// MARK: - Thread Pool (low-overhead on top of GCD)

final class ThreadPool {
    private let queues: [DispatchQueue]
    private var idx = 0
    private let lock = NSLock()
    
    init(workers: Int) {
        let n = max(1, workers)
        var qs: [DispatchQueue] = []
        qs.reserveCapacity(n)
        for i in 0..<n {
            qs.append(DispatchQueue(label: "microhttp.worker.\(i)", qos: .userInitiated, attributes: .concurrent))
        }
        self.queues = qs
    }
    
    // NOTE: Mark the closure as @Sendable
    func submit(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        let q = queues[idx]
        idx = (idx + 1) % queues.count
        lock.unlock()
        q.async(execute: work)
    }
}

// MARK: - Utilities

@inline(__always)
private func errnoString(_ where_: String) -> String {
    let e = errno
    return "\(where_): \(String(cString: strerror(e))) [errno \(e)]"
}

private extension Data {
    mutating func appendBytes(_ buffer: UnsafeRawBufferPointer) {
        if let base = buffer.baseAddress {
            self.append(base.assumingMemoryBound(to: UInt8.self), count: buffer.count)
        }
    }
}

// MARK: - WebSocket helpers

fileprivate func wsAcceptKey(for clientKey: String) -> String {
    let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    let combined = Data((clientKey + magic).utf8)
    let digest = SHA1.hash(data: combined)
    return digest.base64EncodedString()
}

// Minimal SHA1 implementation in pure Swift (no external deps)
fileprivate struct SHA1 {
    static func hash(data: Data) -> Data {
        var message = [UInt8](data)
        let ml = UInt64(message.count * 8)
        // append the bit '1' to the message
        message.append(0x80)
        // append 0 <= k < 512 bits '0', so that the resulting message length (in bits)
        // is congruent to 448 (mod 512)
        while (message.count % 64) != 56 { message.append(0) }
        // append length as 64-bit big-endian
        var mlBE = ml.bigEndian
        withUnsafeBytes(of: &mlBE) { message.append(contentsOf: $0) }
        
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0
        
        var w = [UInt32](repeating: 0, count: 80)
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            // Break chunk into sixteen 32-bit big-endian words w[0..15]
            for i in 0..<16 {
                let j = chunkStart + i*4
                let b0 = UInt32(message[j]) << 24
                let b1 = UInt32(message[j+1]) << 16
                let b2 = UInt32(message[j+2]) << 8
                let b3 = UInt32(message[j+3])
                w[i] = b0 | b1 | b2 | b3
            }
            // Extend to 80 words
            for i in 16..<80 {
                let v = w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16]
                w[i] = (v << 1) | (v >> 31)
            }
            
            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4
            
            for i in 0..<80 {
                var f: UInt32 = 0
                var k: UInt32 = 0
                switch i {
                    case 0...19:
                        f = (b & c) | ((~b) & d)
                        k = 0x5A827999
                    case 20...39:
                        f = b ^ c ^ d
                        k = 0x6ED9EBA1
                    case 40...59:
                        f = (b & c) | (b & d) | (c & d)
                        k = 0x8F1BBCDC
                    default:
                        f = b ^ c ^ d
                        k = 0xCA62C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = (b << 30) | (b >> 2)
                b = a
                a = temp
            }
            
            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }
        
        var digest = Data()
        for h in [h0, h1, h2, h3, h4] {
            var be = h.bigEndian
            withUnsafeBytes(of: &be) { digest.appendBytes($0) }
        }
        return digest
    }
}

// MARK: - WebSocket framing & connection

public enum WebSocketOpcode: UInt8, Sendable {
    case continuation = 0x0
    case text        = 0x1
    case binary      = 0x2
    // 0x3-0x7 reserved
    case close       = 0x8
    case ping        = 0x9
    case pong        = 0xA
    // 0xB-0xF reserved

    /// Control frames (close, ping, pong) have the high bit of the opcode set.
    internal var isControl: Bool { (rawValue & 0x08) != 0 }
}

public struct WebSocketFrame: Sendable {
    public var fin: Bool
    public var opcode: WebSocketOpcode
    public var payload: Data
    public var maskingKey: UInt32? // network-order key if present

    public init(fin: Bool, opcode: WebSocketOpcode, payload: Data = Data(), maskingKey: UInt32? = nil) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
        self.maskingKey = maskingKey
    }
}

/// A server-side WebSocket connection on an already-upgraded socket.
///
/// Reading follows RFC 6455 section 5 and enforces size limits before reading or
/// allocating a payload. When the peer breaks the protocol, `readMessage()` sends a
/// Close frame (1002 protocol error, 1007 invalid UTF-8, or 1009 too big), shuts the
/// socket down, and throws `WebSocketProtocolError`.
///
/// Threading: `readMessage()` / `run(handle:)` must be driven by one reader thread.
/// The `send*`, `close(code:reason:)` and `closeSocket()` methods may be called from any
/// thread. `closeSocket()` is idempotent and never closes the descriptor while a read or
/// write of this connection is still using it, so this connection closes the descriptor
/// exactly once and never reads or writes it after closing it.
///
/// Ownership: those guarantees hold only while this connection is the descriptor's sole
/// owner. Create it only after the HTTP 101 response has been completely written, and from
/// then on release the descriptor only through `closeSocket()`. If other code still writes
/// to or closes the same descriptor number (for example an HTTP thread that has not yet
/// written the 101), the number can be closed early and handed to another client by
/// `accept()`, and the two connections then read and write each other's bytes.
public final class WebSocketConnection: @unchecked Sendable {

    /// Default largest payload accepted in one frame (1 MiB).
    public static let defaultMaxFrameBytes = 1 << 20
    /// Default largest message accepted after reassembling fragments (1 MiB).
    public static let defaultMaxMessageBytes = 1 << 20
    /// Payloads are read from the socket in slices of at most this many bytes.
    internal static let readSliceBytes = 64 * 1024

    internal var endpoint: CoreWebsocketEndpoint?
    public let fd: Int32

    /// Serializes whole frames on the wire.
    private let writeLock = NSLock()
    /// Guards the state below. Never held across a blocking system call.
    private let stateLock = NSLock()
    private var closedForWriting = false
    private var closeFrameSent = false
    private var fdCloseRequested = false
    private var fdReleased = false
    private var releaseCount = 0
    private var activeIO = 0
    private var frameLimit: Int
    private var messageLimit: Int
    private var peerCloseCode: UInt16?
    private var peerCloseReason: String?

    // Fragmented message in progress. Touched only by the reader thread.
    private var partialOpcode: WebSocketOpcode?
    private var partialPayload = Data()

    /// - Parameters:
    ///   - maxFrameBytes: largest data-frame payload accepted; larger frames are refused with close 1009.
    ///   - maxMessageBytes: largest message accepted after reassembling fragments; larger ones get close 1009.
    public init(fd: Int32,
                maxFrameBytes: Int = WebSocketConnection.defaultMaxFrameBytes,
                maxMessageBytes: Int = WebSocketConnection.defaultMaxMessageBytes) {
        self.fd = fd
        self.frameLimit = max(0, maxFrameBytes)
        self.messageLimit = max(0, maxMessageBytes)
    }

    deinit {
        // no implicit close; caller owns lifecycle
    }

    @inline(__always)
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    /// True once the connection will send nothing more: a Close frame went out, the
    /// peer went away, a protocol error occurred, or `closeSocket()` was called.
    public var isClosed: Bool { locked { closedForWriting } }

    /// Largest data-frame payload accepted, in bytes. Settable per connection, from any thread.
    public var maxFrameBytes: Int {
        get { locked { frameLimit } }
        set { locked { frameLimit = max(0, newValue) } }
    }

    /// Largest message accepted after reassembling fragments, in bytes. Settable per connection.
    public var maxMessageBytes: Int {
        get { locked { messageLimit } }
        set { locked { messageLimit = max(0, newValue) } }
    }

    /// The status code from the peer's Close frame, once one has been received.
    public var receivedCloseCode: UInt16? { locked { peerCloseCode } }

    /// The reason from the peer's Close frame, if it sent a non-empty one.
    public var receivedCloseReason: String? { locked { peerCloseReason } }

    /// True once the descriptor itself has been closed (for tests).
    internal var isDescriptorReleased: Bool { locked { fdReleased } }

    /// How many times this connection has called close() on its descriptor; never more
    /// than 1 (for tests, which cannot rely on the freed number being reused).
    internal var descriptorReleaseCount: Int { locked { releaseCount } }

    /// Mark this connection as closed (prevents further writes)
    internal func markClosed() {
        locked { closedForWriting = true }
    }

    /// Closes the socket. Safe to call more than once and from any thread.
    ///
    /// The first call stops all writes and closes the descriptor straight away when no
    /// read or write is in progress. Otherwise it shuts the socket down, which wakes the
    /// blocked reader or writer, and the last of them closes the descriptor on its way
    /// out. Later calls do nothing, so the descriptor number is closed exactly once.
    public func closeSocket() {
        stateLock.lock()
        closedForWriting = true
        if fdCloseRequested {
            stateLock.unlock()
            return
        }
        fdCloseRequested = true
        let closeNow = activeIO == 0
        if closeNow {
            fdReleased = true
        } else {
            // The descriptor is still open (a reader/writer holds it), so this cannot
            // touch a reused number. shutdown() does not block.
            _ = shutdown(fd, Int32(SHUT_RDWR))
        }
        stateLock.unlock()
        if closeNow { releaseDescriptor() }
    }

    /// Closes the descriptor. Callers set `fdReleased` under the state lock first, so only
    /// one caller ever gets here.
    private func releaseDescriptor() {
        locked { releaseCount += 1 }
#if os(Linux)
        _ = Glibc.close(fd)
#else
        _ = Darwin.close(fd)
#endif
    }

    /// Stops writes and shuts the socket down (TCP FIN) without releasing the descriptor,
    /// which stays with the owner until `closeSocket()`.
    private func shutdownSocket() {
        locked {
            closedForWriting = true
            if !fdReleased {
                _ = shutdown(fd, Int32(SHUT_RDWR))
            }
        }
    }

    // MARK: - I/O primitives

    /// Registers a read or write on the descriptor; fails once `closeSocket()` was called.
    private func beginIO() -> Bool {
        return locked {
            if fdCloseRequested { return false }
            activeIO += 1
            return true
        }
    }

    private func endIO() {
        let closeNow: Bool = locked {
            activeIO -= 1
            if fdCloseRequested && activeIO == 0 && !fdReleased {
                fdReleased = true
                return true
            }
            return false
        }
        if closeNow { releaseDescriptor() }
    }

    /// Reads exactly `count` bytes. Callers check `count` against the limits first; the
    /// buffer still grows only as bytes actually arrive, at most 64 KiB per read.
    private func readExact(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        guard beginIO() else { throw Err.closed }
        defer { endIO() }
        var remaining = count
        var out = Data()
        out.reserveCapacity(min(count, Self.readSliceBytes))
        var buf = [UInt8](repeating: 0, count: min(count, Self.readSliceBytes))
        while remaining > 0 {
            let toRead = min(buf.count, remaining)
            let r = buf.withUnsafeMutableBytes { p in
                read(fd, p.baseAddress, toRead)
            }
            if r == 0 { markClosed(); throw Err.closed }
            if r < 0 {
                let e = errno
                if e == EINTR { continue }
                let message = errnoString("ws read")
                markClosed()
                throw Err.io(message)
            }
            out.append(contentsOf: buf[0..<r])
            remaining -= r
        }
        return out
    }

    /// Writes all of `data`. With `nonBlocking`, gives up instead of waiting for buffer space.
    private func writeAll(_ data: Data, nonBlocking: Bool = false) throws {
        guard !data.isEmpty else { return }
        guard beginIO() else { throw Err.closed }
        defer { endIO() }
        try data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            guard var base = p.baseAddress else { return }
            var remaining = p.count
            while remaining > 0 {
                let w: Int
                if nonBlocking {
#if os(Linux)
                    w = Glibc.send(fd, base, remaining, Int32(MSG_DONTWAIT))
#else
                    w = Darwin.send(fd, base, remaining, Int32(MSG_DONTWAIT))
#endif
                } else {
                    w = write(fd, base, remaining)
                }
                if w < 0 {
                    let e = errno
                    if e == EINTR { continue }
                    let message = errnoString("ws write")
                    markClosed()
                    if e == EPIPE || e == ECONNRESET {
                        throw Err.closed
                    }
                    throw Err.io(message)
                }
                if w == 0 { markClosed(); throw Err.closed }
                remaining -= w
                base = base.advanced(by: w)
            }
        }
    }

    // MARK: - Framing

    private func unmask(_ data: inout Data, key: UInt32) {
        let maskBytes: [UInt8] = [UInt8(key >> 24), UInt8((key >> 16) & 0xFF),
                                  UInt8((key >> 8) & 0xFF), UInt8(key & 0xFF)]
        data.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            guard let base = p.baseAddress else { return }
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for i in 0..<p.count {
                ptr[i] ^= maskBytes[i & 3]
            }
        }
    }

    private func serialize(frame: WebSocketFrame, mask: Bool = false) -> Data {
        var out = Data()
        let finBit: UInt8 = frame.fin ? 0x80 : 0x00
        let opcodeNibble: UInt8 = frame.opcode.rawValue & 0x0F
        out.append(finBit | opcodeNibble)

        let payload = frame.payload
        let maskBit: UInt8 = mask ? 0x80 : 0x00
        let len = payload.count
        if len <= 125 {
            out.append(maskBit | UInt8(len))
        } else if len <= 0xFFFF {
            out.append(maskBit | 126)
            var be = UInt16(len).bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        } else {
            out.append(maskBit | 127)
            var be = UInt64(len).bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        }

        if mask {
            let maskingKey = frame.maskingKey ?? UInt32.random(in: UInt32.min...UInt32.max)
            var be = maskingKey.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
            // apply masking to payload copy
            var copy = payload
            unmask(&copy, key: maskingKey)
            out.append(copy)
        } else {
            out.append(payload)
        }

        return out
    }

    /// Reads `count` (2, 4 or 8) bytes as a big-endian unsigned integer.
    private func readBigEndian(_ count: Int) throws -> UInt64 {
        let bytes = try readExact(count)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// Fails the connection (RFC 6455 section 7.1.7): sends a best-effort Close frame with
    /// `code`, stops writing, shuts the socket down and returns the error to throw.
    /// It never waits on a peer that is not reading, and the descriptor is left for the
    /// owner's `closeSocket()`.
    private func failConnection(_ code: UInt16, _ reason: String) -> WebSocketProtocolError {
        partialOpcode = nil
        partialPayload = Data()
        // Wait briefly for a frame being written by another thread, so the Close frame is
        // not spliced into it. If that writer is stuck, skip the Close frame.
        if writeLock.lock(before: Date(timeIntervalSinceNow: 1)) {
            let mayWrite: Bool = locked {
                let ok = !closedForWriting && !closeFrameSent
                closedForWriting = true
                closeFrameSent = true
                return ok
            }
            if mayWrite {
                let payload = WebSocketWire.closePayload(code: code, reason: reason)
                let bytes = serialize(frame: WebSocketFrame(fin: true, opcode: .close, payload: payload))
                try? writeAll(bytes, nonBlocking: true)
            }
            writeLock.unlock()
        }
        shutdownSocket()
        return WebSocketProtocolError(closeCode: code, reason: reason)
    }

    /// Reads one frame, validating the header and limits before the payload is read.
    /// Returns a complete data message, or a control frame. Control frames may arrive
    /// between the fragments of a message; the partial message is kept for the next call.
    private func readFrameOrMessage() throws -> WebSocketFrame? {
        let header = try readExact(2)
        let b0 = header[header.startIndex]
        let b1 = header[header.startIndex + 1]
        let fin = (b0 & 0x80) != 0

        // RSV1-3 have meaning only with a negotiated extension, and none is ever negotiated.
        guard (b0 & 0x70) == 0 else {
            throw failConnection(WebSocketCloseCode.protocolError, "reserved bits set without a negotiated extension")
        }
        guard let opcode = WebSocketOpcode(rawValue: b0 & 0x0F) else {
            throw failConnection(WebSocketCloseCode.protocolError, "unknown opcode \(b0 & 0x0F)")
        }
        // Section 5.1: a server must close the connection on an unmasked client frame.
        guard (b1 & 0x80) != 0 else {
            throw failConnection(WebSocketCloseCode.protocolError, "client frames must be masked")
        }
        let shortLength = UInt64(b1 & 0x7F)
        if opcode.isControl {
            // Section 5.5: control frames are never fragmented and carry at most 125 bytes.
            guard fin else {
                throw failConnection(WebSocketCloseCode.protocolError, "fragmented control frame")
            }
            guard shortLength <= 125 else {
                throw failConnection(WebSocketCloseCode.protocolError, "control frame payload over 125 bytes")
            }
        } else if opcode == .continuation {
            guard partialOpcode != nil else {
                throw failConnection(WebSocketCloseCode.protocolError, "continuation frame with no message in progress")
            }
        } else {
            guard partialOpcode == nil else {
                throw failConnection(WebSocketCloseCode.protocolError, "new data frame while a fragmented message is in progress")
            }
        }

        var length = shortLength
        if shortLength == 126 {
            length = try readBigEndian(2)
        } else if shortLength == 127 {
            length = try readBigEndian(8)
            // Section 5.2: the most significant bit of a 64-bit length must be 0.
            guard (length & (1 << 63)) == 0 else {
                throw failConnection(WebSocketCloseCode.protocolError, "64-bit payload length with the most significant bit set")
            }
        }

        if !opcode.isControl {
            let (frameMax, messageMax) = locked { (frameLimit, messageLimit) }
            guard length <= UInt64(frameMax) else {
                throw failConnection(WebSocketCloseCode.messageTooBig, "frame larger than \(frameMax) bytes")
            }
            // Both terms are below 2^63, so the sum cannot overflow.
            let soFar = opcode == .continuation ? UInt64(partialPayload.count) : 0
            guard soFar + length <= UInt64(messageMax) else {
                throw failConnection(WebSocketCloseCode.messageTooBig, "message larger than \(messageMax) bytes")
            }
        }

        let maskingKey = try UInt32(truncatingIfNeeded: readBigEndian(4))
        // `length` is now at most 125 (control) or within the configured limits.
        var payload = try readExact(Int(length))
        unmask(&payload, key: maskingKey)

        switch opcode {
            case .ping, .pong:
                return WebSocketFrame(fin: true, opcode: opcode, payload: payload, maskingKey: maskingKey)
            case .close:
                switch WebSocketWire.parseClosePayload(payload) {
                    case .failure(let error):
                        throw failConnection(error.closeCode, error.reason)
                    case .success(let parsed):
                        locked {
                            peerCloseCode = parsed.code
                            peerCloseReason = parsed.reason
                        }
                }
                // Any partial message is abandoned: the peer is closing.
                partialOpcode = nil
                partialPayload = Data()
                return WebSocketFrame(fin: true, opcode: .close, payload: payload, maskingKey: maskingKey)
            case .text, .binary:
                if fin {
                    try validateMessage(opcode: opcode, payload: payload)
                    return WebSocketFrame(fin: true, opcode: opcode, payload: payload, maskingKey: maskingKey)
                }
                partialOpcode = opcode
                partialPayload = payload
                return nil
            case .continuation:
                partialPayload.append(payload)
                guard fin, let messageOpcode = partialOpcode else { return nil }
                let message = partialPayload
                partialOpcode = nil
                partialPayload = Data()
                try validateMessage(opcode: messageOpcode, payload: message)
                return WebSocketFrame(fin: true, opcode: messageOpcode, payload: message, maskingKey: nil)
        }
    }

    /// Section 8.1: a text message must be valid UTF-8.
    private func validateMessage(opcode: WebSocketOpcode, payload: Data) throws {
        if opcode == .text && !WebSocketWire.isValidUTF8(payload) {
            throw failConnection(WebSocketCloseCode.invalidPayload, "text message is not valid UTF-8")
        }
    }

    /// Reads the next complete message (fragments reassembled) or control frame.
    ///
    /// A ping, pong or close that arrives between the fragments of a message is returned
    /// on its own; the partial message carries on with the next call. Throws
    /// `WebSocketProtocolError` (after sending the matching Close frame) when the peer
    /// breaks the protocol or exceeds `maxFrameBytes` / `maxMessageBytes`.
    public func readMessage() throws -> WebSocketFrame {
        while true {
            if let frame = try readFrameOrMessage() {
                return frame
            }
        }
    }

    // MARK: - Public send helpers (servers do not mask)

    /// Writes one frame; the caller holds `writeLock`.
    private func writeFrameLocked(_ frame: WebSocketFrame) throws {
        if isClosed { throw Err.closed }
        // As a server, do not mask outgoing frames per RFC6455
        try writeAll(serialize(frame: frame, mask: false))
        if frame.opcode == .close {
            // Section 5.5.1: nothing may be sent after a Close frame.
            locked {
                closeFrameSent = true
                closedForWriting = true
            }
        }
    }

    public func send(frame: WebSocketFrame) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try writeFrameLocked(frame)
    }

    /// Non-throwing send that returns false on failure (useful from tick handlers)
    @discardableResult
    public func safeSend(frame: WebSocketFrame) -> Bool {
        do {
            try send(frame: frame)
            return true
        } catch {
            return false
        }
    }

    public func sendText(_ text: String) throws {
        try send(frame: WebSocketFrame(fin: true, opcode: .text, payload: Data(text.utf8)))
    }

    /// Non-throwing text send — returns false if the connection is broken
    @discardableResult
    public func safeSendText(_ text: String) -> Bool {
        return safeSend(frame: WebSocketFrame(fin: true, opcode: .text, payload: Data(text.utf8)))
    }

    public func sendBinary(_ data: Data) throws {
        try send(frame: WebSocketFrame(fin: true, opcode: .binary, payload: data))
    }

    public func sendPing(_ data: Data = Data()) throws {
        let payload = data.prefix(125) // control frames max 125
        try send(frame: WebSocketFrame(fin: true, opcode: .ping, payload: payload))
    }

    public func sendPong(_ data: Data = Data()) throws {
        let payload = data.prefix(125)
        try send(frame: WebSocketFrame(fin: true, opcode: .pong, payload: payload))
    }

    /// Sends a Close frame and stops further writes. Calling it again after the Close
    /// frame has gone out does nothing. Throws `Err.closed` if the connection broke first.
    public func close(code: UInt16 = 1000, reason: String = "") throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        if locked({ closeFrameSent }) { return }
        let payload = WebSocketWire.closePayload(code: code, reason: reason)
        try writeFrameLocked(WebSocketFrame(fin: true, opcode: .close, payload: payload))
    }

    // MARK: - Run loop

    public typealias FrameHandler = @Sendable (WebSocketFrame) -> [WebSocketFrame]?

    // Runs a blocking loop reading frames and invoking the handler. Returns on close or error.
    public func run(handle: FrameHandler) throws {
        defer { markClosed() }
        loop: while true {
            // Errors (peer gone, protocol violation) end the loop and reach the caller.
            let frame = try readMessage()
            switch frame.opcode {
                case .ping:
                    // if handler returns nothing, auto-pong
                    if let responses = handle(frame) {
                        for r in responses { _ = safeSend(frame: r) }
                    } else {
                        _ = safeSend(frame: WebSocketFrame(fin: true, opcode: .pong, payload: frame.payload))
                    }
                case .close:
                    // echo close if handler doesn't override
                    if let responses = handle(frame) {
                        for r in responses { _ = safeSend(frame: r) }
                    } else {
                        // best-effort echo — peer may already be gone
                        _ = safeSend(frame: WebSocketFrame(fin: true, opcode: .close, payload: frame.payload))
                    }
                    break loop
                default:
                    if let responses = handle(frame) {
                        for r in responses {
                            if !safeSend(frame: r) { break loop }
                        }
                    }
            }
        }
    }
}

// MARK: - Server

public final class HTTPServer: @unchecked Sendable {
    
    public typealias HeadCallback = (HttpRequestHead) -> GateDecision
    public typealias BeforeBodyCallback = (HttpRequestHead) -> GateDecision
    public typealias Handler = (HttpRequest) -> HttpResponse
    public typealias RouteHandler = (HttpRequest) -> HttpResponse
    
    private struct WildcardRoute {
        let pattern: String
        let regex: NSRegularExpression
        let literalCount: Int
        let wildcardCount: Int
        let handler: RouteHandler
    }
    
    public struct Config {
        public var host: String = "0.0.0.0"
        public var port: UInt16 = 8080
        public var workers: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        public var recvTimeoutSeconds: Int32 = 60
        public var absoluteMaxBodyBytes: Int = 1_000_000_000          // 1 GB safety
        public init() {}
    }
    
    internal var routes: [String: RouteHandler] = [:]
    private var wildcardRoutes: [WildcardRoute] = []
    private let routesLock = DispatchQueue(label: "microhttp.routes")
    
    public func addRoute(_ path: String, handler: @escaping RouteHandler) {
        routesLock.sync {
            if path.contains("*") {
                if let regex = Self.wildcardRegex(for: path) {
                    wildcardRoutes.removeAll(where: { $0.pattern == path })
                    wildcardRoutes.append(WildcardRoute(
                        pattern: path,
                        regex: regex,
                        literalCount: path.filter({ $0 != "*" }).count,
                        wildcardCount: path.filter({ $0 == "*" }).count,
                        handler: handler
                    ))
                    wildcardRoutes.sort {
                        if $0.literalCount != $1.literalCount { return $0.literalCount > $1.literalCount }
                        if $0.wildcardCount != $1.wildcardCount { return $0.wildcardCount < $1.wildcardCount }
                        return $0.pattern.count > $1.pattern.count
                    }
                } else {
                    routes[path] = handler
                }
                return
            }
            
            routes[path] = handler
        }
    }
    
    internal func routeHandler(for path: String) -> RouteHandler? {
        routesLock.sync {
            if let exact = routes[path] {
                return exact
            }
            
            let fullRange = NSRange(location: 0, length: path.utf16.count)
            for wildcard in wildcardRoutes {
                if wildcard.regex.firstMatch(in: path, options: [], range: fullRange) != nil {
                    return wildcard.handler
                }
            }
            return nil
        }
    }
    
    private static func wildcardRegex(for path: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: path)
        let pattern = "^" + escaped.replacingOccurrences(of: "\\*", with: ".*") + "$"
        return try? NSRegularExpression(pattern: pattern)
    }
    
    private let cfg: Config
    private let onHead: HeadCallback
    private let onBeforeBody: BeforeBodyCallback
    private let handler: Handler
    private var listenFD: Int32 = -1
    private let pool: ThreadPool
    private let acceptQueue = DispatchQueue(label: "microhttp.accept", qos: .userInitiated)
    
    public init(
        config: Config = Config(),
        onRequestHead: @escaping HeadCallback,
        onBeforeBody: @escaping BeforeBodyCallback,
        handler: @escaping Handler
    ) {
        self.cfg = config
        self.onHead = onRequestHead
        self.onBeforeBody = onBeforeBody
        self.handler = handler
        self.pool = ThreadPool(workers: config.workers)
    }
    
    public func start() throws {
        // Ignore SIGPIPE process-wide so broken sockets don't kill the process
        signal(SIGPIPE, SIG_IGN)

#if os(Linux)
        let sockType = CInt(SOCK_STREAM.rawValue)
#else
        let sockType = CInt(SOCK_STREAM)
#endif
        listenFD = socket(AF_INET, sockType, 0)
        guard listenFD >= 0 else { throw Err.socket(errnoString("socket")) }
        
        var yes: Int32 = 1
        _ = setsockopt(listenFD, CInt(SOL_SOCKET), CInt(SO_REUSEADDR), &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        _ = setsockopt(listenFD, CInt(IPPROTO_TCP), CInt(TCP_NODELAY), &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = cfg.port.bigEndian
        let saddr = cfg.host.withCString { inet_addr($0) }
        addr.sin_addr = in_addr(s_addr: saddr)
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                bind(listenFD, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { throw Err.bind(errnoString("bind")) }
        guard listen(listenFD, CInt(SOMAXCONN)) == 0 else { throw Err.listen(errnoString("listen")) }
        
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }
    
    public func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }
    
    /// The port the listening socket is bound to (useful with `Config.port = 0`), or nil when not listening.
    internal var boundPort: UInt16? {
        let fd = listenFD
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard rc == 0 else { return nil }
        return UInt16(bigEndian: addr.sin_port)
    }
    
    private func acceptLoop() {
        while listenFD >= 0 {
            var addr = sockaddr()
            var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
            let fd = accept(listenFD, &addr, &len)
            if fd < 0 {
                // benign EINTR etc.
                continue
            }
            // Prevent SIGPIPE on this socket (macOS)
            #if !os(Linux)
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            #endif
            pool.submit { [weak self] in
                self?.handleConnection(fd: fd)
            }
        }
    }
    
    private func handleConnection(fd: Int32) {
        var shouldClose = true
        defer { if shouldClose { close(fd) } }
        var tv = timeval(tv_sec: Int(cfg.recvTimeoutSeconds), tv_usec: 0)
        _ = setsockopt(fd, CInt(SOL_SOCKET), CInt(SO_RCVTIMEO), &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
        
        do {
            let head = try readHead(fd: fd)
            
            // Reject "..", encoded separators, NUL etc. before any route sees the raw path
            if case .failure = RequestPathValidator.validate(uri: head.uri) {
                try writeResponse(fd: fd, resp: HttpResponse().status(.badRequest).content(.text).body("Bad request"))
                return
            }
            
            let hm = head.headerMap
            let connectionHeader = hm["connection"]?.lowercased() ?? ""
            let upgradeHeader = hm["upgrade"]?.lowercased() ?? ""
            var reqKind: RequestKind = .http
            if connectionHeader.contains("upgrade") && upgradeHeader == "websocket" {
                if let key = hm["sec-websocket-key"] {
                    let protos = (hm["sec-websocket-protocol"] ?? "")
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let ver = Int(hm["sec-websocket-version"] ?? "")
                    let ext = hm["sec-websocket-extensions"]
                    reqKind = .websocket(WebSocketUpgrade(key: key, protocols: protos, version: ver, extensions: ext, socketFD: fd))
                }
            }
            
            // Gate 1 (immediately after headers)
            switch onHead(head) {
                case .accept:
                    break
                case .reject(let resp):
                    try writeResponse(fd: fd, resp: resp)
                    return
            }
            
            // Gate 2 (before reading body) lets you reject based on length/type
            switch onBeforeBody(head) {
                case .accept:
                    break
                case .reject(let resp):
                    try writeResponse(fd: fd, resp: resp)
                    return
            }
            
            let body = try readBody(fd: fd, head: head)
            
            let req = HttpRequest(head: head, body: body, kind: reqKind)
            let resp = handler(req)
            // Content-Length and the default "Connection: close" are added by writeResponse
            try writeResponse(fd: fd, resp: resp)
            
            if resp.status.code == 101 {
                // The socket now belongs to the upgrade hook (e.g. the WebSocket loop).
                shouldClose = false
                resp.onUpgraded?()
                return
            }
        } catch let e as Err {
            // best-effort 400/413/500 depending
            let resp: HttpResponse
            switch e {
                case .closed:
                    // the peer has gone, or a response was already partly written: nothing more to send
                    return
                case .tooLarge:
                    resp = HttpResponse().status(.payloadTooLarge).content(.text).body("Payload too large")
                case .parse, .unsupported:
                    resp = HttpResponse().status(.badRequest).content(.text).body("Bad request")
                default:
                    resp = HttpResponse().status(.internalError).content(.text).body("Internal error")
            }
            _ = try? writeResponse(fd: fd, resp: resp)
        } catch let e as RequestHeadTooLarge {
            let resp: HttpResponse
            switch e {
                case .requestLine:
                    resp = HttpResponse().status(HttpStatus(414, "URI Too Long")).content(.text).body("URI too long")
                case .headerFields:
                    resp = HttpResponse().status(HttpStatus(431, "Request Header Fields Too Large")).content(.text).body("Request header fields too large")
            }
            _ = try? writeResponse(fd: fd, resp: resp)
        } catch {
            let resp = HttpResponse().status(.internalError).content(.text).body("Internal error")
            _ = try? writeResponse(fd: fd, resp: resp)
        }
    }
    
    // MARK: - Parsing
    
    /// Thrown by `readLineCRLF` for a line that does not end within its limit.
    struct LineTooLong: Error {}
    
    /// Thrown by `readHead`; answered 414 (request line) or 431 (header fields).
    enum RequestHeadTooLarge: Error {
        case requestLine
        case headerFields
    }
    
    /// Limits on the request head. A line may hold up to `maxHeadLineBytes` bytes before its CRLF,
    /// the header section (all header lines) up to `maxHeaderSectionBytes`, and there may be at most
    /// `maxHeaderCount` header lines.
    static let maxHeadLineBytes = 16 * 1024
    static let maxHeaderSectionBytes = 64 * 1024
    static let maxHeaderCount = 128
    
    private func readLineCRLF(fd: Int32, limit: Int = HTTPServer.maxHeadLineBytes) throws -> String {
        var data = Data()
        var lastWasCR = false
        var buf = [UInt8](repeating: 0, count: 1)
        while true {
            let r = buf.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress, 1)
            }
            if r == 0 { throw Err.closed }
            if r < 0 {
                if errno == EINTR { continue }
                throw Err.io(errnoString("read line"))
            }
            let b = buf[0]
            if lastWasCR && b == 0x0A { // \n
                data.removeLast() // remove the CR we appended previously
                break
            }
            data.append(b)
            lastWasCR = (b == 0x0D) // \r
            // A line that doesn't end within the limit is refused, never split: returning the first part
            // would let the rest be parsed as a separate header line that a proxy in front never saw.
            // (`limit` content bytes plus the CR of the CRLF are allowed.)
            if data.count > limit + 1 || (data.count == limit + 1 && lastWasCR == false) {
                throw LineTooLong()
            }
        }
        guard let s = String(data: data, encoding: .utf8) else { throw Err.parse("line utf8") }
        return s
    }
    
    func readHead(fd: Int32) throws -> HttpRequestHead {
        // Request line
        let requestLine: String
        do {
            requestLine = try readLineCRLF(fd: fd)
        } catch is LineTooLong {
            throw RequestHeadTooLarge.requestLine
        }
        // a bare CR or LF (or a NUL) left inside a line could be echoed into a response header
        guard Self.hasNoLineBreakOrNUL(requestLine) else { throw Err.parse("control character in request line") }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { throw Err.parse("request line") }
        let method = HttpMethod(String(parts[0]))
        let uri = String(parts[1])
        let version = String(parts[2])
        
        // Headers
        var headers: [(String,String)] = []
        var headerSectionBytes = 0
        while true {
            let line: String
            do {
                line = try readLineCRLF(fd: fd)
            } catch is LineTooLong {
                throw RequestHeadTooLarge.headerFields
            }
            if line.isEmpty { break } // CRLF terminator reached
            // bound the memory and time one client can spend on a request head
            headerSectionBytes += line.utf8.count + 2
            guard headerSectionBytes <= Self.maxHeaderSectionBytes,
                  headers.count < Self.maxHeaderCount else {
                throw RequestHeadTooLarge.headerFields
            }
            guard Self.hasNoLineBreakOrNUL(line) else { throw Err.parse("control character in header") }
            guard let idx = line.firstIndex(of: ":") else { throw Err.parse("header colon") }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers.append((key, val))
        }
        
        return HttpRequestHead(method: method, uri: uri, version: version, headers: headers)
    }
    
    private static func hasNoLineBreakOrNUL(_ line: String) -> Bool {
        return line.utf8.contains(where: { $0 == 0x0D || $0 == 0x0A || $0 == 0x00 }) == false
    }
    
    // MARK: - Body reader (FINISHED)
    
    private func readBody(fd: Int32, head: HttpRequestHead) throws -> HttpBody {
        // Only read body for methods that can have one
        let method = head.method
        let mayHaveBody = !(method == .GET || method == .HEAD)
        if !mayHaveBody { return .none }

        let isChunked = head.isChunked
        let length = head.contentLength

        // Quick rejections
        if let len = length, len > cfg.absoluteMaxBodyBytes {
            throw Err.tooLarge
        }

        // If content-length unknown and not chunked => no body (or unsupported)
        if length == nil && !isChunked {
            return .none
        }

        var inMem = Data()
        inMem.reserveCapacity(min(16 * 1024 * 1024, length ?? (128 * 1024)))

        var total = 0

        func writeChunk(_ ptr: UnsafeRawBufferPointer) throws {
            total += ptr.count
            if total > cfg.absoluteMaxBodyBytes {
                throw Err.tooLarge
            }
            inMem.appendBytes(ptr)
        }

        // --- Fixed length body
        if let len = length, !isChunked {
            if len == 0 { return .none }

            var remaining = len
            let bufSize = min(64 * 1024, max(8 * 1024, len))
            var buf = [UInt8](repeating: 0, count: bufSize)
            while remaining > 0 {
                let toRead = min(buf.count, remaining)
                let r = buf.withUnsafeMutableBytes { p in
                    read(fd, p.baseAddress, toRead)
                }
                if r == 0 { throw Err.closed }
                if r < 0 {
                    if errno == EINTR { continue }
                    throw Err.io(errnoString("read body"))
                }
                try buf.withUnsafeBytes { p in
                    try writeChunk(UnsafeRawBufferPointer(start: p.baseAddress, count: r))
                }
                remaining -= r
            }
            return .inMemory(inMem)
        }

        // --- Chunked body
        if isChunked {
            let bufCap = 64 * 1024
            var buf = [UInt8](repeating: 0, count: bufCap)

            func readLine() throws -> String {
                do {
                    return try readLineCRLF(fd: fd)
                } catch is LineTooLong {
                    throw Err.parse("chunk line too long")
                }
            }

            while true {
                // chunk size line (hex; may include extensions after ';')
                let sizeLine = try readLine()
                let hexPart = sizeLine.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first ?? Substring("")
                guard let chunkSize = Int(hexPart, radix: 16) else { throw Err.parse("chunk size") }
                if chunkSize == 0 {
                    // read trailing headers until empty line
                    while true {
                        let l = try readLine()
                        if l.isEmpty { break }
                    }
                    break
                }
                var remaining = chunkSize
                while remaining > 0 {
                    let toRead = min(buf.count, remaining)
                    let r = buf.withUnsafeMutableBytes { p in
                        read(fd, p.baseAddress, toRead)
                    }
                    if r == 0 { throw Err.closed }
                    if r < 0 {
                        if errno == EINTR { continue }
                        throw Err.io(errnoString("read chunk"))
                    }
                    try buf.withUnsafeBytes { p in
                        try writeChunk(UnsafeRawBufferPointer(start: p.baseAddress, count: r))
                    }
                    remaining -= r
                }
                // trailing CRLF after each chunk
                var crlf = [UInt8](repeating: 0, count: 2)
                let rr = crlf.withUnsafeMutableBytes { p in
                    read(fd, p.baseAddress, 2)
                }
                if rr != 2 || crlf[0] != 0x0D || crlf[1] != 0x0A {
                    throw Err.parse("chunk CRLF")
                }
            }

            return .inMemory(inMem)
        }

        // Fallback
        return .none
    }
    
    // MARK: - Response writer
    
    private func writeAll(fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var base = p.baseAddress!
            var remaining = p.count
            while remaining > 0 {
                let w = write(fd, base, remaining)
                if w < 0 {
                    let e = errno
                    if e == EINTR { continue }
                    if e == EPIPE || e == ECONNRESET { throw Err.closed }
                    throw Err.io(errnoString("write"))
                }
                if w == 0 { throw Err.closed }
                remaining -= w
                base = base.advanced(by: w)
            }
        }
    }

    private func writeAll(fd: Int32, _ ptr: UnsafeRawBufferPointer) throws {
        var base = ptr.baseAddress!
        var remaining = ptr.count
        while remaining > 0 {
            let w = write(fd, base, remaining)
            if w < 0 {
                let e = errno
                if e == EINTR { continue }
                if e == EPIPE || e == ECONNRESET { throw Err.closed }
                throw Err.io(errnoString("write"))
            }
            if w == 0 { throw Err.closed }
            remaining -= w
            base = base.advanced(by: w)
        }
    }
    
    /// What goes on the wire for a response: the final status line, headers and body source.
    internal struct PreparedResponse {
        enum Body: Equatable {
            case none
            case bytes(Data)
            case file(URL, offset: Int, length: Int)
        }
        var status: HttpStatus
        var headers: [(String, String)]
        var body: Body
    }
    
    /// Builds the final status, headers and body for `resp`. Content-Length is written here and
    /// nowhere else.
    ///
    /// - Headers that cannot be written safely (name not an RFC 7230 token, value containing
    ///   CR, LF or NUL) are skipped. HttpResponse already refuses them; this is defence in depth.
    /// - Any Content-Length or Transfer-Encoding the app set is replaced by the real length.
    /// - File bodies send the file's size. A byte range sends 206 (when the status was 200),
    ///   Content-Range and the range length; a range that does not overlap the file sends
    ///   416 with `Content-Range: bytes */<size>`. A missing, unreadable or non-regular file
    ///   sends 404.
    /// - 1xx, 204 and 304 responses carry no body and no Content-Length.
    /// - `Connection: close` is added unless the app set Connection (not for 101), and
    ///   Date and Server are added when missing.
    internal static func prepare(_ resp: HttpResponse, now: Date = Date()) -> PreparedResponse {
        func named(_ name: String) -> ((String, String)) -> Bool {
            return { $0.0.caseInsensitiveCompare(name) == .orderedSame }
        }
        
        let reason = String(String.UnicodeScalarView(resp.status.reason.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        var status = HttpStatus(resp.status.code, reason)
        var headers = resp.headers.filter { HTTPHeaderValidation.isWritable(name: $0.0, value: $0.1) }
        headers.removeAll(where: named("Content-Length"))
        headers.removeAll(where: named("Transfer-Encoding"))
        
        var body: PreparedResponse.Body
        if let url = resp.bodyFileUrl {
            headers.removeAll(where: named("Content-Range"))
            if let size = regularFileSize(url) {
                // A file sent without a Content-Type would be MIME-sniffed by the browser, so an uploaded
                // "image" holding HTML could run script on this origin. Type it from its extension and
                // turn sniffing off. (HttpResponse.file(relativePath:under:) is stricter still and is the
                // API to use for files users can upload.)
                if headers.contains(where: named("Content-Type")) == false {
                    headers.append(("Content-Type", SafeFileResolver.legacyContentType(forExtension: url.pathExtension)))
                }
                if headers.contains(where: named("X-Content-Type-Options")) == false {
                    headers.append(("X-Content-Type-Options", "nosniff"))
                }
                if let range = resp.bodyFileHandleRange {
                    let lower = range.lowerBound
                    let upper = min(range.upperBound, size)
                    if lower < 0 || lower >= size || upper <= lower {
                        status = HttpStatus(416, "Range Not Satisfiable")
                        headers.append(("Content-Range", "bytes */\(size)"))
                        body = .none
                    } else {
                        if status.code == 200 {
                            status = HttpStatus(206, "Partial Content")
                        }
                        headers.append(("Content-Range", "bytes \(lower)-\(upper - 1)/\(size)"))
                        body = .file(url, offset: lower, length: upper - lower)
                    }
                } else {
                    body = .file(url, offset: 0, length: size)
                }
            } else {
                status = .notFound
                headers.removeAll(where: named("Content-Type"))
                headers.append(("Content-Type", "text/plain; charset=utf-8"))
                body = .bytes(Data("Not Found".utf8))
            }
        } else {
            body = .bytes(resp.bodyBytes)
        }
        
        let code = status.code
        if (100..<200).contains(code) || code == 204 || code == 304 {
            body = .none
        } else {
            switch body {
                case .none:
                    headers.append(("Content-Length", "0"))
                case .bytes(let data):
                    headers.append(("Content-Length", "\(data.count)"))
                case .file(_, _, let length):
                    headers.append(("Content-Length", "\(length)"))
            }
        }
        
        if code != 101 && headers.contains(where: named("Connection")) == false {
            headers.append(("Connection", "close"))
        }
        if headers.contains(where: named("Date")) == false {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            fmt.dateFormat = "E, dd MMM yyyy HH:mm:ss 'GMT'"
            headers.append(("Date", fmt.string(from: now)))
        }
        if headers.contains(where: named("Server")) == false {
            headers.append(("Server", "MicroHTTP/1.0"))
        }
        return PreparedResponse(status: status, headers: headers, body: body)
    }
    
    /// The size of a readable regular file, or nil.
    ///
    /// Symlinks are followed, as FileHandle(forReadingFrom:) follows them when the body is
    /// sent: a link to a regular file is served with the target's size, and a dangling link
    /// (or one to a directory, FIFO or device) is nil. attributesOfItem(atPath:) alone does
    /// not follow a link in the last path component, so the path is resolved first.
    private static func regularFileSize(_ url: URL) -> Int? {
        guard url.isFileURL,
              let resolved = SafeFileResolver.realPath(url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              FileManager.default.isReadableFile(atPath: resolved) else {
            return nil
        }
        return size
    }
    
    private func writeResponse(fd: Int32, resp: HttpResponse) throws {
        var prepared = Self.prepare(resp)
        
        // open the file before anything is written, so a failure can still be answered cleanly
        var fileHandle: FileHandle? = nil
        if case .file(let url, let offset, _) = prepared.body {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                try handle.seek(toOffset: UInt64(offset))
                fileHandle = handle
            } catch {
                prepared = Self.prepare(HttpResponse().status(.notFound).content(.text).body("Not Found"))
            }
        }
        defer { try? fileHandle?.close() }
        
        var head = "HTTP/1.1 \(prepared.status.code) \(prepared.status.reason)\r\n"
        for (k, v) in prepared.headers {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        try writeAll(fd: fd, Data(head.utf8))
        
        switch prepared.body {
            case .none:
                return
            case .bytes(let data):
                if data.isEmpty == false {
                    try writeAll(fd: fd, data)
                }
            case .file(_, _, let length):
                guard let handle = fileHandle else { return }
                var remaining = length
                let bufSize = min(64 * 1024, max(8 * 1024, remaining))
                var buf = [UInt8](repeating: 0, count: bufSize)
                while remaining > 0 {
                    let toRead = min(buf.count, remaining)
                    let r = buf.withUnsafeMutableBytes { p in
                        read(handle.fileDescriptor, p.baseAddress, toRead)
                    }
                    if r < 0 && errno == EINTR { continue }
                    // the head promised `length` bytes; if the file shrank or fails now the
                    // response cannot be completed, so stop and let the connection close
                    if r <= 0 { throw Err.closed }
                    try buf.withUnsafeBytes { p in
                        try writeAll(fd: fd, UnsafeRawBufferPointer(start: p.baseAddress, count: r))
                    }
                    remaining -= r
                }
        }
    }
}
