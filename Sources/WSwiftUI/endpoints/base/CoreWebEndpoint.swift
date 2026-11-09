//
//  BaseWebEndpoint.swift
//  SWWebAppServer
//
//  Created by Adrian on 31/01/2025.
//

import Foundation

public enum PickerType {
    case dropdown
    case radio
    case check
    case modal
    case view
    case segmented
}

public typealias WebComposerClosure = (() -> Void)

public enum HeadItem {
    case css(String)
    case js(String)
    case meta(String)
    case link(String)
    case script(String)
    case style(String)
    case title(String)
    case raw(String)
}

public enum WebCoreHeadElement {
    case title(String)
    case base(href: String)
    
    // MARK: - Meta tags
    case metaCharset(String)                                   // <meta charset="…">
    case metaHttpEquiv(httpEquiv: String, content: String)     // <meta http-equiv="…" content="…">
    case metaName(name: String, content: String)               // <meta name="…" content="…">
    case metaProperty(property: String, content: String)       // <meta property="…" content="…">
    
    // convenience for very common names
    case metaViewport(content: String)                         // <meta name="viewport" content="…">
    case metaThemeColor(String)                                // <meta name="theme-color" content="…">
    case metaDescription(String)                               // <meta name="description" content="…">
    case metaApplicationName(String)                           // <meta name="application-name" content="…">
    case metaMobileWebAppCapable(Bool)                         // <meta name="mobile-web-app-capable" content="yes|no">
    // … you can add more “named” shortcuts here …
    
    // MARK: - Link tags
    case link(rel: LinkRel,
              href: String,
              type: String?        = nil,
              sizes: String?       = nil,
              color: String?       = nil,
              attributes: [String:String]? = nil)
    /// e.g.
    /// .link(.icon, href: "...", type: "image/png", sizes: "32x32")
    ///
    /// and you can still do arbitrary ones:
    /// .link(.other("preload"), href: "...", attributes: ["as":"font","crossorigin":""])
    
    public enum LinkRel: Equatable {
        case icon, stylesheet, appleTouchIcon, maskIcon, manifest, shortcutIcon
        case other(String)
        
        public var stringValue: String {
            switch self {
            case .icon:             return "icon"
            case .stylesheet:       return "stylesheet"
            case .appleTouchIcon:   return "apple-touch-icon"
            case .maskIcon:         return "mask-icon"
            case .manifest:         return "manifest"
            case .shortcutIcon:     return "shortcut icon"
            case .other(let s):     return s
            }
        }
    }
    
    // MARK: - Scripts & Styles
    case script(src: String,
                async: Bool     = false,
                defer: Bool     = false,
                type: String?   = nil,
                integrity: String? = nil,
                crossOrigin: String? = nil,
                attributes: [String:String]? = nil)
    case inlineScript(String)
    
    case styleLink(href: String)  // alias for .link(.stylesheet,…)
    case inlineStyle(String)
    
    // MARK: - Comments & Custom
    case comment(String)
    
    /// For anything else you haven’t explicitly modelled above
    case custom(tag: String,
                attributes: [String:String],
                innerHTML: String?)
}


public enum WebCoreElementAttribute {
    case `class`(String)
    case deviceClass(mobile: String?, desktop: String?)
    case id(String)
    case name(String)
    case value(String)
    case type(String)
    case placeholder(String)
    case required
    case disabled
    case readonly
    case checked
    case selected
    case src(String)
    case href(String)
    case alt(String)
    case title(String)
    case style(String)
    case data(String)
    case custom(String)
    case pair(String, String)
    case script(String)
    case innerHTML(String)
    case item(WebElement)
    case variant(BootstrapVariant)
    case parent(Any)
    case label(String)
    case initialValue(Any)
    case errorMessage(String)
    case domLoadedScript(String)
    case validation(ValidationCondition)
    case dontRegisterObject
}

internal enum WebCoreLayoutType {
    case vertical
    case horizontal
}

public class WebElement {

