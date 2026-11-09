//
//  SessionLifecycle.swift
//  WSwiftUI
//
//  The per-request session: what the endpoint asked for (authenticateSession /
//  deauthenticateSession), whether the server accepted the request's credential,
//  and the single finalizer that turns that into Set-Cookie headers on whatever
//  response the dispatcher returns.
//

import Foundation

/// What a response does to the session cookie.
internal enum SessionChange: Equatable {
    /// No Set-Cookie.
    case none
    /// `authenticateSession(token:expiry:)`: write `token`, for `expiry - now` seconds when an
    /// expiry was given (remembered in the `<cookieName>_exp` companion), otherwise `maxAge`.
    case established(token: String, expiry: Date?)
    /// Sliding renewal of an accepted cookie token: write it again for `maxAge` seconds.
    case renewed(token: String)
    /// Expire the cookie (and the companion, if the request carried one). `token` is the token
    /// that was in effect, if any.
    case cleared(token: String?)
}

/// The session state of one request. WSwiftServer creates one per dispatched request, hands it to
/// the endpoint, and finalizes every response with it. An endpoint that is not being dispatched
/// (for example one created only to read its `path`) gets a detached context that writes nothing.
internal final class SessionRequestContext {

    enum CredentialCheck: Equatable {
        /// The endpoint is public: the credential was never validated.
        case unchecked
        /// `onGetUserRoles` returned roles for the credential.
        case accepted
        /// The endpoint requires authentication and the credential was missing or rejected.
        case rejected
    }

    let config: WebSessionConfig
    let credential: AuthenticationCredential?
    /// The token in the request's session cookie, when it has a non-empty one. It is not always the
    /// credential: a Bearer header or an accepted `?token=` takes precedence over the cookie.
    let cookieToken: String?
    /// Whether cookies written for this request carry `Secure`.
    let secure: Bool
    /// The request's `<cookieName>_exp` companion cookie.
    let companion: SessionCookie.Companion

    /// What the endpoint asked for: `.none`, `.established` or `.cleared`. The last call wins.
    private(set) var requested: SessionChange = .none
    private(set) var credentialCheck: CredentialCheck = .unchecked
    /// Tokens already passed to `onSessionEnded` during this request.
    private(set) var endedTokens: [String] = []

    private let onSessionEnded: ((String) -> Void)?
    private let clock: () -> Date

    /// - Parameter publicBaseURLIsHTTPS: whether the app gave `publicBaseURL` an explicit `https://`
    ///   scheme (`SessionCookie.declaresHTTPS`). WSwiftServer normalizes a value without a scheme to
    ///   https for canonical URLs; that alone must not make cookies `Secure` on a plain-http deployment.
    init(request: HttpRequest,
         config: WebSessionConfig,
         publicBaseURLIsHTTPS: Bool,
         onSessionEnded: ((String) -> Void)?,
         clock: @escaping () -> Date = Date.init) {
        self.config = config
        self.credential = request.authenticationCredential(acceptQueryToken: config.acceptQueryToken,
                                                            cookieName: config.cookieName)
        if let cookie = request.cookies[config.cookieName], cookie.isEmpty == false {
            self.cookieToken = cookie
        } else {
            self.cookieToken = nil
        }
        self.companion = SessionCookie.Companion(cookieValue: request.cookies[config.expiryCookieName])
        switch config.secure {
            case .always:
                self.secure = true
            case .never:
                self.secure = false
            case .auto:
                self.secure = config.sameSite == .noRestriction || publicBaseURLIsHTTPS || request.forwardedProtoIsHTTPS
        }
        self.onSessionEnded = onSessionEnded
        self.clock = clock
    }

    /// A context for an endpoint that is not being dispatched: no credential, writes nothing.
    init() {
        self.config = WebSessionConfig()
        self.credential = nil
        self.cookieToken = nil
        self.secure = false
        self.companion = .absent
        self.onSessionEnded = nil
        self.clock = Date.init
    }

    // MARK: Endpoint requests

    /// `authenticateSession(token:expiry:)`.
    func establish(token: String, expiry: Date?) {
        requested = .established(token: token, expiry: expiry)
    }

    /// `deauthenticateSession()`. Ends the token in effect: the one established earlier in this
    /// request, otherwise `requestToken` (the request's own token). The response clears the session
    /// cookie, so the token that cookie held is ended too when it is a different one (for example a
    /// request that carries both a Bearer header and the cookie). `onSessionEnded` runs at once, at
    /// most once per token per request; calling this again does nothing more.
    func end(requestToken: String?) {
        let token: String?
        switch requested {
            case .cleared:
                return
            case .established(let established, _):
                token = established
            case .none, .renewed:
                token = requestToken
        }
        requested = .cleared(token: token)
        for ended in [token, cookieToken] {
            guard let ended, ended.isEmpty == false, endedTokens.contains(ended) == false else { continue }
            endedTokens.append(ended)
            onSessionEnded?(ended)
        }
    }

    // MARK: Server decisions

    func credentialAccepted() { credentialCheck = .accepted }
    func credentialRejected() { credentialCheck = .rejected }

