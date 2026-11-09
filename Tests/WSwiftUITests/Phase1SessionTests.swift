//
//  Phase1SessionTests.swift
//  WSwiftUITests
//
//  Phase 1 / session (H1, M4, M5): the session cookie lifecycle through the real
//  dispatch path: login with and without expiry, sliding renewal, logout, anonymous
//  and Bearer requests, Basic auth in front of a cookie session, custom responses,
//  redirects, the auth-failure 302 and the Secure attribute.
//
//  Everything here uses only API that existed before Phase 1, so these tests also
//  run (and fail) against the Phase 0 code. Tests of the new API are in
//  Phase1SessionConfigTests.swift.
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Endpoints

/// Runs the session actions named in `?do=` (comma-separated, in order) and answers as `?respond=` says.
///
/// Actions: `login` (authenticateSession without expiry), `login30d`, `login1d`, `loginPast`
/// (expiry in the past), `logout` (deauthenticateSession), `loginOther` (a second token).
/// Responses: `page` (default, a rendered page), `redirect` (redirect("/next")), `custom` (a
/// hand-built HttpResponse), `rawRedirect` (HttpResponse().redirect(to:)), `json` (a Codable),
/// `redirectFirst` (redirect() built before the actions run), `appCookie` (a custom response that
/// sets the session cookie itself), `shared` (one static HttpResponse returned to everyone).
class P1SessionActionPage: CoreWebEndpoint {

    static let shared = HttpResponse().status(.ok).content(.text).body("shared")

    func perform() -> Any? {
        let query = request.head.queryParams
        let respond = query["respond"] ?? "page"
        let early = respond == "redirectFirst" ? redirect("/early") : nil
        for action in (query["do"] ?? "").split(separator: ",") {
            switch action {
                case "login":     authenticateSession(token: "tok-new")
                case "loginOther": authenticateSession(token: "tok-other")
                case "login30d":  authenticateSession(token: "tok-new", expiry: Date() + 86400 * 30)
                case "login1d":   authenticateSession(token: "tok-new", expiry: Date() + 86400)
                case "loginPast": authenticateSession(token: "tok-new", expiry: Date() - 60)
                case "logout":    deauthenticateSession()
                default:          break
            }
        }
        switch respond {
            case "redirect":      return redirect("/next")
            case "redirectFirst": return early
            case "custom":        return HttpResponse().status(.ok).content(.text).body("custom")
            case "rawRedirect":   return HttpResponse().redirect(to: "/home")
            case "json":          return P1SessionPayload(ok: true)
            case "appCookie":     return HttpResponse().body("own").setCookie(name: "auth", value: "app-chosen")
            case "shared":        return P1SessionActionPage.shared
            default:              return webpage { }
        }
    }

    override func content() -> Any? { perform() }
    override func persist() -> Any? { perform() }
}

final class P1SessionPublicPage: P1SessionActionPage, WebEndpoint, WebContent {
    var controller: String? = "p1-public"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }
}

final class P1SessionPrivatePage: P1SessionActionPage, WebEndpoint, WebContent {
    var controller: String? = "p1-private"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.authenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }
}

struct P1SessionPayload: Codable { var ok: Bool }

/// An authenticated JSON API: `?do=` as above, `?respond=custom` for a hand-built response.
final class P1SessionApi: CoreWebEndpoint, WebEndpoint, WebApiEndpoint {
    var controller: String? = "p1-api"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.authenticated]
    func acceptedRoles() -> [String]? { nil }
    func call() -> Any? {
        let query = request.head.queryParams
        for action in (query["do"] ?? "").split(separator: ",") {
            if action == "login" { authenticateSession(token: "tok-new") }
            if action == "logout" { deauthenticateSession() }
        }
        if query["respond"] == "custom" {
            return HttpResponse().status(.created).content(.text).body("made")
        }
        return P1SessionPayload(ok: true)
    }
}

// MARK: - Helpers

enum P1Session {

