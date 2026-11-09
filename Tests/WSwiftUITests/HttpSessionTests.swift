//
//  HttpSessionTests.swift
//  WSwiftUITests
//
//  C1: response splitting / header injection / cookie fixation through ?token=,
//  and the session cookie (re)issue rules.
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Endpoints

final class HttpSessionProbePage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "session-probe"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }
    override func content() -> Any? { webpage { } }
}

final class HttpSessionPrivatePage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "session-private"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.authenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }
    override func content() -> Any? { webpage { } }
}

final class HttpSessionLoginPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "session-login"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }
    override func content() -> Any? {
        authenticateSession(token: "fresh-token-123")
        return webpage { }
    }
}

final class HttpSessionRedirectPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "session-redirect"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }
    override func content() -> Any? { redirect("/next") }
}

final class HttpSessionLoginRedirectPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "session-login-redirect"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }
    override func content() -> Any? {
        authenticateSession(token: "fresh-token-456")
        return redirect("/dashboard")
    }
}

struct HttpSessionPayload: Codable { var ok: Bool }

final class HttpSessionJSONApi: CoreWebEndpoint, WebEndpoint, WebApiEndpoint {
    var controller: String? = "session-json"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func call() -> Any? { HttpSessionPayload(ok: true) }
    func acceptedRoles() -> [String]? { nil }
}

// MARK: - Helpers

enum HttpSessionHelpers {

    static let anonymousCookie = "auth=; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax"

    static func cookie(_ value: String) -> String {
        return "auth=\(value); Path=/; Max-Age=3600; HttpOnly; SameSite=Lax"
    }

    static func server(acceptQueryToken: Bool = false) -> WSwiftServer {
        let server = TestHTTP.server()
        server.acceptQueryToken = acceptQueryToken
        server.register(HttpSessionProbePage())
        server.register(HttpSessionPrivatePage())
        server.register(HttpSessionLoginPage())
        server.register(HttpSessionRedirectPage())
        server.register(HttpSessionLoginRedirectPage())
        server.register(HttpSessionJSONApi())
        server.onGetUserRoles { token, _ in
            return token == "good-token" ? ["user"] : []
        }
        return server
    }

    /// True when no header name or value holds a CR, LF or NUL byte.
    /// (Checks bytes: String.contains("\r") misses the single "\r\n" Character.)
    static func hasNoLineBreaks(_ response: HttpResponse) -> Bool {
        return response.headers.allSatisfy { name, value in
            !name.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 }) &&
            !value.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 })
        }
    }

    static let crlfToken = "abc%0D%0AX-Injected:%20yes%0D%0ASet-Cookie:%20evil=1"
}

// MARK: - ?token= handling

@Suite("HTTP session: query token")
struct HttpSessionQueryTokenTests {

    @Test func crlfQueryTokenIsIgnoredByDefault() {
        let server = HttpSessionHelpers.server()
        let response = server.respond(to: TestHTTP.request(.GET, "/session-probe?token=\(HttpSessionHelpers.crlfToken)"))
        #expect(response.status.code == 200)
        #expect(HttpSessionHelpers.hasNoLineBreaks(response))
        #expect(response.header(named: "X-Injected") == nil)
        #expect(response.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.anonymousCookie])
    }

    @Test func queryCookieAttributeInjectionIsIgnoredByDefault() {
        let server = HttpSessionHelpers.server()
        let response = server.respond(to: TestHTTP.request(.GET, "/session-probe?token=abc%3B%20Domain%3Dexample.com%3B%20Max-Age%3D999999999"))
        #expect(response.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.anonymousCookie])
    }

    @Test func queryTokenDoesNotReplaceTheCookieByDefault() {
        let server = HttpSessionHelpers.server()
        let response = server.respond(to: TestHTTP.request(.GET, "/session-probe?token=attacker",
                                                           headers: [("Cookie", "auth=goodtoken")]))
        #expect(response.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.cookie("goodtoken")])
    }

    @Test func emptyQueryTokenDoesNotLogTheUserOut() {
        let server = HttpSessionHelpers.server()
        let response = server.respond(to: TestHTTP.request(.GET, "/session-probe?token",
                                                           headers: [("Cookie", "auth=victim")]))
        #expect(response.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.cookie("victim")])
    }

    @Test func queryTokenDoesNotAuthenticateByDefault() {
        let server = HttpSessionHelpers.server()
        let response = server.respond(to: TestHTTP.request(.GET, "/session-private?token=good-token"))
        #expect(response.status.code == 302)
        #expect(response.header(named: "Location") == "/")
    }

