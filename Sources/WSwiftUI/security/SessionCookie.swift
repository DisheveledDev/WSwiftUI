//
//  SessionCookie.swift
//  WSwiftUI
//
//  Where the request's auth token came from, and the single rule that
//  decides what the "auth" session cookie is set to on a response.
//

import Foundation

/// Where the authentication token of a request was found.
internal enum AuthenticationTokenSource: Sendable, Equatable {
    /// The request carried no token.
    case none
    /// `Authorization: Bearer <token>`.
    case bearerHeader
    /// `?token=<token>` (only honoured when `WSwiftServer.acceptQueryToken` is true).
    case queryParameter
    /// The `auth` cookie.
    case cookie
}

internal struct AuthenticationCredential: Equatable, Sendable {
    let token: String
    let source: AuthenticationTokenSource
}

extension HttpRequest {

    /// Finds the request's authentication token and where it came from.
    ///
    /// Order: the `Authorization` header (only the `Bearer <token>` form; any other
    /// scheme means "no token", as before), then `?token=` when `acceptQueryToken`
    /// is true, then the `auth` cookie. When `acceptQueryToken` is false the query
    /// string is ignored entirely.
    internal func authenticationCredential(acceptQueryToken: Bool) -> AuthenticationCredential? {
        if let authHeader = head.headers.first(where: { $0.0.lowercased() == "authorization" })?.1 {
            let components = authHeader.split(separator: " ")
            guard components.count == 2, components[0].lowercased() == "bearer" else {
                return nil
            }
            return AuthenticationCredential(token: String(components[1]), source: .bearerHeader)
        }
        if acceptQueryToken, let token = head.queryParams["token"], token.isEmpty == false {
            return AuthenticationCredential(token: token, source: .queryParameter)
        }
        if let cookie = cookies[SessionCookie.name] {
            return AuthenticationCredential(token: cookie, source: .cookie)
        }
        return nil
    }
}

internal enum SessionCookie {

    static let name = "auth"
    static let maxAge = 3600

    /// The value to write into the session cookie, or nil to send no Set-Cookie at all.
    ///
    /// - A token set with `authenticateSession(token:)` is always written.
    /// - Otherwise the current token is re-issued when it came from the auth cookie
    ///   (sliding renewal) or a Bearer header, and anonymous requests get an empty
    ///   cookie, as before.
    /// - A token that came from the query string is never written into a cookie.
    static func value(newIdentifier: String?,
                      currentIdentifier: String?,
                      source: AuthenticationTokenSource) -> String? {
        if let newIdentifier {
            return newIdentifier
        }
        switch source {
            case .queryParameter:
                return nil
            case .cookie, .bearerHeader, .none:
                return currentIdentifier ?? ""
        }
    }

    /// Adds the session cookie to `response` following `value(newIdentifier:currentIdentifier:source:)`.
    /// HttpResponse.setCookie drops the cookie if the value is not a valid cookie value.
    @discardableResult
    static func apply(to response: HttpResponse, for endpoint: CoreWebEndpoint) -> HttpResponse {
        guard let cookieValue = value(newIdentifier: endpoint.newAuthenticationIdentifier,
                                      currentIdentifier: endpoint.authenticationIdentifier,
                                      source: endpoint.authenticationTokenSource) else {
            return response
        }
        return response.setCookie(name: name, value: cookieValue, path: "/", domain: nil,
                                  maxAge: maxAge, expires: nil, httpOnly: true, secure: false,
                                  sameSite: "Lax")
    }
}
