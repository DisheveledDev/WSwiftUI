import Foundation
import Dispatch

// Token extraction (Bearer header, opt-in ?token=, auth cookie) lives in
// security/SessionCookie.swift: HttpRequest.authenticationCredential(acceptQueryToken:).

public class WSwiftServer {
    
    // endpoint registration
    private var mutex: Mutex = Mutex()
    private var endpoints: [WebEndpoint] = []
    private let listenPort: Int
    public var publicBaseURL: String?
    
    /// When true, a `?token=` query parameter can authenticate a request (after a Bearer
    /// header, before the auth cookie). It is never written into the session cookie.
    /// Defaults to false: the query string is ignored for authentication, because a token
    /// in a link can be planted by someone else and leaks into logs and Referer headers.
    public var acceptQueryToken: Bool = false
    
    public func register(_ newEndpoint: WebEndpoint) {
        
        let instance = newEndpoint.create()
        
        // calculate the path from the controller and method
        let path = instance.path
        mutex.execute {
            endpoints.append( instance )
        }
        
        let callback: ((HttpRequest) -> HttpResponse) = { [self] request in
            
            let action = WebRequestActivity.from(request: request)
            var endpoint = newEndpoint.create()
            var grants: [String] = []
            
            let credential = request.authenticationCredential(acceptQueryToken: self.acceptQueryToken)
            endpoint.authenticationIdentifier = credential?.token
            (endpoint as? CoreWebEndpoint)?.authenticationTokenSource = credential?.source ?? .none
            
            if endpoint.authenticationRequired.contains(.authenticated) {
                let rejected = { () -> HttpResponse in
                    let response = HttpResponse().redirect(to: "/")
                    // a rejected ?token= says nothing about the auth cookie, so it must not clear it
                    if credential?.source != .queryParameter {
                        response.clearCookie(name: SessionCookie.name)
                    }
                    return response
                }
                if let token = credential?.token, let authenticator = self.getUserRoles, let currentGrants = authenticator(token, endpoint) {
                    grants = currentGrants
                    if grants.isEmpty {
                        return rejected()
                    }
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
                            
                            // cast the object into a cotent or api
                            if let content = e as? WebContent {
                                if let permissions = content.acceptedRoles(for: action) {
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
                
                // if we have a response, return it
                if let response = response as? HttpResponse {
                    // check to see if there was a new auth token set
                    return response
                } else if response is WebElement {
                    // build the html response from the response object
                    if endpoint is WebContent {
                        if let seoEndpoint = endpoint as? SEOIndexable {
                            let endpointPath = (endpoint as? WebEndpoint)?.path ?? request.head.path
                            endpoint.applyPageSEO(seoEndpoint.seo(), baseURL: self.resolvedBaseURL(for: request), path: endpointPath)
                        }
                        let pageContent = endpoint.renderWebPage()
                        return SessionCookie.apply(to: HttpResponse().status(.ok).content(.html).body(pageContent), for: endpoint)
                    }
                } else if let response = response as? Codable {
                    return SessionCookie.apply(to: HttpResponse().status(.ok).content(.json).body(json: response), for: endpoint)
                }
                
                return HttpResponse().status(.notFound)
                
            }
            
            return HttpResponse().status(.notFound)
            
        }
        
        svr.addRoute(path, handler: callback)
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

public class MenuEntry {
    
    public var title: String = ""
    public var children: [MenuEntry] = []
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