    @Test func acceptedQueryTokenAuthenticatesButIsNeverWrittenToACookie() {
        let server = HttpSessionHelpers.server(acceptQueryToken: true)
        let response = server.respond(to: TestHTTP.request(.GET, "/session-private?token=good-token"))
        #expect(response.status.code == 200)
        #expect(response.allHeaders(named: "Set-Cookie").isEmpty)
        #expect(response.headers.contains(where: { $0.1.contains("good-token") }) == false)
    }

    @Test func acceptedQueryTokenIsNeverReflectedOnPublicPages() {
        let server = HttpSessionHelpers.server(acceptQueryToken: true)
        for uri in ["/session-probe?token=\(HttpSessionHelpers.crlfToken)",
                    "/session-probe?token=attacker-session-123",
                    "/session-json?token=attacker-session-123",
                    "/session-redirect?token=attacker-session-123"] {
            let response = server.respond(to: TestHTTP.request(.GET, uri, headers: [("Cookie", "auth=victim")]))
            #expect(HttpSessionHelpers.hasNoLineBreaks(response), "\(uri)")
            #expect(response.allHeaders(named: "Set-Cookie").isEmpty, "\(uri)")
            #expect(response.header(named: "X-Injected") == nil, "\(uri)")
        }
    }

    @Test func rejectedQueryTokenDoesNotClearTheAuthCookie() {
        let server = HttpSessionHelpers.server(acceptQueryToken: true)
        let response = server.respond(to: TestHTTP.request(.GET, "/session-private?token=bad",
                                                           headers: [("Cookie", "auth=good-token")]))
        #expect(response.status.code == 302)
        #expect(response.allHeaders(named: "Set-Cookie").isEmpty)
    }

    @Test func rejectedCookieTokenStillClearsTheCookie() {
        let server = HttpSessionHelpers.server()
        let response = server.respond(to: TestHTTP.request(.GET, "/session-private",
                                                           headers: [("Cookie", "auth=bad")]))
        #expect(response.status.code == 302)
        let cookies = response.allHeaders(named: "Set-Cookie")
        #expect(cookies.count == 1)
        #expect(cookies.first?.hasPrefix("auth=; Path=/; Max-Age=0; Expires=") == true)
    }
}

// MARK: - Session cookie (re)issue rules

@Suite("HTTP session: cookie issue rules")
struct HttpSessionCookieRuleTests {

    @Test func cookieTokenIsReissued() {
        let server = HttpSessionHelpers.server()
        let response = server.respond(to: TestHTTP.request(.GET, "/session-probe", headers: [("Cookie", "auth=tok-123")]))
        #expect(response.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.cookie("tok-123")])
    }

    @Test func authenticatedCookieTokenIsReissued() {
        let server = HttpSessionHelpers.server()
        let response = server.respond(to: TestHTTP.request(.GET, "/session-private", headers: [("Cookie", "auth=good-token")]))
        #expect(response.status.code == 200)
        #expect(response.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.cookie("good-token")])
    }

    @Test func bearerTokenIsReissuedAsBefore() {
        let server = HttpSessionHelpers.server()
        let response = server.respond(to: TestHTTP.request(.GET, "/session-probe", headers: [("Authorization", "Bearer tok-b")]))
        #expect(response.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.cookie("tok-b")])
    }

    @Test func anonymousRequestKeepsTheEmptyCookie() {
        let server = HttpSessionHelpers.server()
        let response = server.respond(to: TestHTTP.request(.GET, "/session-probe"))
        #expect(response.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.anonymousCookie])
    }

    @Test func authenticateSessionTokenIsIssued() {
        for accept in [false, true] {
            let server = HttpSessionHelpers.server(acceptQueryToken: accept)
            let response = server.respond(to: TestHTTP.request(.GET, "/session-login?token=attacker",
                                                               headers: [("Cookie", "auth=old")]))
            #expect(response.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.cookie("fresh-token-123")])
        }
    }

    @Test func jsonResponsesFollowTheSameRules() {
        let server = HttpSessionHelpers.server()
        let withCookie = server.respond(to: TestHTTP.request(.GET, "/session-json", headers: [("Cookie", "auth=tok-j")]))
        #expect(withCookie.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.cookie("tok-j")])
        let injected = server.respond(to: TestHTTP.request(.GET, "/session-json?token=\(HttpSessionHelpers.crlfToken)"))
        #expect(HttpSessionHelpers.hasNoLineBreaks(injected))
        #expect(injected.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.anonymousCookie])
    }

