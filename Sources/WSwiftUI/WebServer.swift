import Foundation
import Dispatch

// Sessions: token extraction (Bearer header, opt-in ?token=, session cookie) and cookie writing
// live in security/SessionCookie.swift; the per-request decision and the finalizer that applies it
// to every response live in security/SessionLifecycle.swift; settings in security/SessionConfig.swift.

public class WSwiftServer {
    
    // endpoint registration
    private var mutex: Mutex = Mutex()
    private var endpoints: [WebEndpoint] = []
    private let listenPort: Int
    public var publicBaseURL: String? {
        didSet { publicBaseURLIsHTTPS = SessionCookie.declaresHTTPS(publicBaseURL) }
    }

    /// Whether `publicBaseURL` was given with an explicit `https://` scheme. Only that makes
    /// `.auto` session cookies `Secure`: a value without a scheme is normalized to https for
    /// canonical URLs, but may well be served over plain http.
    private var publicBaseURLIsHTTPS: Bool = false

    /// Session cookie settings: name, lifetime, sliding renewal, Secure and SameSite, and
    /// `acceptQueryToken` (assigning a new value replaces one set through `acceptQueryToken`).
    /// See `WebSessionConfig` for when a response sets, renews or clears the cookie.
    public var session: WebSessionConfig = WebSessionConfig()
    
    /// When true, a `?token=` query parameter can authenticate a request (after a Bearer
    /// header, before the auth cookie). It is never written into the session cookie.
    /// Defaults to false: the query string is ignored for authentication, because a token
    /// in a link can be planted by someone else and leaks into logs and Referer headers.
    /// Same as `session.acceptQueryToken`: assigning `session` afterwards replaces it, so set
    /// `session` first or pass `acceptQueryToken:` to `WebSessionConfig`.
    public var acceptQueryToken: Bool {
        get { session.acceptQueryToken }
        set { session.acceptQueryToken = newValue }
    }
    