    /// The element's id: its CSS class, the name of its JavaScript global (`<id>` is the element once the page
    /// has loaded, when a script refers to it) and the stem of its generated function names.
    ///
    /// An element created through an endpoint (every DSL control, `create {}`, the `W...` variables) gets
    /// `<namespace>_<n>`: the endpoint's id namespace (`CoreWebEndpoint.elementIdNamespace`, or a short random
    /// one per endpoint instance) and a base-36 counter, e.g. `kq3xa_1f`. That is a valid JavaScript
    /// identifier and CSS class, never empty, unique within the page, and (because of the `_`) never the
    /// name of a Bootstrap class or a browser global. An element created on its own (`WebElement()`) gets a
    /// random id of the same shape until an endpoint adopts it.
    public lazy var builderId: String = WebElementId.fallback()

    internal var attributes: [WebCoreElementAttribute] = []
    internal var layout: WebCoreLayoutType = .vertical
    public var elementName: String = "div"
    public var subElements: [WebElement] = []

    /// Adds an attribute. A `.script` or `.domLoadedScript` added from outside the WSwiftUI module (app code)
    /// is raw JavaScript: it is emitted in a `<script>` element of its own, so a syntax error in it can't stop
    /// the framework's scripts or another element's. `file` identifies the caller; leave it defaulted.
    @discardableResult
    public func addAttribute(_ attribute: WebCoreElementAttribute, file: StaticString = #fileID) -> Self {
        attributes.append(WebScriptOrigin.tagged(attribute, addedFrom: file))
        return self
    }
    
    @discardableResult
    public func `class`(_ className: String)  -> Self {
        addAttribute(.class(className))
        return self
    }
    
    /// Applies one class for mobile clients and another for desktop clients.
    @discardableResult
    public func deviceClass(mobile: String? = nil, desktop: String? = nil) -> Self {
        addAttribute(.deviceClass(mobile: mobile, desktop: desktop))
        return self
    }
    
    @discardableResult
    public func mobileClass(_ className: String) -> Self {
        addAttribute(.deviceClass(mobile: className, desktop: nil))
        return self
    }
    
    @discardableResult
    public func desktopClass(_ className: String) -> Self {
        addAttribute(.deviceClass(mobile: nil, desktop: className))
        return self
    }
    
    @discardableResult
    public func id(_ id: String)  -> Self {
        addAttribute(.id(id))
        return self
    }
    
    /// Sets the element's `name`. An element has one name: this replaces any earlier `.name(...)` or
    /// `.pair("name", ...)`.
    @discardableResult
    public func name(_ name: String)  -> Self {
        attributes.removeAll(where: {
            switch $0 {
                case .name: return true
                case .pair(let key, _): return key.lowercased() == "name"
                default: return false
            }
        })
        addAttribute(.name(name))
        return self
    }
    
    @discardableResult
    public func label(_ text: String)  -> Self {
        
        // remove existing name etries to stop duplication
        attributes.removeAll(where: { if case .label(_) = $0 { return true } else { return false } })
        addAttribute(.label(text))
        return self
        
    }
    
    /// Sets the element's `value`. An element has one value: this replaces any earlier `.value(...)` or
    /// `.pair("value", ...)`. (A variable's hidden input always renders the variable's current value, and a
    /// password input never renders one.)
    @discardableResult
    public func value(_ value: String)  -> Self {
        attributes.removeAll(where: {
            switch $0 {
                case .value: return true
                case .pair(let key, _): return key.lowercased() == "value"
                default: return false
            }
        })
        addAttribute(.value(value))
        return self
    }
    
    /// Sets the element's inner HTML. The string is emitted **raw** (it is trusted HTML), so never pass
    /// user-supplied or database values here without escaping them first (`WebEscape.html(_:)`); the
    /// built-in controls (`Text`, `Button`, `Link`, ...) already escape the text they are given.
    @discardableResult
    public func innerHTML(_ value: String)  -> Self {
        addAttribute(.innerHTML(value))
        return self
    }
    
    @discardableResult
    public func type(_ type: String)  -> Self {
        // remove existing type etries to stop duplication
        attributes.removeAll(where: { if case .type(_) = $0 { return true } else { return false } })
        addAttribute(.type(type))
        return self
    }
    
    @discardableResult
    public func placeholder(_ placeholder: String)  -> Self {
        addAttribute(.placeholder(placeholder))
        return self
    }
    
