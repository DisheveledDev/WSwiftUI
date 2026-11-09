//
//  Phase1SessionReviewTests.swift
//  WSwiftUITests
//
//  Phase 1 / session, review fixes: renewal on 403/404 answers of an accepted
//  cookie session, Secure on cleared cookies behind a TLS proxy, a publicBaseURL
//  without a scheme, the one-time warning when no onSessionEnded handler is
//  registered, SameSite.noRestriction, and the credential source on the
//  dispatched endpoint. Endpoints and helpers are shared with Phase1SessionTests.swift.
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Endpoints

/// An authenticated page the test user ("user" role) may not view: 403.
final class P1SessionForbiddenPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "p1-forbidden"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.authenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { ["admin"] }
    override func content() -> Any? { webpage { } }
}

/// An authenticated API the test user may not call: 403.
final class P1SessionForbiddenApi: CoreWebEndpoint, WebEndpoint, WebApiEndpoint {
    var controller: String? = "p1-forbidden-api"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.authenticated]
    func acceptedRoles() -> [String]? { ["admin"] }
    func call() -> Any? { P1SessionPayload(ok: true) }
}

/// An authenticated page whose content() and persist() find nothing: 404.
final class P1SessionMissingPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "p1-missing"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.authenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }
    override func content() -> Any? { nil }
    override func persist() -> Any? { nil }
}

/// Answers with where the request's credential came from (`sessionContext.credential?.source`).
final class P1SessionSourceProbe: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "p1-source"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }
    override func content() -> Any? {
        let source = sessionContext.credential.map { "\($0.source)" } ?? "nil"
        return HttpResponse().status(.ok).content(.text).body("\(source) \(authenticationIdentifier ?? "-")")
    }
}

enum P1SessionReview {
    /// P1Session.server() plus the endpoints above.
    static func server(publicBaseURL: String? = nil) -> WSwiftServer {
        let server = P1Session.server(publicBaseURL: publicBaseURL)
        server.register(P1SessionForbiddenPage())
        server.register(P1SessionForbiddenApi())
        server.register(P1SessionMissingPage())
        server.register(P1SessionSourceProbe())
        return server
    }
}

// MARK: - 403 / 404 on an accepted cookie session

@Suite("Phase 1 session review: 403 and 404 answers")
struct P1SessionErrorAnswerTests {

    @Test func forbiddenPageRenewsAnAcceptedCookieSession() {
        let response = P1Session.get(P1SessionReview.server(), "/p1-forbidden", cookie: "auth=good-1")
        #expect(response.status.code == 403)
        // the token was accepted (the user is signed in, just not allowed here), so the session slides
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "good-1")])
    }

    @Test func forbiddenPersistAndApiRenewToo() {
        let server = P1SessionReview.server()
        let post = P1Session.get(server, "/p1-forbidden", cookie: "auth=good-1", method: .POST)
        #expect(post.status.code == 403)
        #expect(P1Session.setCookies(post) == [P1Session.set("auth", "good-1")])

        let api = P1Session.get(server, "/p1-forbidden-api", cookie: "auth=good-2")
        #expect(api.status.code == 403)
        #expect(P1Session.setCookies(api) == [P1Session.set("auth", "good-2")])
    }

    @Test func notFoundRenewsAnAcceptedCookieSession() {
        let server = P1SessionReview.server()
        let get = P1Session.get(server, "/p1-missing", cookie: "auth=good-1")
        #expect(get.status.code == 404)
        #expect(P1Session.setCookies(get) == [P1Session.set("auth", "good-1")])

        let post = P1Session.get(server, "/p1-missing", cookie: "auth=good-1", method: .POST)
        #expect(post.status.code == 404)
        #expect(P1Session.setCookies(post) == [P1Session.set("auth", "good-1")])
    }

    @Test func errorAnswersFollowTheOtherSessionRules() {
        let server = P1SessionReview.server()
        // an explicit expiry is neither shortened nor extended
        let future = P1Session.unixSeconds(Date() + 86400 * 30)
        for uri in ["/p1-forbidden", "/p1-missing"] {
            let response = P1Session.get(server, uri, cookie: "auth=good-1; auth_exp=\(future)")
            #expect(response.status.code == (uri == "/p1-forbidden" ? 403 : 404), "\(uri)")
            #expect(P1Session.setCookies(response).isEmpty, "\(uri)")
        }
        // a past expiry ends the cookie
        let past = P1Session.unixSeconds(Date() - 60)
        let expired = P1Session.get(server, "/p1-forbidden", cookie: "auth=good-1; auth_exp=\(past)")
        #expect(expired.status.code == 403)
        #expect(P1Session.setCookies(expired) == [P1Session.cleared("auth"), P1Session.cleared("auth_exp")])
        // Bearer never gets a cookie
        let bearer = P1Session.get(server, "/p1-missing", headers: [("Authorization", "Bearer good-2")])
        #expect(bearer.status.code == 404)
        #expect(P1Session.setCookies(bearer).isEmpty)
        // a rejected cookie never reaches the 403: it is redirected and cleared
        let rejected = P1Session.get(server, "/p1-forbidden", cookie: "auth=revoked")
        #expect(rejected.status.code == 302)
        #expect(P1Session.setCookies(rejected) == [P1Session.cleared("auth")])
    }
}