    /// The change to apply to the response.
    ///
    /// 1. An explicit `authenticateSession` / `deauthenticateSession` always applies (last call wins).
    /// 2. Otherwise only a cookie-borne token can change the cookie:
    ///    - rejected on an `[.authenticated]` endpoint: cleared;
    ///    - accepted, with a companion whose expiry has passed: cleared;
    ///    - accepted, with a valid companion in the future: unchanged (an explicit expiry never slides);
    ///    - accepted otherwise: renewed when `sliding` is on.
    ///    A public endpoint never validates the cookie, so it never renews or clears it.
    /// Bearer and `?token=` credentials, and anonymous requests, never change the cookie.
    var decision: SessionChange {
        switch requested {
            case .established, .cleared:
                return requested
            case .none, .renewed:
                break
        }
        guard let credential, credential.source == .cookie else { return .none }
        switch credentialCheck {
            case .unchecked:
                return .none
            case .rejected:
                return .cleared(token: credential.token)
            case .accepted:
                switch companion {
                    case .expires(let expiry):
                        return expiry <= clock() ? .cleared(token: credential.token) : .none
                    case .absent, .malformed:
                        return config.sliding ? .renewed(token: credential.token) : .none
                }
        }
    }

    // MARK: Finalizer

    /// Whether the response is for a signed-in user: the server accepted the request's credential,
    /// or the response starts or renews a session. Such a response is marked `Cache-Control: private`
    /// unless it sets Cache-Control itself, so a shared cache never stores one user's page for others.
    /// (Responses used to carry a Set-Cookie, which most shared caches won't store; now that the
    /// cookie is sent only when the session changes, many authenticated pages have none.)
    var isPersonalized: Bool {
        if credentialCheck == .accepted { return true }
        switch decision {
            case .established, .renewed:
                return true
            case .none, .cleared:
                return false
        }
    }

    /// Applies `decision` to `response`, and marks a personalized response `Cache-Control: private`.
    /// Every response the dispatcher returns passes through here.
    ///
    /// A response that already sets the session cookie itself keeps it, and one that sets
    /// Cache-Control keeps that. A response that is shared (still referenced elsewhere, e.g. a static
    /// instance) is copied first, so a token is never written into an object another request will return.
    func finalize(_ response: consuming HttpResponse) -> HttpResponse {
        var target = consume response
        let change = decision

        let cookiePrefix = config.cookieName + "="
        let setsSessionCookie = target.headers.contains(where: {
            $0.0.caseInsensitiveCompare("Set-Cookie") == .orderedSame && $0.1.hasPrefix(cookiePrefix)
        })
        let writesCookie = change != .none && setsSessionCookie == false
        let marksPrivate = isPersonalized && target.headers.contains(where: {
            $0.0.caseInsensitiveCompare("Cache-Control") == .orderedSame
        }) == false
        guard writesCookie || marksPrivate else { return target }

        if isKnownUniquelyReferenced(&target) == false {
            target = SessionRequestContext.copy(of: target)
        }

        if marksPrivate {
            target.header("Cache-Control", "private")
        }
        guard writesCookie else { return target }

        switch change {
            case .none:
                break
            case .established(let token, let expiry):
                let before = target.headers.count
                if let expiry {
                    let now = clock()
                    let lifetime = SessionCookie.seconds(until: expiry, from: now)
                    SessionCookie.write(config.cookieName, value: token, maxAge: lifetime, secure: secure, config: config, to: target)
                    guard target.headers.count > before else { break }
                    let expiresAt = Int(now.timeIntervalSince1970.rounded(.down)) + lifetime
                    SessionCookie.write(config.expiryCookieName, value: String(expiresAt), maxAge: lifetime, secure: secure, config: config, to: target)
                } else {
                    SessionCookie.write(config.cookieName, value: token, maxAge: config.maxAge, secure: secure, config: config, to: target)
                    guard target.headers.count > before else { break }
                    if companion.isPresent {
                        SessionCookie.clear(config.expiryCookieName, secure: secure, config: config, to: target)
                    }
                }
            case .renewed(let token):
                SessionCookie.write(config.cookieName, value: token, maxAge: config.maxAge, secure: secure, config: config, to: target)
            case .cleared:
                SessionCookie.clear(config.cookieName, secure: secure, config: config, to: target)
                if companion.isPresent {
                    SessionCookie.clear(config.expiryCookieName, secure: secure, config: config, to: target)
                }
        }
        return target
    }

    /// A new HttpResponse with the same status, headers, body and upgrade hook.
    static func copy(of response: HttpResponse) -> HttpResponse {
        return response.copy()
    }
}

/// A log line written at most once per instance, whichever request threads trigger it.
/// WSwiftServer uses one to warn the first time a session ends while no `onSessionEnded`
/// handler is registered.
internal final class SessionNotice: @unchecked Sendable {

    private let lock = NSLock()
    private var logged = false
    let message: String

    init(_ message: String) {
        self.message = message
    }

    /// Logs the message (to standard error) the first time it is called. Returns true for the call that logged it.
    @discardableResult
    func log() -> Bool {
        lock.lock()
        let first = logged == false
        logged = true
        lock.unlock()
        if first {
            WSwiftUIDiagnostics.log(message)
        }
        return first
    }

    var hasLogged: Bool {
        lock.lock()
        defer { lock.unlock() }
        return logged
    }
}
