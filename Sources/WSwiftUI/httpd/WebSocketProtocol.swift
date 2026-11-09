//
//  WebSocketProtocol.swift
//  WSwiftUI
//
//  RFC 6455 helpers used by `WebSocketConnection`: close codes, the error thrown when a
//  peer breaks the protocol, and the validation rules for close frames and text payloads.
//

import Foundation

/// Close status codes from RFC 6455 section 7.4.1.
public enum WebSocketCloseCode {
    public static let normalClosure: UInt16 = 1000
    public static let goingAway: UInt16 = 1001
    public static let protocolError: UInt16 = 1002
    public static let unsupportedData: UInt16 = 1003
    public static let invalidPayload: UInt16 = 1007
    public static let policyViolation: UInt16 = 1008
    public static let messageTooBig: UInt16 = 1009
    public static let internalError: UInt16 = 1011

    /// Whether `code` may appear in a Close frame on the wire (RFC 6455 section 7.4).
    /// 1005, 1006 and 1015 are reserved for local use and must never be sent.
    public static func isValidOnWire(_ code: UInt16) -> Bool {
        switch code {
            case 1000...1003, 1007...1014, 3000...4999:
                return true
            default:
                return false
        }
    }
}

/// Thrown by `WebSocketConnection.readMessage()` (and so by `run(handle:)`) when the peer
/// breaks RFC 6455 or exceeds a size limit. By the time it is thrown, the connection has
/// already sent a Close frame carrying `closeCode`, stopped writing, and shut the socket down.
/// The owner still calls `closeSocket()` to release the descriptor.
public struct WebSocketProtocolError: Error, CustomStringConvertible, Sendable, Equatable {
    /// The close code sent to the peer, e.g. 1002 (protocol error) or 1009 (message too big).
    public let closeCode: UInt16
    public let reason: String

    public init(closeCode: UInt16, reason: String) {
        self.closeCode = closeCode
        self.reason = reason
    }

    public var description: String {
        return "WebSocket closed with \(closeCode): \(reason)"
    }
}

internal enum WebSocketWire {

    /// Close-frame reasons are limited so the whole payload fits in a 125-byte control frame.
    static let maxCloseReasonBytes = 123

    /// Builds a Close payload: the big-endian status code, then a UTF-8 reason cut at a
    /// character boundary so it fits in a control frame.
    static func closePayload(code: UInt16, reason: String) -> Data {
        var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        var bytes = Array(reason.utf8)
        if bytes.count > maxCloseReasonBytes {
            var cut = maxCloseReasonBytes
            // Do not split a multi-byte character: back up over continuation bytes (10xxxxxx).
            while cut > 0 && (bytes[cut] & 0xC0) == 0x80 { cut -= 1 }
            bytes = Array(bytes[0..<cut])
        }
        payload.append(contentsOf: bytes)
        return payload
    }

    /// Strict UTF-8 check (rejects overlong forms, surrogates and code points above U+10FFFF).
    static func isValidUTF8<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
        var iterator = bytes.makeIterator()
        var decoder = Unicode.UTF8()
        while true {
            switch decoder.decode(&iterator) {
                case .scalarValue:
                    continue
                case .emptyInput:
                    return true
                case .error:
                    return false
            }
        }
    }

    /// The parsed status code and reason of a Close frame received from the peer.
    struct ClosePayload {
        let code: UInt16?
        let reason: String?
    }

    /// Validates a received Close payload (RFC 6455 section 5.5.1 and 7.4).
    /// Returns the protocol error to fail the connection with, or the parsed payload.
    static func parseClosePayload(_ payload: Data) -> Result<ClosePayload, WebSocketProtocolError> {
        let bytes = [UInt8](payload)
        if bytes.isEmpty {
            return .success(ClosePayload(code: nil, reason: nil))
        }
        if bytes.count == 1 {
            return .failure(WebSocketProtocolError(closeCode: WebSocketCloseCode.protocolError,
                                                   reason: "close frame with a 1-byte payload"))
        }
        let code = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard WebSocketCloseCode.isValidOnWire(code) else {
            return .failure(WebSocketProtocolError(closeCode: WebSocketCloseCode.protocolError,
                                                   reason: "invalid close code \(code)"))
        }
        let reasonBytes = bytes[2...]
        guard isValidUTF8(reasonBytes) else {
            return .failure(WebSocketProtocolError(closeCode: WebSocketCloseCode.invalidPayload,
                                                   reason: "close reason is not valid UTF-8"))
        }
        let reason = reasonBytes.isEmpty ? nil : String(decoding: reasonBytes, as: UTF8.self)
        return .success(ClosePayload(code: code, reason: reason))
    }
}
