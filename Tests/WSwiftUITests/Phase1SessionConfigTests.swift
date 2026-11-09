//
//  Phase1SessionConfigTests.swift
//  WSwiftUITests
//
//  Phase 1 / session: the new session API: WSwiftServer.onSessionEnded,
//  WebSessionConfig (Secure policy, SameSite, cookie name, maxAge, sliding,
//  acceptQueryToken) and the internal decision / finalizer helpers.
//  Endpoints and helpers are shared with Phase1SessionTests.swift.
//

import Foundation
import Testing
@testable import WSwiftUI

/// Collects the tokens passed to onSessionEnded (thread-safe).
final class P1EndedTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String] = []
    func append(_ token: String) { lock.lock(); tokens.append(token); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return tokens }
}

extension P1Session {
    static func server(config: WebSessionConfig, publicBaseURL: String? = nil) -> WSwiftServer {
        let server = P1Session.server(publicBaseURL: publicBaseURL)
        server.session = config
        return server
    }

    static func serverRecordingEnds(acceptQueryToken: Bool = false) -> (WSwiftServer, P1EndedTokens) {
        let server = P1Session.server()
        server.acceptQueryToken = acceptQueryToken
        let ended = P1EndedTokens()
        server.onSessionEnded { token in ended.append(token) }
        return (server, ended)
    }
}

// MARK: - onSessionEnded

@Suite("Phase 1 session: onSessionEnded")
struct P1SessionEndedTests {

    @Test func logoutReportsTheRequestTokenOnce() {
        let (server, ended) = P1Session.serverRecordingEnds()
        let response = P1Session.get(server, "/p1-private?do=logout&respond=redirect", cookie: "auth=good-1", method: .POST)
        #expect(response.status.code == 302)
        #expect(ended.all == ["good-1"])
    }

    @Test func repeatedLogoutReportsOnce() {
        let (server, ended) = P1Session.serverRecordingEnds()
        let response = P1Session.get(server, "/p1-private?do=logout,logout,logout", cookie: "auth=good-1")
        #expect(P1Session.setCookies(response) == [P1Session.cleared("auth")])
        #expect(ended.all == ["good-1"])
    }

    @Test func logoutAfterLoginInTheSameRequestEndsTheNewToken() {
        let (server, ended) = P1Session.serverRecordingEnds()
        _ = P1Session.get(server, "/p1-public?do=login,logout")
        #expect(ended.all == ["tok-new"])
    }

    @Test func logoutThenLoginEndsTheOldTokenAndKeepsTheNewOne() {
        let (server, ended) = P1Session.serverRecordingEnds()
        let response = P1Session.get(server, "/p1-private?do=logout,loginOther", cookie: "auth=good-1")
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "tok-other")])
        #expect(ended.all == ["good-1"])
    }

    @Test func logoutWithoutATokenReportsNothing() {
        let (server, ended) = P1Session.serverRecordingEnds()
        let response = P1Session.get(server, "/p1-public?do=logout")
        #expect(P1Session.setCookies(response) == [P1Session.cleared("auth")])
        #expect(ended.all.isEmpty)
    }

    @Test func bearerLogoutReportsTheBearerToken() {
        let (server, ended) = P1Session.serverRecordingEnds()
        _ = P1Session.get(server, "/p1-api?do=logout", headers: [("Authorization", "Bearer good-2")])
        #expect(ended.all == ["good-2"])
    }

    @Test func acceptedQueryTokenLogoutReportsIt() {
        let (server, ended) = P1Session.serverRecordingEnds(acceptQueryToken: true)
        let response = P1Session.get(server, "/p1-private?token=good-2&do=logout", cookie: "auth=good-1")
        // the token in effect, then the cookie's own token, which the response clears
        #expect(ended.all == ["good-2", "good-1"])
        #expect(P1Session.setCookies(response) == [P1Session.cleared("auth")])
    }

    @Test func rejectionAndRenewalReportNothing() {
        let (server, ended) = P1Session.serverRecordingEnds()
        _ = P1Session.get(server, "/p1-private", cookie: "auth=revoked")
        _ = P1Session.get(server, "/p1-private", cookie: "auth=good-1")
        _ = P1Session.get(server, "/p1-private")
        #expect(ended.all.isEmpty)
    }

    @Test func endpointsOutsideDispatchDoNothing() {
        let page = P1SessionPublicPage()
        page.authenticationIdentifier = "x"
        page.deauthenticateSession()
        page.authenticateSession(token: "y")
        #expect(page.redirect("/z").allHeaders(named: "Set-Cookie").isEmpty)
    }
}

