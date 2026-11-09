//
//  Phase1RenderSupportTests.swift
//  WSwiftUITests
//
//  Helpers for the Phase 1 render slice (LAYOUT-11, LAYOUT-16, CORE-25, CORE-26, M12):
//   - `RenderDOM`: a small HTML tree builder for the renderer's own output (void elements, raw-text
//     `<script>` / `<style>`, RCDATA `<textarea>` / `<title>`), which also records what an HTML parser would
//     repair or ignore (end tags of void elements, repeated attributes, stray end tags);
//   - `RenderInvariants`: the invariants every rendered page must satisfy, as a list of violations;
//   - `renderDeterministic` / `RenderPage`: render DSL through the real dispatch path with a fixed element id
//     namespace (byte-identical output), on a private server per call;
//   - `RenderKitchenSink`: a page that uses every object, modifier, action and variable kind.
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - A small HTML tree

final class RenderNode {
    enum Kind { case document, element, text, comment, doctype }
    let kind: Kind
    /// Lower-cased tag name for elements.
    let name: String
    /// Attributes in source order (a repeated one is kept here, an HTML parser keeps only the first).
    var attributes: [(name: String, value: String?)]
    var children: [RenderNode] = []
    weak var parent: RenderNode?
    /// Text content (text and comment nodes, and the raw body of script / style / textarea / title).
    var text: String

    init(kind: Kind, name: String = "", attributes: [(name: String, value: String?)] = [], text: String = "") {
        self.kind = kind
        self.name = name
        self.attributes = attributes
        self.text = text
    }

    func attribute(_ key: String) -> String? {
        attributes.first(where: { $0.name == key })?.value.map(RenderDOM.decode)
    }