    @Test func redirectFollowsTheSameRules() {
        let server = HttpSessionHelpers.server()

        let withCookie = server.respond(to: TestHTTP.request(.GET, "/session-redirect", headers: [("Cookie", "auth=tok-r")]))
        #expect(withCookie.status.code == 302)
        #expect(withCookie.header(named: "Location") == "/next")
        #expect(withCookie.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.cookie("tok-r")])

        let injected = server.respond(to: TestHTTP.request(.GET, "/session-redirect?token=\(HttpSessionHelpers.crlfToken)"))
        #expect(HttpSessionHelpers.hasNoLineBreaks(injected))
        #expect(injected.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.anonymousCookie])

        let fixation = server.respond(to: TestHTTP.request(.GET, "/session-redirect?token=attacker",
                                                           headers: [("Cookie", "auth=victim")]))
        #expect(fixation.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.cookie("victim")])

        let login = server.respond(to: TestHTTP.request(.GET, "/session-login-redirect?token=attacker"))
        #expect(login.header(named: "Location") == "/dashboard")
        #expect(login.allHeaders(named: "Set-Cookie") == [HttpSessionHelpers.cookie("fresh-token-456")])
    }

    @Test func lineBreakInsideTheCookieIsNotReflected() {
        let server = HttpSessionHelpers.server()
        let response = server.respond(to: TestHTTP.request(.GET, "/session-probe",
                                                           headers: [("Cookie", "auth=abc\nX-Injected: yes")]))
        #expect(HttpSessionHelpers.hasNoLineBreaks(response))
        #expect(response.allHeaders(named: "Set-Cookie").isEmpty)
    }

    @Test func cookieValueDecision() {
        #expect(SessionCookie.value(newIdentifier: "n", currentIdentifier: "c", source: .queryParameter) == "n")
        #expect(SessionCookie.value(newIdentifier: nil, currentIdentifier: "c", source: .queryParameter) == nil)
        #expect(SessionCookie.value(newIdentifier: nil, currentIdentifier: "c", source: .cookie) == "c")
        #expect(SessionCookie.value(newIdentifier: nil, currentIdentifier: "c", source: .bearerHeader) == "c")
        #expect(SessionCookie.value(newIdentifier: nil, currentIdentifier: nil, source: .none) == "")
    }

    @Test func credentialSources() {
        let bearer = TestHTTP.request(.GET, "/?token=q", headers: [("Authorization", "Bearer b"), ("Cookie", "auth=c")])
        #expect(bearer.authenticationCredential(acceptQueryToken: true) == AuthenticationCredential(token: "b", source: .bearerHeader))

        let query = TestHTTP.request(.GET, "/?token=q", headers: [("Cookie", "auth=c")])
        #expect(query.authenticationCredential(acceptQueryToken: true) == AuthenticationCredential(token: "q", source: .queryParameter))
        #expect(query.authenticationCredential(acceptQueryToken: false) == AuthenticationCredential(token: "c", source: .cookie))

        let none = TestHTTP.request(.GET, "/?token=q")
        #expect(none.authenticationCredential(acceptQueryToken: false) == nil)

        let basic = TestHTTP.request(.GET, "/", headers: [("Authorization", "Basic xyz"), ("Cookie", "auth=c")])
        #expect(basic.authenticationCredential(acceptQueryToken: false) == nil)
    }
}

// MARK: - HttpResponse header / cookie hygiene

@Suite("HTTP session: response header hygiene")
struct HttpSessionHeaderHygieneTests {

    @Test func headerDropsLineBreaksAndNUL() {
        for value in ["a\r\nX-Injected: yes", "a\nb", "a\rb", "a\0b"] {
            let response = HttpResponse().header("X-Test", value)
            #expect(response.headers.isEmpty, "\(value.debugDescription)")
        }
    }

    @Test func headerDropsNamesThatAreNotTokens() {
        for name in ["", "Bad Name", "X:Y", "Bad\r\nName", "X-Ü", "(x)"] {
            let response = HttpResponse().header(name, "v")
            #expect(response.headers.isEmpty, "\(name.debugDescription)")
        }
    }

    @Test func normalHeadersAreKept() {
        let response = HttpResponse()
            .header("X-Ok", "fine value; with = signs, commas \"and\" quotes\ttab")
            .header("Content-Disposition", "attachment; filename=\"x.png\"")
        #expect(response.headers.count == 2)
        #expect(response.header(named: "X-Ok") == "fine value; with = signs, commas \"and\" quotes\ttab")
    }

    @Test func headersBatchDropsOnlyTheBadOnes() {
        let response = HttpResponse().headers([("X-A", "1"), ("X-B", "2\r\nX-Injected: yes"), ("X C", "3"), ("X-D", "4")])
        #expect(response.headers.map { $0.0 } == ["X-A", "X-D"])
    }

    @Test func redirectDropsAnUnsafeLocation() {
        let bad = HttpResponse().redirect(to: "/next\r\nSet-Cookie: evil=1")
        #expect(bad.status.code == 302)
        #expect(bad.headers.isEmpty)

        let good = HttpResponse().redirect(to: "/ok?a=b&c=%20")
        #expect(good.header(named: "Location") == "/ok?a=b&c=%20")
    }