// MARK: - WebSessionConfig

@Suite("Phase 1 session: WebSessionConfig")
struct P1SessionConfigTests {

    @Test func defaults() {
        let config = WebSessionConfig()
        #expect(config.cookieName == "auth")
        #expect(config.secure == .auto)
        #expect(config.sameSite == .lax)
        #expect(config.maxAge == 3600)
        #expect(config.sliding == true)
        #expect(config.acceptQueryToken == false)
        #expect(TestHTTP.server().session == config)
    }

    @Test func acceptQueryTokenForwardsToTheConfig() {
        let server = TestHTTP.server()
        server.acceptQueryToken = true
        #expect(server.session.acceptQueryToken == true)
        server.session.acceptQueryToken = false
        #expect(server.acceptQueryToken == false)
        server.session = WebSessionConfig(acceptQueryToken: true)
        #expect(server.acceptQueryToken == true)
    }

    @Test func alwaysSecureOnPlainHTTP() {
        let server = P1Session.server(config: WebSessionConfig(secure: .always), publicBaseURL: "http://localhost")
        let response = P1Session.get(server, "/p1-public?do=login")
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "tok-new", secure: true)])
    }

    @Test func neverSecureEvenBehindHTTPS() {
        let server = P1Session.server(config: WebSessionConfig(secure: .never), publicBaseURL: "https://example.com")
        let response = P1Session.get(server, "/p1-public?do=login", headers: [("X-Forwarded-Proto", "https")])
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "tok-new")])
    }

    @Test func sameSiteStrictAndNone() {
        let strict = P1Session.server(config: WebSessionConfig(sameSite: .strict))
        #expect(P1Session.setCookies(P1Session.get(strict, "/p1-public?do=login"))
                == ["auth=tok-new; Path=/; Max-Age=3600; HttpOnly; SameSite=Strict"])

        // browsers reject SameSite=None without Secure, so .auto adds it
        let none = P1Session.server(config: WebSessionConfig(sameSite: .noRestriction))
        #expect(P1Session.setCookies(P1Session.get(none, "/p1-public?do=login"))
                == ["auth=tok-new; Path=/; Max-Age=3600; HttpOnly; Secure; SameSite=None"])
    }

    @Test func customCookieNameIsReadAndWritten() throws {
        let server = P1Session.server(config: WebSessionConfig(cookieName: "sid"))
        // the default name no longer authenticates
        #expect(P1Session.get(server, "/p1-private", cookie: "auth=good-1").status.code == 302)

        let renewal = P1Session.get(server, "/p1-private", cookie: "auth=good-2; sid=good-1")
        #expect(renewal.status.code == 200)
        #expect(P1Session.setCookies(renewal) == [P1Session.set("sid", "good-1")])

        let login = P1Session.get(server, "/p1-public?do=login30d")
        #expect(P1Session.cookie("sid", in: login)?.value == "tok-new")
        #expect(P1Session.cookie("sid_exp", in: login) != nil)
        #expect(P1Session.cookie("auth", in: login) == nil)

        let expiry = P1Session.unixSeconds(Date() + 3000)
        let fixed = P1Session.get(server, "/p1-private", cookie: "sid=good-1; sid_exp=\(expiry)")
        #expect(P1Session.setCookies(fixed).isEmpty)

        let logout = P1Session.get(server, "/p1-private?do=logout", cookie: "sid=good-1; sid_exp=\(expiry)")
        #expect(P1Session.setCookies(logout) == [P1Session.cleared("sid"), P1Session.cleared("sid_exp")])
    }

    @Test func maxAgeAppliesToLoginAndRenewal() {
        let server = P1Session.server(config: WebSessionConfig(maxAge: 600))
        #expect(P1Session.setCookies(P1Session.get(server, "/p1-public?do=login")) == [P1Session.set("auth", "tok-new", maxAge: 600)])
        #expect(P1Session.setCookies(P1Session.get(server, "/p1-private", cookie: "auth=good-1")) == [P1Session.set("auth", "good-1", maxAge: 600)])

        let negative = P1Session.server(config: WebSessionConfig(maxAge: -10))
        #expect(P1Session.setCookies(P1Session.get(negative, "/p1-public?do=login")) == [P1Session.set("auth", "tok-new", maxAge: 0)])
    }

    @Test func noSlidingMeansNoRenewal() {
        let server = P1Session.server(config: WebSessionConfig(sliding: false))
        #expect(P1Session.setCookies(P1Session.get(server, "/p1-private", cookie: "auth=good-1")).isEmpty)
        // login, logout and rejection still write
        #expect(P1Session.setCookies(P1Session.get(server, "/p1-public?do=login")) == [P1Session.set("auth", "tok-new")])
        #expect(P1Session.setCookies(P1Session.get(server, "/p1-private?do=logout", cookie: "auth=good-1")) == [P1Session.cleared("auth")])
        #expect(P1Session.setCookies(P1Session.get(server, "/p1-private", cookie: "auth=revoked")) == [P1Session.cleared("auth")])
        // a past expiry still ends the cookie
        let past = P1Session.unixSeconds(Date() - 5)
        #expect(P1Session.setCookies(P1Session.get(server, "/p1-private", cookie: "auth=good-1; auth_exp=\(past)"))
                == [P1Session.cleared("auth"), P1Session.cleared("auth_exp")])
    }
}