    var classes: [String] {
        (attribute("class") ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    var elementChildren: [RenderNode] { children.filter { $0.kind == .element } }

    var nextElementSibling: RenderNode? {
        guard let parent else { return nil }
        let siblings = parent.children
        guard let index = siblings.firstIndex(where: { $0 === self }) else { return nil }
        return siblings[(index + 1)...].first(where: { $0.kind == .element })
    }

    /// This node and every node below it, in document order.
    var descendants: [RenderNode] {
        var out: [RenderNode] = []
        var stack: [RenderNode] = [self]
        while let node = stack.popLast() {
            out.append(node)
            stack.append(contentsOf: node.children.reversed())
        }
        return out
    }

    func elements(named tag: String) -> [RenderNode] {
        descendants.filter { $0.kind == .element && $0.name == tag }
    }

    func first(named tag: String) -> RenderNode? {
        descendants.first { $0.kind == .element && $0.name == tag }
    }
}

enum RenderDOM {

    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link",
                                            "meta", "source", "track", "wbr"]
    static let rawTextElements: Set<String> = ["script", "style", "textarea", "title"]

    struct Parsed {
        let document: RenderNode
        /// Things an HTML parser would repair or drop: `</input>`, repeated attributes, stray end tags, ...
        var problems: [String]
        var doctypeFirst: Bool
    }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func parse(_ html: String) -> Parsed {
        let chars = Array(html.unicodeScalars)
        let document = RenderNode(kind: .document)
        var stack: [RenderNode] = [document]
        var problems: [String] = []
        var index = 0
        var textStart = 0
        var doctypeFirst = false
        var sawAnything = false

        func flushText(_ end: Int) {
            guard end > textStart else { return }
            let text = String(String.UnicodeScalarView(chars[textStart..<end]))
            let node = RenderNode(kind: .text, text: text)
            node.parent = stack.last
            stack.last!.children.append(node)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { sawAnything = true }
        }
        func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\n" || c == "\t" || c == "\r" || c == "\u{0C}" }
        func isNameChar(_ c: Unicode.Scalar) -> Bool { !isSpace(c) && c != ">" && c != "/" && c != "=" && c != "\"" && c != "'" && c != "<" }
        func hasPrefix(_ s: String, at i: Int, caseInsensitive: Bool = true) -> Bool {
            let p = Array(s.unicodeScalars)
            guard i + p.count <= chars.count else { return false }
            for k in 0..<p.count {
                let a = caseInsensitive ? Character(chars[i + k]).lowercased() : String(chars[i + k])
                let b = caseInsensitive ? Character(p[k]).lowercased() : String(p[k])
                if a != b { return false }
            }
            return true
        }

        while index < chars.count {
            guard chars[index] == "<" else { index += 1; continue }
            if hasPrefix("<!--", at: index) {
                flushText(index)
                let start = index + 4
                var end = start
                while end < chars.count && !hasPrefix("-->", at: end) { end += 1 }
                let node = RenderNode(kind: .comment, text: String(String.UnicodeScalarView(chars[start..<min(end, chars.count)])))
                node.parent = stack.last
                stack.last!.children.append(node)
                index = min(end + 3, chars.count)
                textStart = index
                continue
            }
            if hasPrefix("<!doctype", at: index) {
                flushText(index)
                if sawAnything == false && stack.count == 1 && document.children.allSatisfy({ $0.kind == .text }) {
                    doctypeFirst = index == 0
                }
                var end = index
                while end < chars.count && chars[end] != ">" { end += 1 }
                let node = RenderNode(kind: .doctype, text: String(String.UnicodeScalarView(chars[index..<min(end + 1, chars.count)])))
                document.children.append(node)
                index = min(end + 1, chars.count)
                textStart = index
                sawAnything = true
                continue
            }
            if index + 1 < chars.count, chars[index + 1] == "/" {
                // end tag
                var j = index + 2
                let nameStart = j
                while j < chars.count && isNameChar(chars[j]) { j += 1 }
                let name = String(String.UnicodeScalarView(chars[nameStart..<j])).lowercased()
                while j < chars.count && chars[j] != ">" { j += 1 }
                flushText(index)
                index = min(j + 1, chars.count)
                textStart = index
                if voidElements.contains(name) {
                    problems.append("end tag </\(name)> for a void element")
                    continue
                }
                if let open = stack.lastIndex(where: { $0.kind == .element && $0.name == name }), open > 0 {
                    if open != stack.count - 1 {
                        problems.append("</\(name)> closes unclosed <\(stack[(open + 1)...].map { $0.name }.joined(separator: ">, <"))>")
                    }
                    stack.removeSubrange(open...)
                } else {
                    problems.append("stray end tag </\(name)>")
                }
                continue
            }
            // start tag?
            var j = index + 1
            guard j < chars.count, (chars[j].properties.isAlphabetic) else { index += 1; continue }
            flushText(index)
            let nameStart = j
            while j < chars.count && isNameChar(chars[j]) { j += 1 }
            let name = String(String.UnicodeScalarView(chars[nameStart..<j])).lowercased()
            var attributes: [(name: String, value: String?)] = []
            var selfClosing = false
            while j < chars.count {
                while j < chars.count && isSpace(chars[j]) { j += 1 }
                if j >= chars.count { break }
                if chars[j] == ">" { j += 1; break }
                if chars[j] == "/" {
                    if j + 1 < chars.count && chars[j + 1] == ">" { selfClosing = true; j += 2; break }
                    j += 1
                    continue
                }
                let attrStart = j
                while j < chars.count && isNameChar(chars[j]) { j += 1 }
                if j == attrStart { j += 1; continue }
                let attrName = String(String.UnicodeScalarView(chars[attrStart..<j])).lowercased()
                var k = j
                while k < chars.count && isSpace(chars[k]) { k += 1 }
                var value: String? = nil
                if k < chars.count && chars[k] == "=" {
                    k += 1
                    while k < chars.count && isSpace(chars[k]) { k += 1 }
                    if k < chars.count && (chars[k] == "\"" || chars[k] == "'") {
                        let quote = chars[k]
                        let valueStart = k + 1
                        var valueEnd = valueStart
                        while valueEnd < chars.count && chars[valueEnd] != quote { valueEnd += 1 }
                        value = String(String.UnicodeScalarView(chars[valueStart..<min(valueEnd, chars.count)]))
                        j = min(valueEnd + 1, chars.count)
                    } else {
                        let valueStart = k
                        var valueEnd = k
                        while valueEnd < chars.count && !isSpace(chars[valueEnd]) && chars[valueEnd] != ">" { valueEnd += 1 }
                        value = String(String.UnicodeScalarView(chars[valueStart..<valueEnd]))
                        j = valueEnd
                    }
                }
                if attributes.contains(where: { $0.name == attrName }) {
                    problems.append("<\(name)> repeats the attribute \(attrName)")
                }
                attributes.append((attrName, value))
            }
            let node = RenderNode(kind: .element, name: name, attributes: attributes)
            node.parent = stack.last
            stack.last!.children.append(node)
            sawAnything = true
            index = j
            textStart = index
            if voidElements.contains(name) || selfClosing {
                continue
            }
            if rawTextElements.contains(name) {
                // raw text up to the matching end tag (`</script` followed by space, `/` or `>`)
                var end = index
                while end < chars.count {
                    if chars[end] == "<", hasPrefix("</\(name)", at: end) {
                        let after = end + 2 + name.count
                        if after >= chars.count || isSpace(chars[after]) || chars[after] == ">" || chars[after] == "/" { break }
                    }
                    end += 1
                }
                node.text = String(String.UnicodeScalarView(chars[index..<min(end, chars.count)]))
                var close = end
                while close < chars.count && chars[close] != ">" { close += 1 }
                index = min(close + 1, chars.count)
                textStart = index
                continue
            }
            stack.append(node)
        }
        flushText(chars.count)
        if stack.count > 1 {
            problems.append("unclosed elements at the end: <\(stack.dropFirst().map { $0.name }.joined(separator: ">, <"))>")
        }
        return Parsed(document: document, problems: problems, doctypeFirst: doctypeFirst)
    }

    /// The code an attribute runs: an inline event handler (`on...`) or a `javascript:` URL (in any
    /// attribute, as a browser reads it: leading spaces and controls ignored, tabs and line breaks removed,
    /// the scheme in any case); `nil` for any other attribute.
    static func code(ofAttribute name: String, value: String?) -> String? {
        let decoded = decode(value ?? "")
        if name.hasPrefix("on") { return decoded }
        var text = Substring(decoded)
        while let first = text.unicodeScalars.first, first.value <= 0x20 { text = text.dropFirst() }
        let cleaned = String(text).replacingOccurrences(of: "\t", with: "").replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard cleaned.lowercased().hasPrefix("javascript:") else { return nil }
        return String(cleaned.dropFirst("javascript:".count))
    }

    /// Identifier-shaped tokens of a script or handler (string contents included).
    static func identifierTokens(_ text: String) -> Set<String> {
        var tokens = Set<String>()
        var current = ""
        var inNumber = false
        for scalar in text.unicodeScalars {
            let isStart = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || scalar == "_" || scalar == "$"
            let isDigit = scalar >= "0" && scalar <= "9"
            if current.isEmpty && !inNumber {
                if isStart { current.unicodeScalars.append(scalar) } else if isDigit { inNumber = true }
            } else if inNumber {
                if !(isStart || isDigit) { inNumber = false }
            } else if isStart || isDigit {
                current.unicodeScalars.append(scalar)
            } else {
                tokens.insert(current)
                current = ""
            }
        }
        if current.isEmpty == false { tokens.insert(current) }
        return tokens
    }
}

// MARK: - Invariants

enum RenderInvariants {