    public func register(_ newEndpoint: WebEndpoint) {
        
        let instance = newEndpoint.create()
        
        // calculate the path from the controller and method
        let path = instance.path
        mutex.execute {
            endpoints.append( instance )
        }
        
        // every response this returns is finalized by the route handler below, which applies the session cookie
        let callback: ((HttpRequest, SessionRequestContext) -> HttpResponse) = { [self] request, sessionContext in
            
            let action = WebRequestActivity.from(request: request)
            var endpoint = newEndpoint.create()
            var grants: [String] = []
            
            let credential = sessionContext.credential
            endpoint.authenticationIdentifier = credential?.token
            (endpoint as? CoreWebEndpoint)?.sessionContext = sessionContext
            
            if endpoint.authenticationRequired.contains(.authenticated) {
                let rejected = { () -> HttpResponse in
                    // the finalizer clears a rejected cookie token; a Bearer or ?token= credential never touches the cookie
                    sessionContext.credentialRejected()
                    return HttpResponse().redirect(to: "/")
                }
                if let token = credential?.token, let authenticator = self.getUserRoles, let currentGrants = authenticator(token, endpoint) {
                    grants = currentGrants
                    if grants.isEmpty {
                        return rejected()
                    }
                    sessionContext.credentialAccepted()
                } else {
                    return rejected()
                }
            }
            
            // we've passed authentication, next check the permissions for the user vs the required permissions.
            
            if let content = endpoint as? WebContent {
                if let permissions = content.acceptedRoles(for: action) {
                    if permissions.isEmpty == false {
                        // get the authenticated permissions/grants
                        if grants.containsAny(permissions) == false {
                            return HttpResponse().status(.forbidden).body("You do not have permission to perform this action.")
                        }
                    }
                }
            } else if let api = endpoint as? WebApiEndpoint {
                if let permissions = api.acceptedRoles() {
                    if permissions.isEmpty == false {
                        // get the authenticated permissions/grants
                        if grants.containsAny(permissions) == false {
                            return HttpResponse().status(.forbidden).body("You do not have permission to perform this action.")
                        }
                    }
                }
            }
            
            // populate the handler
            endpoint.request = request
            
            // extract any values from the request and put them into the web data object
            endpoint.data.consume(request.head.queryParams)
            endpoint.data.consume(request.head.headerMap)
            endpoint.data.consume(request.body)
            endpoint.ephemeralData["user_roles"] = grants
            
            // build the menu structure
            var menus: [MenuEntry] = []
            mutex.execute {
                
                var available: [WebEndpoint] = []
                
                for (e) in endpoints {
                    
                    if e is MenuIndexable {
                        
                        // we need to check if the endpoint is visible when logged in or logged out
                        if e.authenticationRequired.contains(.authenticated) && grants.isEmpty {
                            continue // skip this item
                        }
                        
                        // check if it's unauthenticated only, but user is logged in
                        if e.authenticationRequired.contains(.unauthenticated) && (e.authenticationRequired.contains(.authenticated) == false) && (grants.isEmpty == false) {
                            continue // skip this item
                        }
                        
                        // we now need to check if we have permissions to see it
                        if e.authenticationRequired.contains(.authenticated) {
                            
                            // cast the object into a cotent or api; a menu entry is a link, so it is shown
                            // when the user may view the page, whatever the current request is doing
                            if let content = e as? WebContent {
                                if let permissions = content.acceptedRoles(for: .Content) {
                                    if permissions.isEmpty == false {
                                        // get the authenticated permissions/grants
                                        if grants.containsAny(permissions) == false {
                                            continue // skip this item
                                        }
                                    }
                                }
                            }
                            
                        }
                        
                        // we are here so it should be shown in the menu structure, but could be a child of one that does not exist yet. Urgh.
                        available.append(e)
                        
                    }
                    
                }
                
                // now we go through the available endpoints in the tuple and build up the menu structure, and find all the primary entries and create them
                
                var primaries: [String] = []
                
                for e in available {
                    
                    // it has to be content and it has to be indexable
                    guard let menuEndpoint = e as? MenuIndexable else { continue }
                    guard e is WebContent else { continue }
                    
                    if primaries.contains(menuEndpoint.menuPrimary) == false {
                        
                        // we have a new one, we can go ahead and create the primary entry
                        primaries.append(menuEndpoint.menuPrimary)
                        
                        // now the menu entry as well
                        let entry = MenuEntry()
                        entry.title = menuEndpoint.menuPrimary
                        entry.path = e.path
                        
                        menus.append(entry)
                        
                    }
                    
                }
                
                // now we are going to add in secondary entries to the primary ones
                for e in available {
                    
                    guard let menuEndpoint = e as? MenuIndexable else { continue }
                    guard e is WebContent else { continue }
                    
                    // find the primary entry
                    if let primaryEntry = menus.first(where: { $0.title == menuEndpoint.menuPrimary }) {
                        
                        // there must be a secondary title
                        if let secondary = menuEndpoint.menuSecondary, secondary.isEmpty == false {
                            
                            // now we can add the secondary entry
                            let secondaryEntry = MenuEntry()
                            secondaryEntry.title = secondary
                            secondaryEntry.path = e.path
                            secondaryEntry.header = false
                            
                            // now we can add it to the primary entry
                            primaryEntry.children.append(secondaryEntry)
                            
                        }
                        
                    }
                }
                
                // mark the entry for the page being served, and its primary, as selected
                menus.markSelected(paths: [request.head.path, path])
            }
            
            if let endpoint = endpoint as? CoreWebEndpoint {
                endpoint.ephemeralData["menu_data"] = menus
            }
            
            // now make the onAccept callback if its setup
            if let onAccept = self.onAccept {
                onAccept(endpoint)
            }
            
            // now execute and return the correct method
            if let endpoint = endpoint as? CoreWebEndpoint {
                
                var response: Any? = nil
                
                if let endpoint = endpoint as? WebApiEndpoint {
                    // execute the api endpoint
                    response = endpoint.call()
                } else if let endpoint = endpoint as? WebContent {
                    // execute the content endpoint
                    switch action {
                        case .Content:
                            response = endpoint.content()
                        case .Persist:
                            response = endpoint.persist()
                    }
                } else {
                    // we don't know what to do with this endpoint, so return not found
                    return HttpResponse().status(.notFound)
                }
                
                // if we have a response, return it (the session cookie is added when it is finalized)
                if let response = response as? HttpResponse {
                    return response
                } else if response is WebElement {
                    // build the html response from the response object
                    if endpoint is WebContent {
                        if let seoEndpoint = endpoint as? SEOIndexable {
                            let endpointPath = (endpoint as? WebEndpoint)?.path ?? request.head.path
                            endpoint.applyPageSEO(seoEndpoint.seo(), baseURL: self.resolvedBaseURL(for: request), path: endpointPath)
                        }
                        let pageContent = endpoint.renderWebPage()
                        return HttpResponse().status(.ok).content(.html).body(pageContent)
                    }
                } else if let response = response as? Codable {
                    return HttpResponse().status(.ok).content(.json).body(json: response)
                }
                
                return HttpResponse().status(.notFound)
                
            }
            
            return HttpResponse().status(.notFound)
            
        }
        
        svr.addRoute(path) { [self] request in
            // without an onSessionEnded handler a logout only clears the browser's cookie: say so, once
            let notice = self.sessionEndedNotice
            let sessionContext = SessionRequestContext(request: request,
                                                       config: self.session,
                                                       publicBaseURLIsHTTPS: self.publicBaseURLIsHTTPS,
                                                       onSessionEnded: self.sessionEnded ?? { _ in notice.log() })
            return sessionContext.finalize(callback(request, sessionContext))
        }
        print("Registered endpoint \(newEndpoint) at path \(path)")
        
        
    }
    