// MARK: - Internals

@Suite("Phase 1 session: decision and finalizer units")
struct P1SessionUnitTests {

    private func context(_ uri: String = "/", headers: [(String, String)] = [], config: WebSessionConfig = WebSessionConfig(),
                         publicBaseURL: String? = nil, now: Date = Date(timeIntervalSince1970: 1_000_000)) -> SessionRequestContext {
        return SessionRequestContext(request: TestHTTP.request(.GET, uri, headers: headers), config: config,
                                     publicBaseURLIsHTTPS: SessionCookie.declaresHTTPS(publicBaseURL),
                                     onSessionEnded: nil, clock: { now })
    }

    @Test func decisionTable() {
        // anonymous, Bearer and query credentials never change the cookie by themselves
        for (headers, uri) in [([], "/"), ([("Authorization", "Bearer b")], "/"), ([], "/?token=q")] as [([(String, String)], String)] {
            let accepted = context(uri, headers: headers, config: WebSessionConfig(acceptQueryToken: true))
            accepted.credentialAccepted()
            #expect(accepted.decision == .none)
            let rejected = context(uri, headers: headers, config: WebSessionConfig(acceptQueryToken: true))
            rejected.credentialRejected()
            #expect(rejected.decision == .none)
        }

        let cookie = [("Cookie", "auth=c")]
        #expect(context(headers: cookie).decision == .none) // public endpoint: never validated

        let accepted = context(headers: cookie)
        accepted.credentialAccepted()
        #expect(accepted.decision == .renewed(token: "c"))

        let rejected = context(headers: cookie)
        rejected.credentialRejected()
        #expect(rejected.decision == .cleared(token: "c"))

        let future = context(headers: [("Cookie", "auth=c; auth_exp=1000100")])
        future.credentialAccepted()
        #expect(future.decision == .none)

        let past = context(headers: [("Cookie", "auth=c; auth_exp=1000000")])
        past.credentialAccepted()
        #expect(past.decision == .cleared(token: "c"))

        let explicit = context(headers: cookie)
        explicit.credentialAccepted()
        explicit.establish(token: "n", expiry: nil)
        #expect(explicit.decision == .established(token: "n", expiry: nil))
        explicit.end(requestToken: "c")
        #expect(explicit.decision == .cleared(token: "n"))
    }

