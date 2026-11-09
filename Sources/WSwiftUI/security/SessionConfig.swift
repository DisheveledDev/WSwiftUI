//
//  SessionConfig.swift
//  WSwiftUI
//
//  How the session cookie is written: its name, lifetime, Secure and SameSite
//  attributes, and whether an active session slides.
//

import Foundation

/// Session cookie settings for a `WSwiftServer`, set with `server.session = WebSessionConfig(...)`.
///
/// The cookie is written by the server after the endpoint has produced its response, for every
/// kind of response (rendered pages, JSON, `redirect(_:)`, a hand-built `HttpResponse` and the
/// 302 sent when authentication fails). A response gets a `Set-Cookie` only when the session
/// changes:
/// - **established**: `authenticateSession(token:expiry:)` was called;
/// - **cleared**: `deauthenticateSession()` was called, or a cookie token was rejected on an
///   `[.authenticated]` endpoint;
/// - **renewed**: a cookie token was accepted by `onGetUserRoles` on an `[.authenticated]`
///   endpoint and the session slides (see `sliding`).
///
/// Anonymous requests, requests authenticated with `Authorization: Bearer` or `?token=`, and
/// requests to public endpoints (where the cookie token is never validated) get no session cookie
/// unless the endpoint calls `authenticateSession` or `deauthenticateSession` itself.
public struct WebSessionConfig: Sendable, Equatable {

    /// When the session cookie carries the `Secure` attribute.
    public enum SecurePolicy: Sendable, Equatable {
        /// `Secure` when `publicBaseURL` was given with an explicit `https://` scheme, or when the
        /// request arrived through a proxy that reports https (`X-Forwarded-Proto: https` or
        /// `Forwarded: proto=https`, first value). The server itself does not terminate TLS.
        /// A `publicBaseURL` without a scheme (e.g. `"myhost.lan:8080"`) is still normalized to
        /// https for canonical URLs, but does not count as https here.
        case auto
        /// Always `Secure`.
        case always
        /// Never `Secure`. Browsers drop a `SameSite=None` cookie that is not `Secure`.
        case never
    }

    /// The cookie's `SameSite` attribute.
    public enum SameSite: String, Sendable, Equatable {
        case lax = "Lax"
        case strict = "Strict"
        /// `SameSite=None`: cross-site requests carry the cookie. With `SecurePolicy.auto` the
        /// cookie is then always `Secure`, because browsers reject `SameSite=None` without it.
        /// Named after the `no_restriction` value of browser cookie APIs: a case called `none`
        /// would be read as `Optional.none` wherever a `SameSite?` is expected.
        case noRestriction = "None"
    }

    /// The session cookie's name. The companion cookie that remembers an explicit expiry is
    /// named `<cookieName>_exp`.
    public var cookieName: String
    public var secure: SecurePolicy
    public var sameSite: SameSite
    /// Lifetime in seconds of a session established without an explicit expiry, and of every
    /// sliding renewal. Negative values are treated as 0.
    public var maxAge: Int
    /// When true, each request that the app accepts through a cookie (an `[.authenticated]`
    /// endpoint whose `onGetUserRoles` returned roles) re-issues the cookie with `maxAge`.
    /// A session established with an explicit `expiry` never slides: it ends at that expiry.
    public var sliding: Bool
    /// When true, a `?token=` query parameter can authenticate a request (after a Bearer
    /// header, before the cookie). It is never written into the session cookie.
    public var acceptQueryToken: Bool

    public init(cookieName: String = "auth",
                secure: SecurePolicy = .auto,
                sameSite: SameSite = .lax,
                maxAge: Int = 3600,
                sliding: Bool = true,
                acceptQueryToken: Bool = false) {
        self.cookieName = cookieName
        self.secure = secure
        self.sameSite = sameSite
        self.maxAge = maxAge
        self.sliding = sliding
        self.acceptQueryToken = acceptQueryToken
    }

    /// The companion cookie holding an explicit expiry as Unix seconds.
    internal var expiryCookieName: String { cookieName + "_exp" }
}