    /// Tokens the test onGetUserRoles accepts.
    static let validTokens: Set<String> = ["good-1", "good-2", "tok-new"]

    static func server(publicBaseURL: String? = nil) -> WSwiftServer {
        let server = TestHTTP.server(publicBaseURL: publicBaseURL)
        server.register(P1SessionPublicPage())
        server.register(P1SessionPrivatePage())
        server.register(P1SessionApi())
        server.onGetUserRoles { token, _ in
            guard let token else { return nil }
            return validTokens.contains(token) ? ["user"] : []
        }
        return server
    }

    static func get(_ server: WSwiftServer, _ uri: String, cookie: String? = nil,
                    headers: [(String, String)] = [], method: HttpMethod = .GET) -> HttpResponse {
        var all = headers
        if let cookie { all.append(("Cookie", cookie)) }
        return server.respond(to: TestHTTP.request(method, uri, headers: all))
    }

    static func setCookies(_ response: HttpResponse) -> [String] {
        return response.allHeaders(named: "Set-Cookie")
    }

    static func set(_ name: String, _ value: String, maxAge: Int = 3600, secure: Bool = false) -> String {
        return "\(name)=\(value); Path=/; Max-Age=\(maxAge); HttpOnly;\(secure ? " Secure;" : "") SameSite=Lax"
    }

    static func cleared(_ name: String, secure: Bool = false) -> String {
        return "\(name)=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly;\(secure ? " Secure;" : "") SameSite=Lax"
    }

    /// A parsed Set-Cookie header.
    struct Cookie {
        let name: String
        let value: String
        let attributes: [String: String]
        var maxAge: Int? { attributes["max-age"].flatMap { Int($0) } }
        var secure: Bool { attributes["secure"] != nil }

        init?(_ header: String) {
            let parts = header.components(separatedBy: "; ")
            guard let first = parts.first, let eq = first.firstIndex(of: "=") else { return nil }
            name = String(first[..<eq])
            value = String(first[first.index(after: eq)...])
            var attributes: [String: String] = [:]
            for part in parts.dropFirst() {
                let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                attributes[kv[0].lowercased()] = kv.count == 2 ? kv[1] : ""
            }
            self.attributes = attributes
        }
    }

    static func cookie(_ name: String, in response: HttpResponse) -> Cookie? {
        return setCookies(response).compactMap(Cookie.init).first(where: { $0.name == name })
    }

    static func unixSeconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }
}

// MARK: - Login

@Suite("Phase 1 session: login")
struct P1SessionLoginTests {

    @Test func loginWithoutExpiryLastsMaxAge() {
        let response = P1Session.get(P1Session.server(), "/p1-public?do=login")
        #expect(response.status.code == 200)
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "tok-new")])
    }

    @Test func loginWithExpiryUsesItsLifetimeAndWritesTheCompanion() throws {
        let before = Date()
        let response = P1Session.get(P1Session.server(), "/p1-public?do=login30d")
        let thirtyDays = 86400 * 30
        #expect(P1Session.setCookies(response).count == 2)

        let auth = try #require(P1Session.cookie("auth", in: response))
        #expect(auth.value == "tok-new")
        let lifetime = try #require(auth.maxAge)
        #expect(lifetime <= thirtyDays && lifetime >= thirtyDays - 5, "Max-Age \(lifetime)")
        #expect(auth.attributes["httponly"] != nil)
        #expect(auth.attributes["path"] == "/")
        #expect(auth.attributes["samesite"] == "Lax")

        let companion = try #require(P1Session.cookie("auth_exp", in: response))
        #expect(companion.maxAge == lifetime)
        #expect(companion.attributes["httponly"] != nil)
        let expiresAt = try #require(Int(companion.value))
        let expected = P1Session.unixSeconds(before) + thirtyDays
        #expect(abs(expiresAt - expected) <= 5, "companion \(expiresAt) vs \(expected)")
    }

    @Test func loginWithAPastExpiryExpiresAtOnce() {
        let response = P1Session.get(P1Session.server(), "/p1-public?do=loginPast")
        #expect(P1Session.cookie("auth", in: response)?.maxAge == 0)
        #expect(P1Session.cookie("auth_exp", in: response)?.maxAge == 0)
    }

    @Test func loginWithoutExpiryClearsAStaleCompanion() {
        let stale = P1Session.unixSeconds(Date() + 86400 * 10)
        let response = P1Session.get(P1Session.server(), "/p1-public?do=login", cookie: "auth_exp=\(stale)")
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "tok-new"), P1Session.cleared("auth_exp")])
    }

    @Test func loginReplacesTheRequestToken() {
        let response = P1Session.get(P1Session.server(), "/p1-private?do=login", cookie: "auth=good-1")
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "tok-new")])
    }
}