    @discardableResult
    public func required()  -> Self {
        addAttribute(.required)
        return self
    }
    
    @discardableResult
    public func disabled()  -> Self {
        addAttribute(.disabled)
        return self
    }
    
    @discardableResult
    public func readonly()  -> Self {
        addAttribute(.readonly)
        return self
    }
    
    @discardableResult
    public func checked()  -> Self {
        addAttribute(.checked)
        return self
    }
    
    @discardableResult
    public func selected()  -> Self {
        addAttribute(.selected)
        return self
    }
    
    @discardableResult
    public func src(_ src: String)  -> Self {
        addAttribute(.src(src))
        return self
    }
    
    @discardableResult
    public func href(_ href: String)  -> Self {
        addAttribute(.href(href))
        return self
    }
    
    @discardableResult
    public func alt(_ alt: String)  -> Self {
        addAttribute(.alt(alt))
        return self
    }
    
    @discardableResult
    public func title(_ title: String)  -> Self {
        addAttribute(.title(title))
        return self
    }
    
    @discardableResult
    public func style(_ style: String)  -> Self {
        addAttribute(.style(style))
        return self
    }
    
    /// Runs `script` once the page's body has been parsed (all element scripts run, in document order, from
    /// the end of `<body>`). Called from app code, the script is raw JavaScript and gets a `<script>` element
    /// of its own; see `addAttribute(_:file:)`. `file` identifies the caller; leave it defaulted.
    @discardableResult
    public func script(_ script: String, file: StaticString = #fileID)  -> Self {
        addAttribute(.script(script), file: file)
        return self
    }
    
    @discardableResult
    public func data(_ data: String)  -> Self {
        addAttribute(.data(data))
        return self
    }
    
    /// Appends a raw attribute string (e.g. `custom("loading=\"lazy\"")`) to the tag **unescaped**. Use
    /// `addAttribute(.pair(name, value))` for anything containing a dynamic value; `.pair` values are escaped.
    @discardableResult
    public func custom(_ custom: String)  -> Self {
        addAttribute(.custom(custom))
        return self
    }
    
    // MARK: Hiding
    //
    // Every `hidden` overload hides the element the same way: it gets Bootstrap's `d-none` class
    // (`display: none !important`). A hidden element takes no space in the layout, can't be focused or
    // clicked, and is not read by screen readers; it stays in the page, so it can be shown again. This is
    // the same mechanism as the `.hide(ref:)` / `.show(ref:)` actions, so they work on it too.
    // Unlike SwiftUI's `.hidden()`, the element does not keep its space; `.class("invisible")`
    // (`visibility: hidden`) does that. To hide something from sighted users only, and keep it for screen
    // readers, use `visuallyHidden()`.
    
    /// Hides the element (`display: none`, see above) when `hidden` is `true`, which is the default, so
    /// `.hidden()` hides. `.hidden(false)` adds nothing.
    @discardableResult
    public func hidden(_ hidden: Bool = true) -> Self {
        if hidden {
            addAttribute(.class("d-none"))
        }
        return self
    }
    
    /// This overload never had any effect: a `WebAction` describes something to do, not a condition.
    @available(*, deprecated, message: "This overload has no effect. Use hidden(_: Bool), hidden(_: WebVariableElement), or the .hide(ref:) / .show(ref:) actions.")
    @discardableResult
    public func hidden(_ condition: WebAction) -> Self {
        return self
    }
    
    /// Hides the element (`display: none`, see above) while the bound variable is truthy, and shows it
    /// while it is falsy. The server renders the variable's current state; the browser then follows every
    /// change of the variable.
    @discardableResult
    public func hidden(_ hidden: WebVariableElement) -> Self {
        // An anonymous callback, so it can't collide with another `updateVariable<builderId>` function
        // declared for the same element (for example by `disabled(_:)`).
        addAttribute(.script("""
            addCallback\(hidden.builderId)(function (value, _meta) {
                var element = \(builderId);
                if (!element) { return; }
                if (value) {
                    element.classList.add("d-none");
                } else {
                    element.classList.remove("d-none");
                }
            });
            """))
        if hidden.asBool() {
            addAttribute(.class("d-none"))
        }
        return self
    }
    