// MARK: - Secure behind a TLS proxy

@Suite("Phase 1 session review: Secure on every cookie behind https")
struct P1SessionProxySecureTests {

    static let proxies: [(String, String)] = [("X-Forwarded-Proto", "https"),
                                              ("Forwarded", "for=192.0.2.60;proto=https")]

    @Test func logoutBehindAProxyClearsBothCookiesWithSecure() {
        let server = P1SessionReview.server()
        let future = P1Session.unixSeconds(Date() + 86400)
        for proxy in P1SessionProxySecureTests.proxies {
            let response = P1Session.get(server, "/p1-private?do=logout&respond=redirect",
                                         cookie: "auth=good-1; auth_exp=\(future)", headers: [proxy], method: .POST)
            #expect(response.status.code == 302, "\(proxy)")
            #expect(P1Session.setCookies(response) == [P1Session.cleared("auth", secure: true),
                                                       P1Session.cleared("auth_exp", secure: true)], "\(proxy)")
        }
    }

    @Test func rejectionAndExpiryBehindAProxyClearWithSecure() {
        let server = P1SessionReview.server()
        let past = P1Session.unixSeconds(Date() - 60)
        for proxy in P1SessionProxySecureTests.proxies {
            let rejected = P1Session.get(server, "/p1-private", cookie: "auth=revoked; auth_exp=99999999999", headers: [proxy])
            #expect(rejected.status.code == 302, "\(proxy)")
            #expect(P1Session.setCookies(rejected) == [P1Session.cleared("auth", secure: true),
                                                       P1Session.cleared("auth_exp", secure: true)], "\(proxy)")

            let expired = P1Session.get(server, "/p1-private", cookie: "auth=good-1; auth_exp=\(past)", headers: [proxy])
            #expect(P1Session.setCookies(expired) == [P1Session.cleared("auth", secure: true),
                                                      P1Session.cleared("auth_exp", secure: true)], "\(proxy)")
        }
    }

    @Test func renewalAndLoginBehindAProxyAreSecure() throws {
        let server = P1SessionReview.server()
        for proxy in P1SessionProxySecureTests.proxies {
            let renewal = P1Session.get(server, "/p1-forbidden", cookie: "auth=good-1", headers: [proxy])
            #expect(renewal.status.code == 403)
            #expect(P1Session.setCookies(renewal) == [P1Session.set("auth", "good-1", secure: true)], "\(proxy)")

            let login = P1Session.get(server, "/p1-public?do=login30d", headers: [proxy])
            let auth = try #require(P1Session.cookie("auth", in: login))
            let companion = try #require(P1Session.cookie("auth_exp", in: login))
            #expect(auth.secure && companion.secure, "\(proxy)")
        }
    }
}

// MARK: - publicBaseURL without a scheme

@Suite("Phase 1 session review: publicBaseURL scheme")
struct P1SessionBaseURLSchemeTests {

    @Test func aBaseURLWithoutASchemeDoesNotMakeCookiesSecure() {
        let server = P1SessionReview.server(publicBaseURL: "myhost.lan:8080")
        // canonical URLs are unchanged: a value without a scheme is still normalized to https
        #expect(server.publicBaseURL == "https://myhost.lan:8080")
        let login = P1Session.get(server, "/p1-public?do=login")
        #expect(P1Session.setCookies(login) == [P1Session.set("auth", "tok-new")])
        let logout = P1Session.get(server, "/p1-private?do=logout", cookie: "auth=good-1")
        #expect(P1Session.setCookies(logout) == [P1Session.cleared("auth")])
    }

    @Test func aBaseURLWithoutASchemeBehindAnHTTPSProxyIsSecure() {
        let server = P1SessionReview.server(publicBaseURL: "myhost.lan")
        let login = P1Session.get(server, "/p1-public?do=login", headers: [("X-Forwarded-Proto", "https")])
        #expect(P1Session.setCookies(login) == [P1Session.set("auth", "tok-new", secure: true)])
    }

    @Test func anExplicitSchemeStillDecides() {
        for (base, secure) in [("https://example.com", true), ("HTTPS://EXAMPLE.COM/", true), ("  https://example.com", true),
                               ("http://example.com", false), ("localhost:4242", false)] {
            let server = P1SessionReview.server(publicBaseURL: base)
            let login = P1Session.get(server, "/p1-public?do=login")
            #expect(P1Session.setCookies(login) == [P1Session.set("auth", "tok-new", secure: secure)], "\(base)")
        }
    }