// MARK: - Renewal

@Suite("Phase 1 session: renewal")
struct P1SessionRenewalTests {

    @Test func acceptedCookieSlidesWithoutAnExpiry() {
        let response = P1Session.get(P1Session.server(), "/p1-private", cookie: "auth=good-1")
        #expect(response.status.code == 200)
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "good-1")])
    }

    @Test func thirtyDaySessionIsNotShortened() {
        let expiry = P1Session.unixSeconds(Date() + 86400 * 30)
        let response = P1Session.get(P1Session.server(), "/p1-private", cookie: "auth=good-1; auth_exp=\(expiry)")
        #expect(response.status.code == 200)
        #expect(P1Session.setCookies(response).isEmpty)
    }

    @Test func oneDaySessionIsNotExtendedOrShortenedOnJSON() {
        let expiry = P1Session.unixSeconds(Date() + 86400)
        let response = P1Session.get(P1Session.server(), "/p1-api", cookie: "auth=good-1; auth_exp=\(expiry)")
        #expect(response.status.code == 200)
        #expect(P1Session.setCookies(response).isEmpty)
    }

    @Test func pastExpiryCompanionEndsTheCookie() {
        let expiry = P1Session.unixSeconds(Date() - 120)
        let response = P1Session.get(P1Session.server(), "/p1-private", cookie: "auth=good-1; auth_exp=\(expiry)")
        // the app accepted the token, so this request is served; the cookie is not extended past its expiry
        #expect(response.status.code == 200)
        #expect(P1Session.setCookies(response) == [P1Session.cleared("auth"), P1Session.cleared("auth_exp")])
    }

    @Test func malformedCompanionIsIgnored() {
        for value in ["abc", "-5", "1e9", "", "12345678901234"] {
            let response = P1Session.get(P1Session.server(), "/p1-private", cookie: "auth=good-1; auth_exp=\(value)")
            #expect(P1Session.setCookies(response) == [P1Session.set("auth", "good-1")], "\(value)")
        }
    }

    @Test func jsonFromAnAuthenticatedApiSlides() {
        let response = P1Session.get(P1Session.server(), "/p1-api", cookie: "auth=good-2")
        #expect(response.header(named: "Content-Type") == "application/json; charset=utf-8")
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "good-2")])
    }
}

// MARK: - Logout

@Suite("Phase 1 session: logout")
struct P1SessionLogoutTests {

    @Test func logoutRedirectClearsTheCookieAndTheCompanion() {
        // AppGrill SignOutPage: persist() { deauthenticateSession(); return redirect(LoginPage().path) }
        let expiry = P1Session.unixSeconds(Date() + 86400)
        let response = P1Session.get(P1Session.server(), "/p1-private?do=logout&respond=redirect",
                                     cookie: "auth=good-1; auth_exp=\(expiry)", method: .POST)
        #expect(response.status.code == 302)
        #expect(response.header(named: "Location") == "/next")
        #expect(P1Session.setCookies(response) == [P1Session.cleared("auth"), P1Session.cleared("auth_exp")])
        #expect(response.headers.contains(where: { $0.1.contains("good-1") }) == false)
    }