    @Test func setCookieDropsUnsafeValues() {
        for value in ["abc\r\nX-Injected: yes", "abc; Domain=evil.com", "a b", "a,b", "a\"b", "a\\b", "café", "a\0b", "\"a"] {
            let response = HttpResponse().setCookie(name: "auth", value: value)
            #expect(response.headers.isEmpty, "\(value.debugDescription)")
        }
    }

    @Test func setCookieDropsUnsafeNames() {
        for name in ["", "bad name", "a=b", "a;b", "a\r\nb"] {
            let response = HttpResponse().setCookie(name: name, value: "v")
            #expect(response.headers.isEmpty, "\(name.debugDescription)")
        }
    }

    @Test func setCookieDropsUnsafeAttributes() {
        #expect(HttpResponse().setCookie(name: "a", value: "v", path: "/; Domain=evil.com").headers.isEmpty)
        #expect(HttpResponse().setCookie(name: "a", value: "v", path: "/\r\nX: y").headers.isEmpty)
        #expect(HttpResponse().setCookie(name: "a", value: "v", domain: "example.com; Max-Age=1").headers.isEmpty)
        #expect(HttpResponse().setCookie(name: "a", value: "v", domain: "example.com\n").headers.isEmpty)
        #expect(HttpResponse().setCookie(name: "a", value: "v", sameSite: "Lax; Secure").headers.isEmpty)
        #expect(HttpResponse().setCookie(name: "a", value: "v", sameSite: "Lax\t").headers.isEmpty)
        #expect(HttpResponse().setCookie(name: "a", value: "v", path: "/\u{7F}").headers.isEmpty)
    }

    /// RFC 6265 av-octets are ASCII only: C1 controls (U+0080-U+009F, e.g. NEL) and other
    /// non-ASCII text in Path, Domain or SameSite drop the cookie.
    @Test func setCookieDropsNonASCIIAttributes() {
        let nel = String(Character(Unicode.Scalar(0x85)!))
        let lineSeparator = String(Character(Unicode.Scalar(0x2028)!))
        #expect(HttpResponse().setCookie(name: "auth", value: "abc", path: "/" + nel + "x").headers.isEmpty)
        #expect(HttpResponse().setCookie(name: "auth", value: "abc", path: "/" + String(Character(Unicode.Scalar(0x9F)!))).headers.isEmpty)
        #expect(HttpResponse().setCookie(name: "auth", value: "abc", domain: "example.com" + nel).headers.isEmpty)
        #expect(HttpResponse().setCookie(name: "auth", value: "abc", domain: "exa" + String(Character(Unicode.Scalar(0xE4)!)) + "mple.com").headers.isEmpty)
        #expect(HttpResponse().setCookie(name: "auth", value: "abc", sameSite: "Lax" + lineSeparator).headers.isEmpty)
        #expect(HTTPHeaderValidation.isSafeCookieAttribute("/" + nel) == false)
        // printable ASCII, including space and '=', is still accepted
        #expect(HTTPHeaderValidation.isSafeCookieAttribute("/app/a b=c~!") == true)
        #expect(HttpResponse().setCookie(name: "auth", value: "abc", path: "/app", domain: "example.com", sameSite: "Strict")
                .allHeaders(named: "Set-Cookie") == ["auth=abc; Path=/app; Domain=example.com; HttpOnly; SameSite=Strict"])
    }

    @Test func validCookiesAreUnchanged() {
        #expect(HttpResponse().setCookie(name: "auth", value: "").allHeaders(named: "Set-Cookie")
                == ["auth=; Path=/; HttpOnly; SameSite=Lax"])
        #expect(HttpResponse().setCookie(name: "auth", value: "\"quoted\"").allHeaders(named: "Set-Cookie")
                == ["auth=\"quoted\"; Path=/; HttpOnly; SameSite=Lax"])
        #expect(HttpResponse().setCookie(name: "auth", value: "77cd1659-94a7-4fd4-a0ea-3e302e10c446", path: "/app", domain: "example.com",
                                         maxAge: 60, httpOnly: false, secure: true, sameSite: nil).allHeaders(named: "Set-Cookie")
                == ["auth=77cd1659-94a7-4fd4-a0ea-3e302e10c446; Path=/app; Domain=example.com; Max-Age=60; Secure"])
        #expect(HttpResponse().setCookie(name: "t", value: "a-b_c~d.e+f/g=h:i!#$%&'()*").headers.count == 1)

        let cleared = HttpResponse().clearCookie(name: "auth").allHeaders(named: "Set-Cookie")
        #expect(cleared == ["auth=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; SameSite=Lax"])
    }
}