    /// hides the button via class and attribute
    @discardableResult
    public func disabled(_ disabled: WebVariableElement) -> Self {
        addAttribute(.script("""
            function updateVariable\(builderId)(value, _meta) {
                if (value) {
                    \(builderId).classList.add("disabled");
                    \(builderId).setAttribute("aria-disabled", "true");
                    if ("disabled" in \(builderId)) {
                        \(builderId).disabled = true;
                    }
                } else {
                    \(builderId).classList.remove("disabled");
                    \(builderId).removeAttribute("aria-disabled");
                    if ("disabled" in \(builderId)) {
                        \(builderId).disabled = false;
                    }
                }
            }
            addCallback\(disabled.builderId)(updateVariable\(builderId));
            """))
        if disabled.asBool() {
            addAttribute(.class("disabled"))
        }
        return self
    }
    
    @discardableResult
    public func required(_ reqd: Bool = false) -> Self {
        if reqd {
            addAttribute(.custom("required"))
        }
        return self
    }
    
    @discardableResult
    public func validate(_ conditions: [ValidationCondition]) -> Self {
        // so we will generate js to check the validation status of the element, we will not allow form submission
        for condition in conditions {
            addAttribute(.validation(condition))
        }
        return self
    }
    
}

public enum WebClientDeviceKind: String {
    case mobile
    case desktop
}

public extension HttpRequest {
    var clientDeviceKind: WebClientDeviceKind {
        // The two headers this needs, found without building the whole `headerMap`. As in `headerMap`, a
        // header that is sent twice counts with its last value.
        var mobileHeader: String? = nil
        var userAgent: String? = nil
        for (name, value) in head.headers {
            if name.caseInsensitiveCompare("sec-ch-ua-mobile") == .orderedSame {
                mobileHeader = value
            } else if name.caseInsensitiveCompare("user-agent") == .orderedSame {
                userAgent = value
            }
        }

        if let mobileHint = mobileHeader?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if mobileHint.contains("?1") { return .mobile }
            if mobileHint.contains("?0") { return .desktop }
        }

        let ua = (userAgent ?? "").lowercased()
        if ua.isEmpty {
            return .desktop
        }
        
        let mobileHints = [
            "android",
            "iphone",
            "ipad",
            "ipod",
            "mobile",
            "tablet",
            "windows phone",
            "iemobile",
            "blackberry",
            "opera mini",
            "silk",
            "kindle"
        ]
        
        return mobileHints.contains(where: { ua.contains($0) }) ? .mobile : .desktop
    }
    
    var isMobileClient: Bool {
        clientDeviceKind == .mobile
    }
}

public extension CoreWebEndpoint {
    /// The kind of device the request came from. Worked out once per request (the renderer asks for every
    /// `.deviceClass`), and again only when `request` is replaced.
    var clientDeviceKind: WebClientDeviceKind {
        if let cached = deviceKindCache, cached.request === request {
            return cached.kind
        }
        let kind = request.clientDeviceKind
        deviceKindCache = (request, kind)
        return kind
    }
}

public protocol WebEndpoint {
    
    var data: WebData { get set }
    var request: HttpRequest { get set }
    var controller: String? { get set }
    var method: String? { get set }
    var authenticationRequired: [WebAuthenticationStatus] { get set }
    func create() -> Self
    static func path(action: WebRequestActivity?, resource: UUID?, subResource: UUID?, version: UUID?, filter: [String: String]?, fragment: String?, returnUrl: String?) -> String
    var ephemeralData: [String : Any?] { get set }
    var authenticationIdentifier: String? { get set }
    
}

public extension WebEndpoint {
    