    public func registerWebSocket(_ newEndpoint: CoreWebsocketEndpoint) {
        let instance = newEndpoint.create()
        // compute path from controller/method if available, otherwise default
        let path: String
        if let endpointWithPath = instance as? WebEndpoint {
            path = endpointWithPath.path
        } else {
            path = "/ws"
        }

        let callback: ((HttpRequest) -> HttpResponse) = { request in
            // Only proceed for websocket upgrade requests
            switch request.kind {
            case .websocket(let upgrade):
                // Create long-lived endpoint instance
                let wsEndpoint = newEndpoint.create()
                wsEndpoint.request = request
                // Select a protocol if needed
                let chosenProto = upgrade.protocols.first
                // Accept handshake
                let response = HttpResponse().acceptWebSocket(key: upgrade.key, protocol: chosenProto)

                // Start the loop only once the 101 has been completely written: frames sent from
                // onOpen can't reach the wire before the handshake, and if the 101 write fails the
                // HTTP server closes the fd without the WebSocket side ever having touched it.
                response.onUpgraded = {
                    DispatchQueue.global(qos: .userInitiated).async {
                        wsEndpoint.startWebSocket(upgrade)
                    }
                }

                return response
            case .http:
                return HttpResponse().status(.badRequest).body("Expected WebSocket upgrade")
            }
        }

        svr.addRoute(path, handler: callback)
        print("Registered WebSocket endpoint \(newEndpoint) at path \(path)")
    }
    
    public func unregister(_ endpoint: WebEndpoint) {
        
    }
    
    private func registerSystemRoutes() {
        svr.addRoute("/sitemap.xml") { [weak self] request in
            guard let self = self else {
                return HttpResponse().status(.serviceUnavailable)
            }
            
            let entries = self.collectSitemapEntries(for: request)
            let xml = self.renderSitemapXML(entries)
            return HttpResponse()
                .status(.ok)
                .header("Content-Type", "application/xml; charset=utf-8")
                .body(xml)
        }
        
        svr.addRoute("/trawl-urls.txt") { [weak self] request in
            guard let self = self else {
                return HttpResponse().status(.serviceUnavailable)
            }
            
            let entries = self.collectSitemapEntries(for: request)
            let body = self.renderTrawlURLList(entries)
            return HttpResponse().status(.ok).content(.text).body(body)
        }
        
        svr.addRoute("/robots.txt") { [weak self] request in
            guard let self = self else {
                return HttpResponse().status(.serviceUnavailable)
            }
            
            return HttpResponse().status(.ok).content(.text).body(self.renderRobotsTXT(for: request))
        }
    }
    
    private func collectSitemapEntries(for request: HttpRequest) -> [SitemapEntry] {
        let baseURL = resolvedBaseURL(for: request)
        var deduplicated: [SitemapEntry] = []
        var seen: Set<String> = []
        
        mutex.execute {
            for endpoint in endpoints {
                guard isPublicContentEndpoint(endpoint) else {
                    continue
                }
                
                if let sitemapEndpoint = endpoint as? SitemapIndexable {
                    guard sitemapEndpoint.includeInSitemap else {
                        continue
                    }
                    
                    for entry in sitemapEndpoint.sitemapEntries(baseURL: baseURL) {
                        let url = normalizeSitemapURL(entry.url, baseURL: baseURL)
                        guard seen.insert(url).inserted else {
                            continue
                        }
                        
                        deduplicated.append(SitemapEntry(
                            url: url,
                            lastModified: entry.lastModified,
                            changeFrequency: entry.changeFrequency,
                            priority: entry.priority,
                            includeInTrawl: entry.includeInTrawl
                        ))
                    }
                } else {
                    let defaultURL = normalizeSitemapURL(endpoint.path, baseURL: baseURL)
                    guard seen.insert(defaultURL).inserted else {
                        continue
                    }
                    deduplicated.append(SitemapEntry(url: defaultURL))
                }
            }
        }
        
        return deduplicated.sorted(by: { $0.url < $1.url })
    }
    