    @Test func logoutIsNotUndoneByRenewalOnAnAuthenticatedPage() {
        let response = P1Session.get(P1Session.server(), "/p1-private?do=logout", cookie: "auth=good-1")
        #expect(response.status.code == 200)
        #expect(P1Session.setCookies(response) == [P1Session.cleared("auth")])
    }

    @Test func logoutOnAPublicPageClearsTheCookie() {
        let response = P1Session.get(P1Session.server(), "/p1-public?do=logout", cookie: "auth=good-1")
        #expect(P1Session.setCookies(response) == [P1Session.cleared("auth")])
    }

    @Test func logoutFromAnApiCallClearsTheCookie() {
        let response = P1Session.get(P1Session.server(), "/p1-api?do=logout", cookie: "auth=good-1")
        #expect(response.status.code == 200)
        #expect(P1Session.setCookies(response) == [P1Session.cleared("auth")])
    }

    @Test func redirectBuiltBeforeLogoutStillClears() {
        let response = P1Session.get(P1Session.server(), "/p1-private?do=logout&respond=redirectFirst", cookie: "auth=good-1")
        #expect(response.header(named: "Location") == "/early")
        #expect(P1Session.setCookies(response) == [P1Session.cleared("auth")])
    }

    @Test func lastCallWinsBetweenLoginAndLogout() {
        let server = P1Session.server()
        let loginThenLogout = P1Session.get(server, "/p1-public?do=login,logout")
        #expect(P1Session.setCookies(loginThenLogout) == [P1Session.cleared("auth")])

        let logoutThenLogin = P1Session.get(server, "/p1-private?do=logout,loginOther", cookie: "auth=good-1")
        #expect(P1Session.setCookies(logoutThenLogin) == [P1Session.set("auth", "tok-other")])
    }
}

// MARK: - Who gets a cookie

@Suite("Phase 1 session: no cookie unless the session changes")
struct P1SessionNoCookieTests {

    @Test func anonymousPublicPageGetsNoCookie() {
        let server = P1Session.server()
        for respond in ["page", "redirect", "custom", "json"] {
            let response = P1Session.get(server, "/p1-public?respond=\(respond)")
            #expect(P1Session.setCookies(response).isEmpty, "\(respond)")
        }
    }

    @Test func publicPageNeitherRenewsNorClearsAnUnvalidatedCookie() {
        let server = P1Session.server()
        for cookie in ["auth=good-1", "auth=not-a-session", "auth=good-1; auth_exp=1"] {
            let response = P1Session.get(server, "/p1-public", cookie: cookie)
            #expect(P1Session.setCookies(response).isEmpty, "\(cookie)")
        }
    }

    @Test func anonymousRequestToAnAuthenticatedPageGetsNoCookie() {
        let response = P1Session.get(P1Session.server(), "/p1-private")
        #expect(response.status.code == 302)
        #expect(P1Session.setCookies(response).isEmpty)
    }

    @Test func emptyCookieIsNoToken() {
        let response = P1Session.get(P1Session.server(), "/p1-private", cookie: "auth=")
        #expect(response.status.code == 302)
        #expect(P1Session.setCookies(response).isEmpty)
    }

    @Test func bearerRequestsNeverGetACookie() {
        let server = P1Session.server()
        let page = P1Session.get(server, "/p1-private", headers: [("Authorization", "Bearer good-2")])
        #expect(page.status.code == 200)
        #expect(P1Session.setCookies(page).isEmpty)

        let api = P1Session.get(server, "/p1-api", headers: [("Authorization", "Bearer good-2")])
        #expect(api.status.code == 200)
        #expect(P1Session.setCookies(api).isEmpty)

        // a Bearer header next to a cookie authenticates with the header and leaves the cookie alone
        let both = P1Session.get(server, "/p1-private", cookie: "auth=good-1", headers: [("Authorization", "Bearer good-2")])
        #expect(both.status.code == 200)
        #expect(P1Session.setCookies(both).isEmpty)
    }