    /// The shape of a generated element id: `<namespace>_<base-36 counter>`.
    static let generatedIdPattern = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9]*_[0-9a-z]+$")

    static func isGeneratedId(_ token: String) -> Bool {
        generatedIdPattern.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length)) != nil
    }

    /// Registered element globals: the `var <id>, <id>, ...;` that opens the registration block (looked up one by
    /// one with `__wsuiElement("<id>")`, or, for many, in one walk over the document).
    static func registeredIds(in html: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\nvar ([A-Za-z_$][\w$]*(?:, [A-Za-z_$][\w$]*)*);\n\(function \(__wsuiDocument"#)
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return [] }
        let declared = ns.substring(with: match.range(at: 1)).components(separatedBy: ", ")
        // and each one is looked up: one by one, or listed for the walk over the document
        var lookedUp = Set<String>()
        let single = try! NSRegularExpression(pattern: #"\n([A-Za-z_$][\w$]*) = __wsuiElement\("([^"]+)"\);"#)
        for m in single.matches(in: html, range: NSRange(location: 0, length: ns.length))
            where ns.substring(with: m.range(at: 1)) == ns.substring(with: m.range(at: 2)) {
            lookedUp.insert(ns.substring(with: m.range(at: 1)))
        }
        let bulk = try! NSRegularExpression(pattern: #"\}\)\(document, \[([^\]]*)\]\);"#)
        if let m = bulk.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) {
            for item in ns.substring(with: m.range(at: 1)).components(separatedBy: ", ") {
                lookedUp.insert(item.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
        }
        return declared.filter { lookedUp.contains($0) }
    }

    /// Every violation of the page invariants (empty when the page is fine).
    static func violations(in html: String) -> [String] {
        var out: [String] = []
        let parsed = RenderDOM.parse(html)
        let document = parsed.document

        // 1. the doctype comes first
        if html.hasPrefix("<!DOCTYPE html>") == false || parsed.doctypeFirst == false {
            out.append("the page does not start with <!DOCTYPE html>")
        }
        // HTML-parser repairs: void end tags, repeated attributes, stray end tags
        out.append(contentsOf: parsed.problems)

        guard let head = document.first(named: "head"), let body = document.first(named: "body") else {
            out.append("no <head> or <body>")
            return out
        }

        // 2. exactly one charset declaration, the first element of <head>
        let charsetMetas = document.elements(named: "meta").filter { meta in
            meta.attributes.contains { $0.name == "charset" }
                || (meta.attribute("http-equiv")?.lowercased() == "content-type")
        }
        if charsetMetas.count != 1 {
            out.append("\(charsetMetas.count) character set declarations (expected 1)")
        }
        if let first = head.elementChildren.first, !(first.name == "meta" && first.attribute("charset")?.lowercased() == "utf-8") {
            out.append("the first element of <head> is <\(first.name)>, not <meta charset=\"utf-8\">")
        }

        // 3. no <script> among the body's content: scripts are direct children of <body>, after its last
        //    other node
        var seenScript = false
        for child in body.children {
            switch child.kind {
                case .element where child.name == "script":
                    seenScript = true
                case .text where child.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    break
                default:
                    if seenScript {
                        out.append("<\(child.kind == .element ? child.name : "#text")> after a <script> in <body>")
                    }
            }
        }
        for script in body.elements(named: "script") where script.parent !== body {
            out.append("<script> inside the body's content (in <\(script.parent?.name ?? "?")>)")
        }

        // 6. id attributes are unique
        var ids: [String: Int] = [:]
        for element in document.descendants where element.kind == .element {
            if let id = element.attribute("id") { ids[id, default: 0] += 1 }
        }
        for (id, count) in ids where count > 1 {
            out.append("id \"\(id)\" is used \(count) times")
        }

        // 9. no stray name="HTML" wrapper
        if html.contains("name=\"HTML\"") {
            out.append("a name=\"HTML\" element")
        }

        // 7 + 8. scripts and handlers only refer to element globals and per-variable functions that exist
        let scripts = document.elements(named: "script").filter { $0.attribute("src") == nil }.map { $0.text }
        var handlerTexts: [String] = []
        for element in document.descendants where element.kind == .element {
            for attribute in element.attributes {
                if let code = RenderDOM.code(ofAttribute: attribute.name, value: attribute.value) {
                    handlerTexts.append(code)
                }
            }
        }
        let allCode = scripts + handlerTexts
        var pageIds = Set<String>()
        for element in body.descendants where element.kind == .element {
            for cls in element.classes where isGeneratedId(cls) { pageIds.insert(cls) }
        }
        let registered = Set(registeredIds(in: html))
        let joinedScripts = scripts.joined(separator: "\n")
        var referencedTokens = Set<String>()
        for code in allCode { referencedTokens.formUnion(RenderDOM.identifierTokens(code)) }
        for id in referencedTokens.intersection(pageIds).sorted() {
            let defined = joinedScripts.contains("var \(id) = ") || joinedScripts.contains("function \(id)(")
            if registered.contains(id) == false && defined == false {
                out.append("\(id) is referenced by a script or handler but neither registered nor defined")
            }
        }
        for id in registered where pageIds.contains(id) == false {
            out.append("\(id) is registered but no element has that class")
        }
        let functionPrefixes = ["addCallback", "updateWebVariable", "addWebVariableEventListener", "notifyWebVariable",
                                "emitWebVariableEvent"]
        for token in referencedTokens.sorted() {
            guard let prefix = functionPrefixes.first(where: { token.hasPrefix($0) && token.count > $0.count }) else { continue }
            let suffix = String(token.dropFirst(prefix.count))
            guard isGeneratedId(suffix) else { continue }
            if joinedScripts.contains("function \(token)(") == false {
                out.append("\(token) is called but never defined")
            }
        }
        return out
    }

    /// Records an issue for every violation.
    static func expectValid(_ html: String, _ label: String = "page", sourceLocation: SourceLocation = #_sourceLocation) {
        for violation in violations(in: html) {
            Issue.record("\(label): \(violation)", sourceLocation: sourceLocation)
        }
    }

    /// The trailing `<script>` elements of <body>, in order.
    static func bodyScripts(_ html: String) -> [RenderNode] {
        RenderDOM.parse(html).document.first(named: "body")?.elements(named: "script") ?? []
    }
}

// MARK: - Rendering

/// A content endpoint for the render slice: its whole `content()` is a closure, and `namespace` (when set) is
/// its `elementIdNamespace`, so the same page renders the same bytes.
final class RenderPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "phase1-render"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    nonisolated(unsafe) static var build: ((RenderPage) -> Void)? = nil
    nonisolated(unsafe) static var namespace: String? = nil

    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }

    /// Used by the server for `renderPage(...)`, which sets `namespace` under its lock first.
    required init() {
        super.init()
        elementIdNamespace = RenderPage.namespace
    }

    /// An endpoint with its own namespace that never reads the shared `namespace` (so `buildPage` needs no
    /// lock while `renderPage` runs on another thread).
    init(fixedNamespace: String?) {
        super.init()
        elementIdNamespace = fixedNamespace
    }

    override func content() -> Any? {
        return webpage {
            RenderPage.build?(self)
        }
    }
}

private let renderPageLock = NSLock()

/// Renders the DSL in `build` (inside `webpage {}`) through the real dispatch path, with `namespace` as the
/// element id namespace (`nil`: a random one, as in production). Serialized with this file's own lock.
func renderPage(namespace: String? = "t", headers: [(String, String)] = [], _ build: @escaping (RenderPage) -> Void) -> String {
    renderPageLock.lock()
    defer { renderPageLock.unlock() }
    RenderPage.build = build
    RenderPage.namespace = namespace
    defer {
        RenderPage.build = nil
        RenderPage.namespace = nil
    }
    let server = TestHTTP.server()
    server.register(RenderPage())
    return server.respond(to: TestHTTP.request(.GET, "/phase1-render", headers: headers)).bodyString
}

/// Builds the DSL in `build` on a fresh endpoint (with `namespace`) and returns the endpoint, without
/// rendering, for tests that call `renderWebPage()` themselves.
func buildPage(namespace: String? = "t", _ build: (RenderPage) -> Void) -> RenderPage {
    let page = RenderPage(fixedNamespace: namespace)
    _ = page.webpage {
        build(page)
    }
    return page
}

// MARK: - Kitchen sink

enum RenderKitchenSink {

    /// Every object, modifier, action and variable kind of the library on one page.
    ///
    /// Every part of it is deterministic: AccordionItem ids come from builderIds, and Chart and FileUploader
    /// JSON has sorted keys.
    static func build(_ page: CoreWebEndpoint) {
        let name = page.WString("Ada").name("name")
        let age = page.WInt(36).name("age")
        let ratio = page.WDouble(0.5).name("ratio")
        let flag = page.WBool(true).name("flag")
        let tags = page.WArray(["a", "b"]).name("tags")
        let choice = page.WString("two").name("choice")
        let segment = page.WString("left").name("segment")
        let radio = page.WString("r1").name("radio")
        let showModal = page.WBool(false)
        let showPanel = page.WBool(false)
        let alertShown = page.WBool(true)
        let progress = page.WInt(40)
        let progressD = page.WDouble(0.25)
        let live = page.WString("live").name("live")
        live.liveUpdate(url: "/live", reference: "ks", actions: [.read, .write], related: [name],
                        onRequest: [.addClass("busy")], onResponse: [.removeClass("busy")], pollEverySeconds: 30)
        name.onValueChanged([.text(ref: "ks-status", "changed")])
        age.onLiveUpdateError([.alert("failed")])

        page.head(.title("Kitchen sink"))
        page.head(.metaViewport(content: "width=device-width"))
        page.head(.metaDescription("all controls"))
        page.head(.link(rel: .icon, href: "/favicon.ico", type: "image/x-icon", attributes: ["data-b": "2", "data-a": "1"]))
        page.head(.script(src: "/app.js", defer: true, attributes: ["data-z": "z", "data-y": "y"]))
        page.head(.inlineStyle("body { margin: 0 }"))
        page.head(.comment("kitchen sink"))

        page.NavBar(brand: "Brand") {
            page.NavBarItem(title: "Home", href: "/", active: true)
            page.NavDropdown(title: "More", id: "ks-more") {
                page.NavDropdownHeader("Header")
                page.NavDropdownItem(title: "Item", href: "/item")
            }
        }
        page.Breadcrumb {
            page.BreadcrumbItem(title: "Home", url: "/")
            page.BreadcrumbItem(title: "Here", url: "/here", active: true)
        }
        page.Jumbotron {
            page.JumbotronTitle("Jumbo")
            page.JumbotronSubtitle("Subtitle")
        }
        page.VStack {
            page.Text("Plain text").bold().foreground(.red).padding(4).font(.title)
            page.Text("$0 is $1", name, age)
            page.Text(name)
            page.Link("/somewhere", title: "A link")
            page.Image("/img.png", alt: "image").rounded().reloadImage(seconds: 60)
            page.Code(language: .swift, "let x = 1")
            page.Badge("New", variant: .primary)
            page.Callout(.info) { page.Text("Callout") }
            page.Audio("/a.mp3")
            page.Spacer()
            page.Flex { page.Text("Flex") }
            page.HStack {
                page.Button("Toggle flag").onClick(.toggle(flag))
                page.Button("Set name").onClick([.setVariable(name, to: "Grace"), .addClass("x"), .removeClass("y")])
                page.Button("Hide").hidden(flag)
                page.Button("Disable").disabled(flag)
                page.Button("Visually hidden").visuallyHidden()
            }
            page.ListGroup {
                page.ListGroupItem("One")
                page.ListGroupItem("Two").onClick(.navigate("/two"))
                page.ListGroupItem("Three", variant: .secondary)
            }
            page.Picker("Choice", selection: choice, style: .menu) {
                page.Text("one")
                page.Text("two")
            }
            page.Picker("Segment", selection: segment, style: .segmented(.primary)) {
                page.Text("left")
                page.Text("right")
            }
            page.Picker("Radio", selection: radio, style: .radio(.vertical)) {
                page.Text("r1")
                page.Text("r2")
            }
        }
        page.Form(action: "/submit") {
            page.TextField("Name", text: name, prompt: "Your name").validate([.notEmpty])
            page.SecureField("Password", text: page.WString("").name("password"))
            page.TextArea(value: page.WString("notes").name("notes"))
            page.Toggle("Flag", isOn: flag)
            page.Button("Submit", type: "submit")
        }
        page.Card {
            page.CardHeader { page.Text("Card header") }
            page.CardBody { page.Text("Card body") }
            page.CardFooter { page.Text("Card footer") }
        }
        page.Table {
            page.TableHeader {
                page.Row { page.Cell { page.Text("H") } }
            }
            page.TableBody {
                page.Row { page.Cell { page.Text("C") }.align("right") }
            }
        }
        page.Accordion {
            page.AccordionItem(title: "Section") { page.Text("Accordion body") }
        }.expandFirst(true)
        page.Alert("Heads up", isPresented: alertShown, variant: .warning, message: "Bound alert", dismissible: true)
        page.Progress {
            page.ProgressBar(progress, max: 100)
        }
        page.Progress {
            page.ProgressBar(progressD, max: 1.0)
        }
        page.Modal(id: "ks-modal", isPresented: showModal) {
            page.ModalDialog {
                page.ModalContent {
                    page.ModalHeader { page.ModalTitle { page.Text("Title") } }
                    page.ModalBody { page.Text("Modal body") }
                    page.ModalFooter { page.Button("Close").onClick(.hideModal(ref: "ks-modal")) }
                }
            }
        }
        page.OffCanvas(id: "ks-panel", isPresented: showPanel) {
            page.OffCanvasBody { page.Text("Panel") }
        }
        page.Chart(type: .bar, labels: ["a", "b"], dataSets: [ChartDataSet(label: "Set", values: [1, 2])])
        // `extraFields` is JSON-encoded with sorted keys, so its order is the same on every render
        page.FileUploader(action: "/upload", extraFields: ["a": "1", "b": "2", "c": "3", "d": "4"],
                          onUpload: [.alert("uploaded")]) {
            page.Text("Drop files")
        }
        page.Spinner("Loading")
        page.Pagination {
            page.PaginationItem(page: 1, href: "?p=1", active: true)
        }
        page.Carousel(id: "ks-carousel") {
            page.CarouselInner {
                page.CarouselItem(active: true) { page.Text("Slide") }
            }
        }
        page.WebSocket(url: "/ws", onRecieve: [.text(ref: "ks-status", "message")])
        page.Text("status").id("ks-status")
        page.Footer {
            page.Text("Footer")
        }.sticky().collapseOnScroll(threshold: 50)

        // actions of every kind, on buttons
        page.HStack {
            page.Button("Actions").onClick([
                .post(url: "/post", values: [name, age], onSuccessful: [.extractJSONInto(key: "a.b", into: name)],
                      onFailed: [.alert("no")], onTimeout: [.alert("slow")], resultInto: tags),
                .get(url: "/get", params: [name], onSuccessful: [.extractJSON(key: "x", actions: [.evaluate(op: .isTrue, [.reload], nil)])]),
                .random([.addClass("a"), .addClass("b")]),
                .if(flag, .isTrue, [.show(ref: "ks-status")], [.hide(ref: "ks-status")]),
                .showModal(ref: "ks-modal"),
                .showModal(ref: "ks-modal", contentURL: "/fragment"),
                .hidden(ref: "ks-status", false),
                .setBackgroundColor(ref: nil, color: .blue),
                .fadeIn(ref: "ks-status", duration: 0.2),
                .addToArray(variable: tags, value: "c"),
                .localStorageSet(key: "k", value: name),
                .clipboardCopy(name),
                .delay(seconds: 0.1, actions: [.focus(ref: "ks-status")]),
                .confirm("Sure?", ifYes: [.alert("yes")], ifNo: nil),
                .setStyles(ref: nil, styles: ["color": "red", "background": "blue"]),
                .regexExtract(source: name, pattern: "(a)", group: 1, into: name),
            ])
            page.Button("Events").onDblClick([.alert("double")], options: EventOptions(debounceMs: 10))
                .onMouseover([.addClass("hover")]).onMouseLeave([.removeClass("hover")])
                .onEnterKey([.click(ref: "ks-status")]).onTimer(seconds: 60, [.reload])
        }
        page.TextField(binding: ratio)
    }
}