    private func isPublicContentEndpoint(_ endpoint: WebEndpoint) -> Bool {
        guard endpoint is WebContent else {
            return false
        }
        
        guard endpoint.path.contains("*") == false else {
            return false
        }
        
        guard endpoint.authenticationRequired.contains(.unauthenticated) else {
            return false
        }
        
        if let contentEndpoint = endpoint as? WebContent,
           let permissions = contentEndpoint.acceptedRoles(for: .Content),
           permissions.isEmpty == false {
            return false
        }
        
        return true
    }
    
    private func resolvedBaseURL(for request: HttpRequest) -> String {
        if let configured = publicBaseURL {
            return configured
        }
        
        if let origin = request.head.headerMap["origin"],
           let normalizedOrigin = Self.normalizedBaseURL(origin) {
            return normalizedOrigin
        }
        
        let forwardedProto = firstHeaderValue(request.head.headerMap["x-forwarded-proto"]) ?? "http"
        
        if let forwardedHost = firstHeaderValue(request.head.headerMap["x-forwarded-host"]),
           forwardedHost.isEmpty == false,
           let normalized = Self.normalizedBaseURL("\(forwardedProto)://\(forwardedHost)") {
            return normalized
        }
        
        if let host = firstHeaderValue(request.head.headerMap["host"]),
           host.isEmpty == false,
           let normalized = Self.normalizedBaseURL("\(forwardedProto)://\(host)") {
            return normalized
        }
        
        return "http://localhost:\(listenPort)"
    }
    
    private func renderSitemapXML(_ entries: [SitemapEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">")
        
        for entry in entries {
            lines.append("  <url>")
            lines.append("    <loc>\(xmlEscape(entry.url))</loc>")
            if let lastModified = entry.lastModified {
                lines.append("    <lastmod>\(formatter.string(from: lastModified))</lastmod>")
            }
            if let frequency = entry.changeFrequency {
                lines.append("    <changefreq>\(frequency.rawValue)</changefreq>")
            }
            if let priority = entry.priority {
                let clamped = min(1.0, max(0.0, priority))
                lines.append("    <priority>\(String(format: "%.1f", clamped))</priority>")
            }
            lines.append("  </url>")
        }
        
        lines.append("</urlset>")
        return lines.joined(separator: "\n") + "\n"
    }
    
    private func renderTrawlURLList(_ entries: [SitemapEntry]) -> String {
        let urls = entries
            .filter { $0.includeInTrawl }
            .map { $0.url }
        
        if urls.isEmpty {
            return ""
        }
        return urls.joined(separator: "\n") + "\n"
    }
    
    private func renderRobotsTXT(for request: HttpRequest) -> String {
        let baseURL = resolvedBaseURL(for: request)
        return """
        User-agent: *
        Allow: /
        Sitemap: \(baseURL)/sitemap.xml
        
        """
    }
    
    private func normalizeSitemapURL(_ url: String, baseURL: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        
        if trimmed.hasPrefix("/") {
            return "\(baseURL)\(trimmed)"
        }
        
        return "\(baseURL)/\(trimmed)"
    }
    