    @Test func establishedLifetimeIsMeasuredFromNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ctx = context(now: now)
        ctx.establish(token: "t", expiry: now + 90.9)
        let response = ctx.finalize(HttpResponse())
        #expect(response.allHeaders(named: "Set-Cookie") == [
            "auth=t; Path=/; Max-Age=90; HttpOnly; SameSite=Lax",
            "auth_exp=1000090; Path=/; Max-Age=90; HttpOnly; SameSite=Lax",
        ])
    }

    @Test func invalidTokenWritesNoCompanion() {
        let ctx = context()
        ctx.establish(token: "bad token;", expiry: Date(timeIntervalSince1970: 2_000_000))
        #expect(ctx.finalize(HttpResponse()).allHeaders(named: "Set-Cookie").isEmpty)
    }

    @Test func companionParsing() {
        #expect(SessionCookie.Companion(cookieValue: nil) == .absent)
        #expect(SessionCookie.Companion(cookieValue: "1700000000") == .expires(Date(timeIntervalSince1970: 1_700_000_000)))
        for bad in ["", "abc", "-1", "+5", "1.5", " 1", "1e9", "1234567890123", "١٢٣"] {
            #expect(SessionCookie.Companion(cookieValue: bad) == .malformed, "\(bad)")
        }
    }

    @Test func lifetimeClamps() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(SessionCookie.seconds(until: Date(timeIntervalSince1970: -5), from: now) == 0)
        #expect(SessionCookie.seconds(until: Date(timeIntervalSince1970: 59.99), from: now) == 59)
        #expect(SessionCookie.seconds(until: Date.distantFuture, from: now) == SessionCookie.maximumLifetime)
        #expect(SessionCookie.seconds(until: Date(timeIntervalSince1970: .infinity), from: now) == 0)
        #expect(SessionCookie.seconds(until: Date(timeIntervalSince1970: .nan), from: now) == 0)
    }

    @Test func forwardedProtoParsing() {
        func https(_ headers: [(String, String)]) -> Bool { TestHTTP.request(.GET, "/", headers: headers).forwardedProtoIsHTTPS }
        #expect(https([("X-Forwarded-Proto", " https ")]))
        #expect(https([("Forwarded", "proto=https")]))
        #expect(https([("X-Forwarded-Proto", "https"), ("X-Forwarded-Proto", "http")]))
        #expect(https([]) == false)
        #expect(https([("X-Forwarded-Proto", ",https")]) == false)
        #expect(https([("Forwarded", "for=x, proto=https")]) == false)
        #expect(https([("Forwarded", "proto")]) == false)
    }

    @Test func secureDecision() {
        #expect(context(publicBaseURL: "https://a.example").secure)
        #expect(context(publicBaseURL: "HTTPS://A.EXAMPLE").secure)
        #expect(context(publicBaseURL: "http://a.example").secure == false)
        #expect(context(publicBaseURL: " https://a.example/ ").secure)
        // no scheme: normalized to https for canonical URLs, but not proof of https
        #expect(context(publicBaseURL: "a.example:8080").secure == false)
        #expect(context(publicBaseURL: "httpsa.example").secure == false)
        #expect(context(headers: [("X-Forwarded-Proto", "https")]).secure)
        #expect(context(config: WebSessionConfig(secure: .always)).secure)
        #expect(context(config: WebSessionConfig(secure: .never), publicBaseURL: "https://a.example").secure == false)
    }

    @Test func copyKeepsTheWholeResponse() {
        var upgraded = false
        let original = HttpResponse().status(.created).header("X-A", "1").content(.json).body("{}")
        original.onUpgraded = { upgraded = true }
        let copy = SessionRequestContext.copy(of: original)
        #expect(copy !== original)
        #expect(copy.status.code == 201)
        #expect(copy.headers.map { "\($0.0)=\($0.1)" } == original.headers.map { "\($0.0)=\($0.1)" })
        #expect(copy.bodyBytes == original.bodyBytes)
        copy.onUpgraded?()
        #expect(upgraded)

        let file = URL(fileURLWithPath: "/tmp/x.bin")
        let ranged = SessionRequestContext.copy(of: HttpResponse().status(HttpStatus(206, "Partial Content")).body(file, from: 10, to: 20))
        #expect(ranged.bodyFileUrl == file)
        #expect(ranged.bodyFileHandleRange == 10..<20)
        #expect(ranged.status.code == 206)

        let empty = SessionRequestContext.copy(of: HttpResponse().status(.notFound))
        #expect(empty.status.code == 404)
        #expect(empty.headers.isEmpty)
        #expect(empty.bodyBytes.isEmpty)
    }
}