    @Test func rejectedBearerDoesNotTouchTheCookie() {
        let response = P1Session.get(P1Session.server(), "/p1-private", cookie: "auth=good-1",
                                     headers: [("Authorization", "Bearer revoked")])
        #expect(response.status.code == 302)
        #expect(P1Session.setCookies(response).isEmpty)
    }
}

// MARK: - Basic auth in front of the app (M5)

@Suite("Phase 1 session: non-Bearer Authorization")
struct P1SessionBasicAuthTests {

    @Test func basicAuthHeaderFallsThroughToTheCookie() {
        let response = P1Session.get(P1Session.server(), "/p1-private", cookie: "auth=good-1",
                                     headers: [("Authorization", "Basic dXNlcjpwYXNz")])
        #expect(response.status.code == 200)
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "good-1")])
    }

    @Test func otherSchemesAndMalformedBearerFallThrough() {
        let server = P1Session.server()
        for header in ["Digest username=\"u\"", "Negotiate abc", "Bearer", "Bearer a b"] {
            let response = P1Session.get(server, "/p1-private", cookie: "auth=good-1", headers: [("Authorization", header)])
            #expect(response.status.code == 200, "\(header)")
            #expect(P1Session.setCookies(response) == [P1Session.set("auth", "good-1")], "\(header)")
        }
    }

    @Test func basicAuthAloneIsStillAnonymous() {
        let response = P1Session.get(P1Session.server(), "/p1-private", headers: [("Authorization", "Basic dXNlcjpwYXNz")])
        #expect(response.status.code == 302)
        #expect(P1Session.setCookies(response).isEmpty)
    }
}

// MARK: - Every response type gets the session decision

@Suite("Phase 1 session: every response is finalized")
struct P1SessionResponseTypeTests {

    @Test func customResponseFromContentCarriesTheLogin() {
        let response = P1Session.get(P1Session.server(), "/p1-public?do=login&respond=custom")
        #expect(response.bodyString == "custom")
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "tok-new")])
    }

    @Test func customResponseFromPersistCarriesTheLogin() {
        let response = P1Session.get(P1Session.server(), "/p1-public?do=login1d&respond=rawRedirect", method: .POST)
        #expect(response.status.code == 302)
        #expect(response.header(named: "Location") == "/home")
        #expect(P1Session.cookie("auth", in: response)?.value == "tok-new")
        #expect(P1Session.cookie("auth_exp", in: response) != nil)
    }

    @Test func customResponseFromCallCarriesTheSession() {
        let server = P1Session.server()
        let login = P1Session.get(server, "/p1-api?do=login&respond=custom", cookie: "auth=good-1")
        #expect(login.status.code == 201)
        #expect(P1Session.setCookies(login) == [P1Session.set("auth", "tok-new")])

        let renewal = P1Session.get(server, "/p1-api?respond=custom", cookie: "auth=good-1")
        #expect(P1Session.setCookies(renewal) == [P1Session.set("auth", "good-1")])

        let logout = P1Session.get(server, "/p1-api?do=logout&respond=custom", cookie: "auth=good-1")
        #expect(P1Session.setCookies(logout) == [P1Session.cleared("auth")])
    }

    @Test func customResponseKeepsItsRenewal() {
        let response = P1Session.get(P1Session.server(), "/p1-private?respond=custom", cookie: "auth=good-1")
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "good-1")])
    }

    @Test func redirectCarriesTheLogin() {
        let response = P1Session.get(P1Session.server(), "/p1-public?do=login&respond=redirect")
        #expect(response.status.code == 302)
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "tok-new")])
    }

    @Test func jsonCarriesTheLogin() {
        let response = P1Session.get(P1Session.server(), "/p1-public?do=login&respond=json")
        #expect(response.bodyString == "{\"ok\":true}")
        #expect(P1Session.setCookies(response) == [P1Session.set("auth", "tok-new")])
    }

    @Test func authFailureRedirectClearsARejectedCookie() {
        let response = P1Session.get(P1Session.server(), "/p1-private", cookie: "auth=revoked; auth_exp=99999999999")
        #expect(response.status.code == 302)
        #expect(response.header(named: "Location") == "/")
        #expect(P1Session.setCookies(response) == [P1Session.cleared("auth"), P1Session.cleared("auth_exp")])
    }

    @Test func aResponseThatSetsTheSessionCookieItselfIsLeftAlone() {
        let response = P1Session.get(P1Session.server(), "/p1-private?do=login&respond=appCookie", cookie: "auth=good-1")
        #expect(P1Session.setCookies(response) == ["auth=app-chosen; Path=/; HttpOnly; SameSite=Lax"])
    }

    @Test func aSharedResponseIsNeverWrittenTo() {
        let server = P1Session.server()
        let first = P1Session.get(server, "/p1-private?respond=shared", cookie: "auth=good-1")
        let second = P1Session.get(server, "/p1-private?respond=shared", cookie: "auth=good-2")
        #expect(P1Session.setCookies(first) == [P1Session.set("auth", "good-1")])
        #expect(P1Session.setCookies(second) == [P1Session.set("auth", "good-2")])
        #expect(first.bodyString == "shared" && second.bodyString == "shared")
        #expect(P1SessionActionPage.shared.allHeaders(named: "Set-Cookie").isEmpty)
    }
}