    private func xmlEscape(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    
    private func firstHeaderValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        
        if let first = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true).first {
            return first.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func normalizedBaseURL(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        
        if trimmed.hasPrefix("http://") == false && trimmed.hasPrefix("https://") == false {
            trimmed = "https://\(trimmed)"
        }
        
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        
        return trimmed
    }
    
    private var getUserRoles: ((String, WebEndpoint) -> [String]?)? = nil
    
    // authentication
    public func onGetUserRoles(callback: @escaping ((_ authenticationToken: String?, _ endpoint: WebEndpoint) -> [String]?)) {
        getUserRoles = callback
    }
    
    private var sessionEnded: ((String) -> Void)? = nil
    
    /// Called when an endpoint calls `deauthenticateSession()`, with the token that was in effect:
    /// the one set earlier in the same request with `authenticateSession`, otherwise the request's
    /// own token (cookie, Bearer or accepted `?token=`). The logout clears the session cookie, so when
    /// the request's cookie holds a different token (a Bearer header or `?token=` took precedence over
    /// it) the handler is called with that token too. It runs at most once per token per request,
    /// however often `deauthenticateSession()` is called, and not at all when no token was in effect.
    ///
    /// The token has not necessarily been validated: on a public endpoint (a typical `/logout`)
    /// `onGetUserRoles` doesn't run, so it is whatever the request carried. Treat it as a key to
    /// delete, not as proof of identity.
    ///
    /// Revoke the token server-side here; a reliable logout needs it:
    ///
    ///     server.onSessionEnded { token in Database.removeUserToken(token: token) }
    ///
    /// Clearing the cookie only affects the browser that receives the logout response. Sessions are
    /// stateless, so a request still carrying the old cookie (an XHR in flight, another tab, a copied
    /// cookie) that reaches an `[.authenticated]` endpoint is accepted and renewed until
    /// `onGetUserRoles` rejects the token. Without a handler the server logs a warning the first
    /// time a session with a token ends.
    ///
    /// It runs synchronously on the request's thread, inside `deauthenticateSession()`, before the
    /// response is sent. It is not called when a token is merely rejected by `onGetUserRoles`.
    public func onSessionEnded(callback: @escaping ((_ token: String) -> Void)) {
        sessionEnded = callback
    }

    /// Logged the first time `deauthenticateSession()` ends a token while no `onSessionEnded`
    /// handler is registered.
    internal let sessionEndedNotice = SessionNotice(
        "[WSwiftUI] deauthenticateSession() cleared the session cookie, but no onSessionEnded handler is registered: "
        + "the token stays valid server-side, so a copied cookie or a request already in flight can still use it. "
        + "Revoke it with server.onSessionEnded { token in ... }."
    )
    
    // request events
    private var onAccept: ((_ endpoint: WebEndpoint) -> Void)? = nil
    
    public func onAcceptedRequest(callback: @escaping ((_ endpoint: WebEndpoint) -> Void)) {
        self.onAccept = callback
    }
    
    // instance vars
    private var svr: HTTPServer!
    
    /// Dispatches a request through the registered routes without going through a socket.
    /// Used by the test suite (and usable for in-process integration tests).
    internal func respond(to request: HttpRequest) -> HttpResponse {
        if let handler = self.svr.routeHandler(for: request.head.path) {
            return handler(request)
        }
        return HttpResponse().status(.notFound).body("No endpoints configured.")
    }
    
    // action blocks
    public convenience init(port: Int, bindAddressv4: String? = nil, publicBaseURL: String? = nil) {
        self.init(port: port, bindAddressv4: bindAddressv4, publicBaseURL: publicBaseURL, autoStart: true)
    }
    
    /// - Parameter autoStart: when `false` the listening socket is not opened; the test suite dispatches
    ///   requests in process with `respond(to:)`.
    internal init(port: Int, bindAddressv4: String?, publicBaseURL: String?, autoStart: Bool) {
        self.listenPort = port
        self.publicBaseURL = Self.normalizedBaseURL(publicBaseURL)
        // observers do not run in init; decide from the value as given, before normalization
        self.publicBaseURLIsHTTPS = SessionCookie.declaresHTTPS(publicBaseURL)

        var config = HTTPServer.Config()
        config.port = UInt16(port)

        self.svr = HTTPServer(config: config, onRequestHead: { head in
            return .accept
        }, onBeforeBody: { head in
            return .accept
        }, handler: { request in
            
            if let handler = self.svr.routeHandler(for: request.head.path) {
                return handler(request)
            }
            
            return HttpResponse().status(.notFound).body("No endpoints configured.")
        })
        
        registerSystemRoutes()
        if autoStart {
            try? svr.start()
        }

    }
    
}

/// One entry of the menu built for each request (`CoreWebEndpoint.menuEntries`). Entries are
/// listed when the user may view the page (its `.Content` roles), whatever the current request does.
public class MenuEntry {
    
    public var title: String = ""
    public var children: [MenuEntry] = []
    /// True for the entry of the page being served, and for the primary entry that contains it.
    public var selected: Bool = false
    public var path: String?
    public var header: Bool = false
    
}

internal class Mutex {
    
    private var thread: Thread? = nil;
    private var lock: DispatchQueue
    
    public init() {
        lock = DispatchQueue(label: UUID().uuidString.lowercased())
    }
    
    public func execute(_ closure:() -> Void) {
        if thread != Thread.current {
            lock.sync {
                thread = Thread.current
                closure()
                thread = nil
            }
        } else {
            closure()
        }
    }
    
    public func execute<T>(_ closure:() -> T) -> T {
        if thread != Thread.current {
            return lock.sync {
                thread = Thread.current
                let result = closure()
                thread = nil
                return result
            }
        } else {
            return closure()
        }
    }
    
}