// MARK: - Over a socket

/// One listening server for the socket tests below (ephemeral port).
enum P1SessionSocketFixture {
    nonisolated(unsafe) static let server: WSwiftServer = {
        let server = WSwiftServer(port: 0, publicBaseURL: "https://example.com")
        server.register(P1SessionPublicPage())
        server.register(P1SessionPrivatePage())
        server.onGetUserRoles { token, _ in
            guard let token else { return nil }
            return P1Session.validTokens.contains(token) ? ["user"] : []
        }
        return server
    }()

    /// Reached by reflection, as in HttpSessionFixture.
    static var port: Int? {
        let listener = Mirror(reflecting: server).children.first(where: { $0.label == "svr" })?.value
        guard let http = listener as? HTTPServer, let port = http.boundPort else { return nil }
        return Int(port)
    }
}

@Suite("Phase 1 session: over a socket")
struct P1SessionSocketTests {

    @Test func loginWithExpiryWritesBothCookies() throws {
        let port = try #require(P1SessionSocketFixture.port, "server did not start")
        let response = try HttpSessionSocket.get("/p1-public?do=login1d&respond=redirect", port: port)
        #expect(response.statusCode == 302)
        let cookies = response.values("Set-Cookie")
        #expect(cookies.count == 2)
        #expect(cookies.first?.hasPrefix("auth=tok-new; Path=/; Max-Age=") == true)
        #expect(cookies.last?.hasPrefix("auth_exp=") == true)
        #expect(cookies.allSatisfy { $0.hasSuffix("; HttpOnly; Secure; SameSite=Lax") })
    }

    @Test func logoutClearsBothCookies() throws {
        let port = try #require(P1SessionSocketFixture.port, "server did not start")
        let response = try HttpSessionSocket.send("POST /p1-private?do=logout&respond=redirect HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                                                  + "Cookie: auth=good-1; auth_exp=99999999999\r\nContent-Length: 0\r\n\r\n", port: port)
        #expect(response.statusCode == 302)
        #expect(response.values("Set-Cookie") == [P1Session.cleared("auth", secure: true), P1Session.cleared("auth_exp", secure: true)])
    }

    @Test func anonymousPageHasNoCookie() throws {
        let port = try #require(P1SessionSocketFixture.port, "server did not start")
        let response = try HttpSessionSocket.get("/p1-public", port: port)
        #expect(response.statusCode == 200)
        #expect(response.values("Set-Cookie").isEmpty)
    }
}