    static func path(
        action: WebRequestActivity? = nil,
        resource: UUID? = nil,
        subResource: UUID? = nil,
        version: UUID? = nil,
        filter: [String: String]? = nil,
        fragment: String? = nil,
        returnUrl: String? = nil) -> String {
        
        var path = "/"
        
        if let this = self as? WebEndpoint {
            if let controller = this.controller {
                path += "\(controller)"
            }
            
            if let method = this.method {
                path += "/\(method)"
            }
        }
        
        // check if there are any params at all and if so, append a "?"
        if action != nil || resource != nil || subResource != nil || version != nil || filter != nil || fragment != nil || returnUrl != nil {
            path += "?"
        }
        
        if let action = action {
            path += "action=\(action.rawValue)"
        }
        
        if let resource = resource {
            path += "&resource=\(resource)"
        }
        
        if let subResource = subResource {
            path += "&subResource=\(subResource)"
        }
        
        if let version = version {
            path += "&version=\(version)"
        }
        
        if let filter = filter {
            path += "&filter="
            // now encode the filter as a JSON string
            if let data = try? JSONSerialization.data(withJSONObject: filter, options: .prettyPrinted) {
                if let jsonString = String(data: data, encoding: .utf8) {
                    // now append but make sure the string is URL encoded
                    path += "\(jsonString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
                }
            }
        }
        
        return path
        
    }
    
    var path: String {
        get {
            var path = "/"
            if let controller = self.controller {
                path += "\(controller)"
            }
            if let method = self.method {
                path += "/\(method)"
            }
            return path
        }
    }
    
}

public protocol WebContent {
    
    // default calls for events
    func content() -> Any?
    func persist() -> Any?
    func redirect(_ path: String) -> HttpResponse
    func authenticateSession(token: String, expiry: Date?)
    func deauthenticateSession()
    func acceptedRoles(for action: WebRequestActivity) -> [String]?
    
}

public protocol WebApiEndpoint {
    func call() -> Any?
    func acceptedRoles() -> [String]?
}

internal extension CoreWebEndpoint {
    /// Called by every form control bound to `value` that submits it under the variable's name (TextField,
    /// SecureField, TextArea, Picker). Re-applies the state recorded by `validateData(_:)`
    /// (`previous_<name>` / `error_<name>`) when a form is re-rendered: the variable's value (definition
    /// script, hidden carrier `value`, page-load sync, and the control, which reads it afterwards) and its
    /// error message.
    ///
    /// - Parameters:
    ///   - restoreValue: pass `false` for secret inputs (password fields). The submitted value is then never
    ///     copied back into the variable (so it can't be echoed into the page), and it is dropped from
    ///     `ephemeralData` so a later control bound to the same name can't restore it either. Error messages
    ///     are still applied.
    ///   - claimsFieldName: `true` (the default) when the control submits the field under the variable's
    ///     name; the variable's hidden carrier input then leaves the field to the control instead of
    ///     submitting it a second time. Pass `false` only for a control that does not submit the field
    ///     itself, so the carrier keeps submitting it. (A control in the carrier's form that submits a field
    ///     of the same name takes it over anyway when the page is rendered, see `WebFormFieldClaims`; a
    ///     checkbox does too, so an unchecked box submits nothing, as in plain HTML.)
    func updateWithEphermeralData(_ value: WebVariableElement, restoreValue: Bool = true, claimsFieldName: Bool = true) {

        guard let name = value.internalName else {
            return
        }
        
        if claimsFieldName {
            value.claimFormField(name)
        }

        if restoreValue == false {
            ephemeralData.removeValue(forKey: "previous_\(name)")
        }
        
        func anyFromJSONValue(_ json: JSONValue) -> Any {
            switch json {
                case .string(let s): return s
                case .int(let i): return i
                case .double(let d): return d
                case .bool(let b): return b
                case .array(let arr): return arr.map { anyFromJSONValue($0) }
                case .object(let obj):
                    var mapped: [String: Any] = [:]
                    for (k, v) in obj {
                        mapped[k] = anyFromJSONValue(v)
                    }
                    return mapped
                case .null: return ""
            }
        }
        
        func parseBool(_ raw: Any) -> Bool {
            if let b = raw as? Bool { return b }
            if let i = raw as? Int { return i != 0 }
            if let d = raw as? Double { return d != 0 }
            if let s = raw as? String {
                let lowered = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return lowered == "true" || lowered == "1" || lowered == "yes" || lowered == "on"
            }
            return false
        }
        
        // A double outside Int's range (or NaN / infinite) would trap in `Int(_:)`.
        func intValue(_ d: Double) -> Int? {
            return Int(exactly: d.rounded(.towardZero))
        }

        func parseInt(_ raw: Any) -> Int {
            if let i = raw as? Int { return i }
            if let d = raw as? Double { return intValue(d) ?? 0 }
            if let s = raw as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if let i = Int(trimmed) { return i }
                if let d = Double(trimmed), let i = intValue(d) { return i }
            }
            return 0
        }
        