// MARK: - Secure

@Suite("Phase 1 session: Secure attribute")
struct P1SessionSecureTests {

    @Test func httpsPublicBaseURLMakesCookiesSecure() {
        let server = P1Session.server(publicBaseURL: "https://example.com")
        let login = P1Session.get(server, "/p1-public?do=login")
        #expect(P1Session.setCookies(login) == [P1Session.set("auth", "tok-new", secure: true)])

        let logout = P1Session.get(server, "/p1-private?do=logout", cookie: "auth=good-1; auth_exp=99999999999")
        #expect(P1Session.setCookies(logout) == [P1Session.cleared("auth", secure: true), P1Session.cleared("auth_exp", secure: true)])

        let renewal = P1Session.get(server, "/p1-private", cookie: "auth=good-1")
        #expect(P1Session.setCookies(renewal) == [P1Session.set("auth", "good-1", secure: true)])

        let rejected = P1Session.get(server, "/p1-private", cookie: "auth=revoked")
        #expect(P1Session.setCookies(rejected) == [P1Session.cleared("auth", secure: true)])
    }

    @Test func forwardedHTTPSMakesCookiesSecure() {
        let server = P1Session.server()
        for header in [("X-Forwarded-Proto", "https"), ("X-Forwarded-Proto", "HTTPS"), ("X-Forwarded-Proto", "https, http"),
                       ("Forwarded", "for=192.0.2.60;proto=https;by=203.0.113.43"), ("Forwarded", "proto=\"https\""),
                       ("forwarded", "For=\"[2001:db8::1]\";Proto=https, for=10.0.0.1;proto=http")] {
            let response = P1Session.get(server, "/p1-public?do=login", headers: [header])
            #expect(P1Session.setCookies(response) == [P1Session.set("auth", "tok-new", secure: true)], "\(header)")
        }
    }

    @Test func plainHTTPIsNotSecure() {
        let server = P1Session.server(publicBaseURL: "http://localhost:4242")
        for headers in [[], [("X-Forwarded-Proto", "http")], [("X-Forwarded-Proto", "http, https")],
                        [("Forwarded", "for=1.2.3.4;proto=http, proto=https")], [("X-Forwarded-Proto", "httpsx")]] {
            let response = P1Session.get(server, "/p1-public?do=login", headers: headers)
            #expect(P1Session.setCookies(response) == [P1Session.set("auth", "tok-new")], "\(headers)")
        }
    }
}