    @Test func assigningPublicBaseURLLaterIsHonoured() {
        let server = P1SessionReview.server(publicBaseURL: "http://example.com")
        server.publicBaseURL = "https://example.com"
        #expect(P1Session.setCookies(P1Session.get(server, "/p1-public?do=login")) == [P1Session.set("auth", "tok-new", secure: true)])
        server.publicBaseURL = "http://example.com"
        #expect(P1Session.setCookies(P1Session.get(server, "/p1-public?do=login")) == [P1Session.set("auth", "tok-new")])
        server.publicBaseURL = "example.com"
        #expect(P1Session.setCookies(P1Session.get(server, "/p1-public?do=login")) == [P1Session.set("auth", "tok-new")])
        server.publicBaseURL = nil
        #expect(P1Session.setCookies(P1Session.get(server, "/p1-public?do=login")) == [P1Session.set("auth", "tok-new")])
    }

    @Test func declaresHTTPS() {
        #expect(SessionCookie.declaresHTTPS("https://a"))
        #expect(SessionCookie.declaresHTTPS("Https://a"))
        #expect(SessionCookie.declaresHTTPS("\n https://a"))
        #expect(SessionCookie.declaresHTTPS(nil) == false)
        #expect(SessionCookie.declaresHTTPS("") == false)
        #expect(SessionCookie.declaresHTTPS("a") == false)
        #expect(SessionCookie.declaresHTTPS("http://a") == false)
        #expect(SessionCookie.declaresHTTPS("https:/a") == false)
        #expect(SessionCookie.declaresHTTPS("x https://a") == false)
    }
}

// MARK: - Warning when no onSessionEnded handler is registered

@Suite("Phase 1 session review: onSessionEnded warning")
struct P1SessionEndedNoticeTests {

    @Test func logoutWithoutAHandlerWarnsOnce() {
        let server = P1SessionReview.server()
        #expect(server.sessionEndedNotice.hasLogged == false)
        let response = P1Session.get(server, "/p1-private?do=logout&respond=redirect", cookie: "auth=good-1", method: .POST)
        // the logout itself is unaffected
        #expect(P1Session.setCookies(response) == [P1Session.cleared("auth")])
        #expect(server.sessionEndedNotice.hasLogged)
        // later logouts do not log again
        _ = P1Session.get(server, "/p1-private?do=logout", cookie: "auth=good-2")
        #expect(server.sessionEndedNotice.log() == false)
    }

    @Test func noWarningWithAHandler() {
        let (server, ended) = P1Session.serverRecordingEnds()
        _ = P1Session.get(server, "/p1-private?do=logout", cookie: "auth=good-1")
        #expect(ended.all == ["good-1"])
        #expect(server.sessionEndedNotice.hasLogged == false)
    }

    @Test func noWarningWhenNoTokenEnds() {
        let server = P1SessionReview.server()
        _ = P1Session.get(server, "/p1-public?do=logout")              // anonymous logout
        _ = P1Session.get(server, "/p1-private", cookie: "auth=revoked") // rejection is not a logout
        _ = P1Session.get(server, "/p1-private", cookie: "auth=good-1")  // renewal
        #expect(server.sessionEndedNotice.hasLogged == false)
    }

    @Test func noticeLogsExactlyOnceAcrossThreads() {
        let notice = SessionNotice("[WSwiftUI test] SessionNotice concurrency probe")
        let firsts = P1EndedTokens()
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if notice.log() { firsts.append("\(index)") }
        }
        #expect(firsts.all.count == 1)
        #expect(notice.hasLogged)
    }
}

// MARK: - SameSite and the credential source

@Suite("Phase 1 session review: API details")
struct P1SessionAPIDetailTests {

    @Test func sameSiteNoRestrictionIsNoneOnTheWire() {
        #expect(WebSessionConfig.SameSite.noRestriction.rawValue == "None")
        #expect(WebSessionConfig.SameSite(rawValue: "None") == .noRestriction)
        // unambiguous where an optional is expected
        let optional: WebSessionConfig.SameSite? = .noRestriction
        #expect(optional != nil)

        let server = P1Session.server(config: WebSessionConfig(secure: .never, sameSite: .noRestriction))
        #expect(P1Session.setCookies(P1Session.get(server, "/p1-public?do=login"))
                == ["auth=tok-new; Path=/; Max-Age=3600; HttpOnly; SameSite=None"])
    }

    @Test func dispatchedEndpointKnowsWhereItsTokenCameFrom() {
        let server = P1SessionReview.server()
        server.acceptQueryToken = true
        #expect(P1Session.get(server, "/p1-source").bodyString == "nil -")
        #expect(P1Session.get(server, "/p1-source", cookie: "auth=c1").bodyString == "cookie c1")
        #expect(P1Session.get(server, "/p1-source", headers: [("Authorization", "Bearer b1")]).bodyString == "bearerHeader b1")
        #expect(P1Session.get(server, "/p1-source?token=q1", cookie: "auth=c1").bodyString == "queryParameter q1")
        #expect(P1Session.get(server, "/p1-source", cookie: "auth=c1",
                              headers: [("Authorization", "Basic dXNlcjpwYXNz")]).bodyString == "cookie c1")
    }
}