        func parseDouble(_ raw: Any) -> Double {
            if let d = raw as? Double { return d }
            if let i = raw as? Int { return Double(i) }
            if let s = raw as? String, let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
            return 0
        }
        
        func parseString(_ raw: Any) -> String {
            if let s = raw as? String { return s }
            if let b = raw as? Bool { return b ? "true" : "false" }
            if let i = raw as? Int { return String(i) }
            // the text the client shows for the number (JS `String(number)`)
            if let d = raw as? Double { return ScriptValue.numberText(d) }
            return String(describing: raw)
        }
        
        func parseStringArray(_ raw: Any) -> [String] {
            if let arr = raw as? [String] { return arr }
            if let arr = raw as? [Any] { return arr.map { String(describing: $0) } }
            if let s = raw as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return [] }
                if let data = trimmed.data(using: .utf8),
                   let arr = try? JSONBodyLimits.jsonObject(with: data) as? [Any] {
                    return arr.map { String(describing: $0) }
                }
                return trimmed.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            return []
        }
        
        func parseObject(_ raw: Any) -> [String: Any] {
            if let obj = raw as? [String: Any], JSONSerialization.isValidJSONObject(obj) {
                return obj
            }
            if let s = raw as? String,
               let data = s.data(using: .utf8),
               let obj = try? JSONBodyLimits.jsonObject(with: data) as? [String: Any],
               JSONSerialization.isValidJSONObject(obj) {
                return obj
            }
            return [:]
        }
        
        if let previousValue = ephemeralData["previous_\(name)"], let rawValue = previousValue {
            let sourceValue: Any
            if let jsonValue = rawValue as? JSONValue {
                sourceValue = anyFromJSONValue(jsonValue)
            } else {
                sourceValue = rawValue
            }

            let normalizedValue: Any
            switch value.variableType {
                case .bool:   normalizedValue = parseBool(sourceValue)
                case .int:    normalizedValue = parseInt(sourceValue)
                case .double: normalizedValue = parseDouble(sourceValue)
                case .string: normalizedValue = parseString(sourceValue)
                case .array:  normalizedValue = parseStringArray(sourceValue)
                case .object: normalizedValue = parseObject(sourceValue)
            }

            // the hidden carrier renders its `value` from this (WebVariableElement.formValue)
            value.replaceValue(normalizedValue)
        }
        
        if let errorMessage = ephemeralData ["error_\(name)"] as? String {
            value.errorMessage = errorMessage
        } else {
            value.errorMessage = nil
        }
        
    }
}

open class CoreWebEndpoint {
    
    // create a new object and return it
    public func create() -> Self {
        return Self.init()
    }
    
    public required init() {}
    
    public var data: WebData = WebData()
    public var request: HttpRequest = HttpRequest(
        head: HttpRequestHead(method: .GET, uri: "/", version: "HTTP/1.1", headers: []),
        body: .none
    )
    
    // session data
    public var ephemeralData: [String : Any?] = [:]
    public var authenticationIdentifier: String? = nil
    /// This request's session (see SessionLifecycle.swift). WSwiftServer installs a new one for
    /// each request it dispatches; an endpoint that is not being dispatched has a detached one.
    /// Where `authenticationIdentifier` came from is `sessionContext.credential?.source`.
    internal var sessionContext: SessionRequestContext = SessionRequestContext()
    internal var headAttributes: [WebCoreHeadElement] = []
    
    /// A 302 redirect to `path`. Like every response this endpoint returns, it gets the session
    /// cookie from the server after the endpoint finishes, so `authenticateSession` and
    /// `deauthenticateSession` may be called before or after building it.
    public func redirect(_ path: String) -> HttpResponse {
        return HttpResponse().redirect(to: path)
    }
    
