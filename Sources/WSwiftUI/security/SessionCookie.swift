//
//  SessionCookie.swift
//  WSwiftUI
//
//  Where the request's auth token came from, whether the request reached us over
//  https, and how the session cookie and its expiry companion are written.
//  The decision of WHEN to write them lives in SessionLifecycle.swift.
//

import Foundation

/// Where the authentication token of a request was found. A request without a token has no
/// `AuthenticationCredential` at all, so there is no "none" case (which `credential?.source == .none`
/// would silently read as `Optional.none`).
internal enum AuthenticationTokenSource: Sendable, Equatable {
    /// `Authorization: Bearer <token>`.
    case bearerHeader
    /// `?token=<token>` (only honoured when `WebSessionConfig.acceptQueryToken` is true).
    case queryParameter
    /// The session cookie.
    case cookie
}

internal struct AuthenticationCredential: Equatable, Sendable {
    let token: String
    let source: AuthenticationTokenSource
}

extension HttpRequest {

    /// Finds the request's authentication token and where it came from.
    ///
    /// Order: an `Authorization: Bearer <token>` header, then `?token=` when `acceptQueryToken`
    /// is true, then the session cookie. An `Authorization` header with any other scheme (for
    /// example Basic auth added by a proxy) is ignored, so the cookie still authenticates.
    /// When `acceptQueryToken` is false the query string is ignored entirely. An empty cookie
    /// or query value is no token.
    internal func authenticationCredential(acceptQueryToken: Bool,
                                           cookieName: String = SessionCookie.name) -> AuthenticationCredential? {
        if let authHeader = head.headers.first(where: { $0.0.lowercased() == "authorization" })?.1 {
            let components = authHeader.split(separator: " ")
            if components.count == 2, components[0].lowercased() == "bearer" {
                return AuthenticationCredential(token: String(components[1]), source: .bearerHeader)
            }
        }
        if acceptQueryToken, let token = head.queryParams["token"], token.isEmpty == false {
            return AuthenticationCredential(token: token, source: .queryParameter)
        }
        if let cookie = cookies[cookieName], cookie.isEmpty == false {
            return AuthenticationCredential(token: cookie, source: .cookie)
        }
        return nil
    }

    /// True when a proxy in front of the server reports that the client used https:
    /// the first value of `X-Forwarded-Proto`, or the `proto=` of the first element of
    /// `Forwarded` (RFC 7239). Only used to add `Secure` to cookies, which a spoofed header
    /// can only make stricter.
    internal var forwardedProtoIsHTTPS: Bool {
        if let value = firstHeader("x-forwarded-proto"),
           let first = value.split(separator: ",", omittingEmptySubsequences: false).first,
           first.trimmingCharacters(in: .whitespaces).lowercased() == "https" {
            return true
        }
        if let value = firstHeader("forwarded"),
           let element = value.split(separator: ",", omittingEmptySubsequences: false).first {
            for pair in element.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "proto" else { continue }
                var proto = parts[1].trimmingCharacters(in: .whitespaces)
                if proto.count >= 2, proto.hasPrefix("\""), proto.hasSuffix("\"") {
                    proto = String(proto.dropFirst().dropLast())
                }
                return proto.lowercased() == "https"
            }
        }
        return false
    }

    private func firstHeader(_ lowercasedName: String) -> String? {
        return head.headers.first(where: { $0.0.lowercased() == lowercasedName })?.1
    }
}

internal enum SessionCookie {

    /// The default session cookie name (`WebSessionConfig.cookieName`).
    static let name = "auth"

    /// The longest lifetime written into a cookie, in seconds (about 68 years).
    static let maximumLifetime = Int(Int32.max)

    /// True when a `publicBaseURL`, as the app wrote it, names the `https://` scheme explicitly
    /// (any case, surrounding whitespace ignored). A value without a scheme is not https here,
    /// although WSwiftServer normalizes it to https for canonical URLs.
    static func declaresHTTPS(_ publicBaseURL: String?) -> Bool {
        guard let publicBaseURL else { return false }
        return publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("https://")
    }

    /// What the request's expiry companion cookie says.
    enum Companion: Equatable {
        /// The request carried no companion cookie.
        case absent
        /// The companion was present but is not a plain number of Unix seconds; it is ignored.
        case malformed
        /// The session was established with an explicit expiry at this time.
        case expires(Date)

        /// Parses a companion value: 1 to 12 ASCII digits of Unix seconds.
        init(cookieValue: String?) {
            guard let cookieValue else {
                self = .absent
                return
            }
            guard (1...12).contains(cookieValue.utf8.count),
                  cookieValue.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let seconds = Int(cookieValue) else {
                self = .malformed
                return
            }
            self = .expires(Date(timeIntervalSince1970: TimeInterval(seconds)))
        }

        var isPresent: Bool { self != .absent }
    }

    /// Whole seconds from `now` until `date`, clamped to `0...maximumLifetime`.
    static func seconds(until date: Date, from now: Date) -> Int {
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite, interval > 0 else { return 0 }
        return Int(min(interval.rounded(.down), Double(maximumLifetime)))
    }

    /// Writes one session cookie (`HttpOnly`, `Path=/`, the configured SameSite and Secure).
    /// HttpResponse.setCookie drops the cookie (and logs) if the value is not cookie-octets.
    @discardableResult
    static func write(_ name: String, value: String, maxAge: Int, secure: Bool,
                      config: WebSessionConfig, to response: HttpResponse) -> HttpResponse {
        return response.setCookie(name: name, value: value, path: "/", domain: nil,
                                  maxAge: min(max(0, maxAge), maximumLifetime), expires: nil,
                                  httpOnly: true, secure: secure, sameSite: config.sameSite.rawValue)
    }

    /// Expires one session cookie: empty value, `Max-Age=0` and an `Expires` in 1970, with the
    /// same Path, SameSite and Secure attributes it was written with.
    @discardableResult
    static func clear(_ name: String, secure: Bool, config: WebSessionConfig, to response: HttpResponse) -> HttpResponse {
        return response.setCookie(name: name, value: "", path: "/", domain: nil,
                                  maxAge: 0, expires: Date(timeIntervalSince1970: 0),
                                  httpOnly: true, secure: secure, sameSite: config.sameSite.rawValue)
    }
}