    /// Logs the client in with `token`: the response sets the session cookie to it.
    /// With `expiry` the cookie lives until then (`Max-Age` = expiry - now, at least 0) and is
    /// never renewed past or short of it; without, it lives `WebSessionConfig.maxAge` seconds and
    /// slides when `sliding` is on. Between this and `deauthenticateSession()`, the last call wins.
    public func authenticateSession(token: String, expiry: Date? = nil) {
        sessionContext.establish(token: token, expiry: expiry)
    }
    
    /// Logs the client out: the response expires the session cookie (and its expiry companion),
    /// even on an `[.authenticated]` endpoint, and `WSwiftServer.onSessionEnded` is called with the
    /// token in effect (the one set earlier in this request by `authenticateSession`, otherwise the
    /// request's own token) so the app can revoke it, and again with the session cookie's token when
    /// that is a different one; at most once per token per request.
    /// Register `onSessionEnded` for a reliable logout: without server-side revocation, a request
    /// still carrying the old cookie is accepted (and renewed) by `onGetUserRoles` as before.
    public func deauthenticateSession() {
        sessionContext.end(requestToken: authenticationIdentifier)
    }
    
    // data for final object construction
    internal var title: String? = nil
    internal var head: [HeadItem] = []
    internal var builderScripts: [String] = []
    /// The synthetic document root. Every element created outside a container (before, inside or after
    /// `webpage {}`) is appended to it in creation order. It is a `WebFragmentElement`, so it is never
    /// rendered itself: `renderWebPage()` emits its children into `<body>`.
    internal let documentRoot: WebElement = WebFragmentElement()
    /// The element top-level content hangs from: always `documentRoot`. (It used to be whichever element
    /// was created first, which was then never rendered.)
    internal var webRootElement: WebElement? { documentRoot }
    internal var stack: [WebElement] = []
    /// DOMContentLoaded scripts queued on the endpoint itself. The renderer reads them (before the ones its
    /// elements carry) and never appends to them, so rendering a page twice gives the same output.
    internal var domLoadedScripts: [String] = []

    /// The namespace of the ids of the elements this endpoint creates (`WebElement.builderId` is
    /// `<namespace>_<n>`, `n` counting up in base 36).
    ///
    /// By default (`nil`) every endpoint instance, and so every request, picks a short random namespace. A page
    /// and the HTML of other requests inserted into it (a `showModal(ref:contentURL:)` body, markup fetched by
    /// your own scripts) therefore never share an element id.
    ///
    /// Set a fixed namespace (letters and digits, starting with a letter; other characters are dropped) to
    /// make the output deterministic: the same page then renders byte-identical HTML on every request, which
    /// allows snapshot tests and ETags. Use a different namespace for each endpoint whose HTML ends up in the
    /// same browser page. Set it before the page creates its first element, e.g. in `init()` or at the top of
    /// `content()`.
    public var elementIdNamespace: String? = nil
    /// How many element ids this endpoint has handed out.
    internal var elementIdCounter: Int = 0
    /// The namespace used while `elementIdNamespace` is `nil`: picked once per endpoint instance.
    internal lazy var randomElementIdNamespace: String = WebElementId.randomNamespace()
    /// `elementIdNamespace` as last sanitized, so it is checked once rather than for every element.
    internal var sanitizedElementIdNamespace: (raw: String, value: String?)? = nil
    /// `clientDeviceKind` of `request`, worked out once per request.
    internal var deviceKindCache: (request: HttpRequest, kind: WebClientDeviceKind)? = nil

    // default content methods
    open func content() -> Any? {
        return HttpResponse().status(.notFound)
    }
    
    open func persist() -> Any? {
        return HttpResponse().status(.notFound)
    }
    
}

class Test : CoreWebEndpoint, WebEndpoint, WebContent {

    public required init() {
        super.init()
    }
    
    var controller: String? = "test"
    
    var method: String? = nil
    
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    
    override func content() -> Any? {
        return HttpResponse().status(.ok).content(.text).body("Hello, World!")
    }
      
    func acceptedRoles(for action: WebRequestActivity) -> [String]? {
        return nil
    }
    
}


// MARK: - CoreWebsocketEndpoint

open class CoreWebsocketEndpoint: CoreWebEndpoint, @unchecked Sendable {
    
    public required init() {
        super.init()
    }
    
    // Tick interval for onTick callbacks (seconds). Set to <= 0 to disable ticking.
    open var tickInterval: TimeInterval = 1.0

    /// Largest WebSocket frame payload a client may send, in bytes (default 1 MiB).
    /// Larger frames are refused with close code 1009. Override, or set in `init()`,
    /// to change it for this endpoint; `onOpen` can also adjust `connection.maxFrameBytes`.
    open var maxFrameBytes: Int = WebSocketConnection.defaultMaxFrameBytes

    /// Largest message a client may send after fragments are joined, in bytes (default 1 MiB).
    /// Larger messages are refused with close code 1009.
    open var maxMessageBytes: Int = WebSocketConnection.defaultMaxMessageBytes

    // Auth requirements default: unauthenticated
    open var authenticationRequired: [WebAuthenticationStatus] { get { [.unauthenticated] } set { /* ignored in base */ } }

    // Lifecycle hooks
    open func onOpen(connection: WebSocketConnection, request: HttpRequest) {}
    open func onTick(connection: WebSocketConnection) {}
    open func onClose(connection: WebSocketConnection, code: UInt16?, reason: String?) {}

    // Frame handler: return frames to send back, or nil to send nothing
    open func onFrame(connection: WebSocketConnection, frame: WebSocketFrame) -> [WebSocketFrame]? {
        // Default: echo text frames
        if frame.opcode == .text, let s = String(data: frame.payload, encoding: .utf8) {
            let reply = WebSocketFrame(fin: true, opcode: .text, payload: Data("Echo: \(s)".utf8))
            return [reply]
        }
        return nil
    }

    private var tickTimer: DispatchSourceTimer?

    /// Starts the WebSocket loop on `upgrade.socketFD` and takes ownership of the descriptor:
    /// when the loop ends it releases the descriptor through `WebSocketConnection.closeSocket()`.
    ///
    /// Call this only after the HTTP 101 response has been completely written, and do not
    /// touch the descriptor afterwards. Otherwise the loop can close the descriptor while the
    /// HTTP side still writes to or closes it, and the number can be reused by another client.
    public func startWebSocket(_ upgrade: WebSocketUpgrade) {
        let conn = WebSocketConnection(fd: upgrade.socketFD,
                                       maxFrameBytes: self.maxFrameBytes,
                                       maxMessageBytes: self.maxMessageBytes)
        conn.endpoint = self
        self.request = HttpRequest(head: self.request.head, body: self.request.body) // keep initial request context
        self.onOpen(connection: conn, request: self.request)

        // Simple periodic tick using `tickInterval` (default 1s). Override `onTick` in subclass.
        if tickInterval > 0 {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            let intervalMs = max(1, Int(self.tickInterval * 1000))
            timer.schedule(deadline: .now() + .milliseconds(intervalMs),
                           repeating: .milliseconds(intervalMs))
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                // Don't call onTick if the connection is already closed
                guard !conn.isClosed else { return }
                self.onTick(connection: conn)
            }
            self.tickTimer = timer
            timer.resume()
        }

        // Frame loop
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                conn.closeSocket()
                return
            }
            // closeSocket() is idempotent and waits for in-flight I/O, so an endpoint that
            // closes the socket itself in onTick/onFrame cannot cause a second close().
            defer {
                self.tickTimer?.cancel()
                self.tickTimer = nil
                conn.closeSocket()
            }
            do {
                try conn.run { [weak self] frame in
                    guard let self = self else { return nil }
                    return self.onFrame(connection: conn, frame: frame)
                }
                // The peer's close code and reason, when it sent a Close frame.
                self.onClose(connection: conn, code: conn.receivedCloseCode, reason: conn.receivedCloseReason)
            } catch let violation as WebSocketProtocolError {
                // The connection already sent this close code to the peer.
                self.onClose(connection: conn, code: violation.closeCode, reason: violation.reason)
            } catch {
                self.onClose(connection: conn, code: nil, reason: String(describing: error))
            }
        }
    }
}
