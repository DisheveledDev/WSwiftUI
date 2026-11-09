//
//  Phase1DocumentTests.swift
//  WSwiftUITests
//
//  Phase 1, document slice: the synthetic document root (no created element is swallowed by becoming the
//  root, `webpage {}` adds no wrapper), the doctype and charset, void elements, and the isolation of
//  DOMContentLoaded scripts.
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Helpers

/// A content endpoint whose whole `content()` is supplied by a closure, so a test can create elements
/// before, inside and after `webpage {}` (`renderHTML` always wraps its body in `webpage {}`).
final class Phase1DocPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "phase1-document"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    nonisolated(unsafe) static var build: ((Phase1DocPage) -> Any?)? = nil

    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }

    override func content() -> Any? {
        return Phase1DocPage.build?(self)
    }
}

private let phase1DocLock = NSLock()

/// Renders the page `build` returns through the real dispatch path, on a private server.
/// Calls are serialized with this file's own lock, so it is safe to use from parallel tests.
func phase1DocRender(_ build: @escaping (Phase1DocPage) -> Any?) -> String {
    phase1DocLock.lock()
    defer { phase1DocLock.unlock() }
    Phase1DocPage.build = build
    defer { Phase1DocPage.build = nil }
    let server = TestHTTP.server()
    server.register(Phase1DocPage())
    return server.respond(to: TestHTTP.request(.GET, "/phase1-document")).bodyString
}

extension CoreWebEndpoint {
    /// The shape of the demo's and AppGrill's `Template`: head elements and page chrome around the content,
    /// all inside `webpage {}`.
    func phase1DocTemplate(_ content: WebComposerClosure) -> WebElement {
        webpage {
            head(.metaViewport(content: "width=device-width, initial-scale=1"))
            NavBar(brand: "Brand") {
                NavBarItem(title: "Home", href: "/", active: true)
            }
            HStack {
                VStack(mode: .fill) {
                    content()
                }
            }
            Footer {
                Text("footer-text")
            }
        }
    }
}

enum Phase1DocScan {

    /// The functions each reactive variable defines and the page calls.
    static let variableFunctionPattern = #"(function\s+)?\b((?:addCallback|updateWebVariable|addWebVariableEventListener|notifyWebVariable)[0-9a-z_]+)\s*\("#

    static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return (text as NSString).substring(with: range)
    }

    /// Per-variable functions the page calls anywhere (inline scripts and inline event-handler attributes).
    static func referencedVariableFunctions(in html: String) -> Set<String> {
        var names = Set<String>()
        for match in matches(variableFunctionPattern, in: html) where group(match, 1, in: html) == nil {
            if let name = group(match, 2, in: html) { names.insert(name) }
        }
        return names
    }

    /// Functions declared (`function name(`) in the page's inline scripts.
    static func definedFunctions(in html: String) -> Set<String> {
        let scripts = ScriptScan.inlineScripts(in: html).joined(separator: "\n")
        var names = Set<String>()
        for match in matches(#"function\s+([A-Za-z_$][\w$]*)\s*\("#, in: scripts) {
            if let name = group(match, 1, in: scripts) { names.insert(name) }
        }
        return names
    }

    /// Variable functions the page calls but never defines (each one is a ReferenceError in the browser).
    static func undefinedVariableFunctions(in html: String) -> [String] {
        return referencedVariableFunctions(in: html).subtracting(definedFunctions(in: html)).sorted()
    }

    static func section(_ html: String, from start: String, to end: String) -> String? {
        guard let a = html.range(of: start), let b = html.range(of: end, range: a.upperBound..<html.endIndex) else {
            return nil
        }
        return String(html[a.upperBound..<b.lowerBound])
    }

    /// The page's DOMContentLoaded `<script>` bodies, joined. (The framework's DOMContentLoaded scripts share
    /// one listener; a raw one, e.g. added by a test, gets a `<script>` element and a listener of its own.)
    static func domContentLoadedScript(in html: String) -> String? {
        let scripts = ScriptScan.inlineScripts(in: html).filter { $0.contains("addEventListener('DOMContentLoaded'") }
        return scripts.isEmpty ? nil : scripts.joined(separator: "\n")
    }

    /// The `__wsuiReport` definition at the top of the page's first framework script.
    static func reportFunction(in html: String) -> String? {
        guard let start = html.range(of: "function __wsuiReport(e) {") else { return nil }
        guard let end = html.range(of: "\n", range: start.upperBound..<html.endIndex) else { return nil }
        return String(html[start.lowerBound..<end.lowerBound])
    }

    /// `{op, path, value}` records with the given op and path from a node harness run.
    static func records(_ result: NodeJS.Result, op: String, path: String) -> [[String: Any]] {
        return result.records.compactMap { $0 as? [String: Any] }.filter {
            ($0["op"] as? String) == op && ($0["path"] as? String) == path
        }
    }
}

// MARK: - Doctype and charset (M11 / LAYOUT-10 / CORE-21)

@Suite("phase1 document: doctype and charset")
struct Phase1DocumentHeadTests {

    @Test func doctypeIsTheFirstThingInThePage() {
        let html = renderHTML { page in
            page.Text("hello")
        }
        #expect(html.hasPrefix("<!DOCTYPE html>\n<html lang=\"en\">\n"), "page starts with: \(html.prefix(60).debugDescription)")
        #expect(ScriptScan.matches(of: "<!doctype", in: html) == 1)
    }

    @Test func doctypeIsFirstForATemplatePageWithStateDeclaredFirst() {
        let html = phase1DocRender { page in
            let flag = page.WBool(false)
            return page.phase1DocTemplate {
                page.Text("$0", flag)
            }
        }
        #expect(html.hasPrefix("<!DOCTYPE html>\n"))
    }

    @Test func charsetMetaIsTheFirstHeadElement() throws {
        let html = renderHTML { page in
            page.head(.metaViewport(content: "width=device-width, initial-scale=1"))
            page.head(.title("Doc title"))
            page.Text("hello")
        }
        let head = try #require(Phase1DocScan.section(html, from: "<head>", to: "</head>"))
        let firstElement = head.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(firstElement.hasPrefix("<meta charset=\"utf-8\""), "head starts with: \(firstElement.prefix(80).debugDescription)")
        // the rest of the head is kept, in order
        let viewport = try #require(head.range(of: "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\""))
        let title = try #require(head.range(of: "<title>Doc title</title>"))
        #expect(viewport.lowerBound < title.lowerBound)
        // an encoding declaration only counts within the first 1024 bytes
        let start = String(decoding: Array(html.utf8.prefix(1024)), as: UTF8.self)
        #expect(start.contains("<meta charset=\"utf-8\""))
    }

    @Test func aCharsetThePageAddsIsDeclaredOnceAndFirst() throws {
        let html = renderHTML { page in
            page.head(.metaViewport(content: "width=device-width"))
            page.head(.metaCharset("UTF-8"))
            page.Text("hello")
        }
        let head = try #require(Phase1DocScan.section(html, from: "<head>", to: "</head>"))
        #expect(ScriptScan.matches(of: "charset=", in: head) == 1)
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<meta charset=\"utf-8\""))
        #expect(head.contains("<meta name=\"viewport\" content=\"width=device-width\""))
    }
}

// MARK: - Synthetic document root (H8 / CORE-06 / DATA-3 / ERG-2)

@Suite("phase1 document: synthetic root")
struct Phase1DocumentRootTests {

    @Test func elementsCreatedOutsideAContainerHangFromTheDocumentRoot() {
        let endpoint = CoreWebEndpoint()
        #expect(endpoint.parent === endpoint.documentRoot)
        let first = endpoint.WString("first")
        var inside: WebElement? = nil
        let page = endpoint.webpage {
            #expect(endpoint.parent is WebFragmentElement)
            inside = endpoint.create { $0.elementName = "p" }
        }
        let after = endpoint.create { $0.elementName = "p" }
        #expect(endpoint.parent === endpoint.documentRoot)
        let expected: [WebElement] = [first, page, after]
        #expect(endpoint.documentRoot.subElements.map { ObjectIdentifier($0) } == expected.map { ObjectIdentifier($0) })
        #expect(page is WebFragmentElement)
        #expect(page.subElements.count == 1 && page.subElements.first === inside)
    }

    @Test func variableDeclaredBeforeTheTemplateIsRenderedAndItsFunctionsAreDefined() throws {
        var firstId = ""
        var flagId = ""
        let html = phase1DocRender { page in
            // state declared at the top of content(), as AppGrill's ApplicationEditPage does
            let first = page.WString("FIRST-VAR")
            let flag = page.WBool(false)
            firstId = first.builderId
            flagId = flag.builderId
            return page.phase1DocTemplate {
                page.Text("Value: $0", first)
                _ = page.TextField(binding: first)
                _ = page.Modal(id: "phase1DocModal", isPresented: flag) {
                    page.Text("modal body")
                }
                page.Button("Show").onClick(.setVariable(flag, to: true))
            }
        }
        // both variables are emitted: their hidden inputs and their function definitions
        #expect(html.contains("id=\"hiddenInput_\(firstId)\""))
        #expect(html.contains("id=\"hiddenInput_\(flagId)\""))
        #expect(html.contains("function addCallback\(firstId)("))
        #expect(html.contains("function updateWebVariable\(firstId)("))
        #expect(html.contains("function updateWebVariable\(flagId)("))
        #expect(html.contains("FIRST-VAR"))

        // every per-variable function the page calls is defined somewhere in it
        let referenced = Phase1DocScan.referencedVariableFunctions(in: html)
        #expect(referenced.contains("addCallback\(firstId)"))
        #expect(referenced.contains("updateWebVariable\(flagId)"))
        #expect(Phase1DocScan.undefinedVariableFunctions(in: html) == [])
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func templatePageWithStateDeclaredFirstHasValidScripts() throws {
        let html = phase1DocRender { page in
            let first = page.WString("FIRST-VAR")
            return page.phase1DocTemplate {
                page.Text("$0", first)
            }
        }
        let scripts = ScriptScan.inlineScripts(in: html)
        #expect(scripts.isEmpty == false)
        let result = try NodeJS.run(scripts: scripts)
        #expect(result.syntaxErrors == [])
    }

    @Test func everyCreatedElementIsEmittedOnceInCreationOrder() {
        var created: [WebElement] = []
        let html = phase1DocRender { page in
            func marker(_ text: String) {
                created.append(page.create { el in
                    el.elementName = "p"
                    el.innerHTML(text)
                })
            }
            marker("marker-0")   // created first: this one used to become the invisible root
            let body = page.webpage {
                marker("marker-1")
                page.VStack {
                    marker("marker-2")
                    page.HStack {
                        marker("marker-3")
                    }
                }
                marker("marker-4")
            }
            marker("marker-5")   // created after webpage {}
            return body
        }
        var lastPosition = html.startIndex
        for index in 0...5 {
            let text = ">marker-\(index)</p>"
            #expect(ScriptScan.occurrences(of: text, in: html) == 1, "\(text) emitted \(ScriptScan.occurrences(of: text, in: html)) times")
            if let range = html.range(of: text) {
                #expect(range.lowerBound > lastPosition, "\(text) is out of creation order")
                lastPosition = range.lowerBound
            }
        }
        for element in created {
            #expect(ScriptScan.occurrences(of: "class=\"\(element.builderId)\"", in: html) == 1)
        }
    }

    @Test func noStrayHTMLWrapperAndNoTagForThePage() {
        var pageIds: [String] = []
        let stateFirst = phase1DocRender { page in
            let flag = page.WBool(false)
            let body = page.phase1DocTemplate {
                page.Text("$0", flag)
            }
            pageIds.append(body.builderId)
            return body
        }
        let pageFirst = phase1DocRender { page in
            let body = page.phase1DocTemplate {
                page.Text("plain")
            }
            pageIds.append(body.builderId)
            return body
        }
        for (html, pageId) in zip([stateFirst, pageFirst], pageIds) {
            #expect(html.contains("name=\"HTML\"") == false)
            // `lang` is declared once, on <html>
            #expect(ScriptScan.occurrences(of: "lang=\"en\"", in: html) == 1)
            // the page fragment has no element, so nothing (not even a registration script) refers to it
            #expect(html.contains(pageId) == false)
        }
    }

    @Test func webpageAddsNoWrapperElement() throws {
        let html = renderHTML { page in
            _ = page.create { el in
                el.elementName = "p"
                el.innerHTML("first-child")
            }
        }
        let body = try #require(Phase1DocScan.section(html, from: "data-wsui-device=\"desktop\">\n", to: "</body>"))
        #expect(body.hasPrefix("        <p class=\""), "body starts with: \(body.prefix(80).debugDescription)")
        #expect(body.contains(">first-child</p>"))
    }

    @Test func scriptsAttachedToThePageFragmentStillRun() throws {
        let html = phase1DocRender { page in
            let body = page.webpage {
                page.Text("content")
            }
            body.script("window.phase1FragmentScript = 1;")
            body.addAttribute(.domLoadedScript("window.phase1FragmentLoaded = 1;"))
            body.class("ignored-class")
            return body
        }
        #expect(html.contains("<script>window.phase1FragmentScript = 1;</script>"))
        let domLoaded = try #require(Phase1DocScan.domContentLoadedScript(in: html))
        #expect(domLoaded.contains("window.phase1FragmentLoaded = 1;"))
        // a fragment has no tag for a class to go on
        #expect(html.contains("ignored-class") == false)
    }
}

// MARK: - Void elements (CORE-26)

@Suite("phase1 document: void elements")
struct Phase1DocumentVoidElementTests {

    static let voidElements = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                               "source", "track", "wbr"]

    @Test func voidElementsHaveNoEndTags() {
        let html = renderHTML { page in
            for name in Self.voidElements {
                _ = page.create { $0.elementName = name }
            }
            _ = page.create { el in
                el.elementName = "IMG"
                el.src("upper.png")
            }
            page.Image("picture.png", alt: "picture")
            let bound = page.WString("bound")
            _ = page.TextField(binding: bound)
            _ = page.create { el in
                el.elementName = "div"
                el.id("phase1-plain-div")
            }
            _ = page.create { el in
                el.elementName = "textarea"
                el.id("phase1-plain-textarea")
            }
        }
        for name in Self.voidElements {
            #expect(ScriptScan.matches(of: "</\(name)[\\s>]", in: html) == 0, "</\(name)> emitted")
            #expect(ScriptScan.matches(of: "<\(name) class=\"[0-9a-z_]+\"", in: html) >= 1, "<\(name)> missing")
        }
        #expect(html.contains("<img class=\"") && html.contains("src=\"picture.png\""))
        #expect(html.contains("src=\"upper.png\">"))
        // the bound variable's hidden input is emitted once; its definition script now runs from the end of
        // <body>, so no script follows the input
        #expect(ScriptScan.matches(of: "id=\"hiddenInput_[0-9a-z_]+\"[^>]*>", in: html) == 1)
        #expect(ScriptScan.matches(of: "id=\"hiddenInput_[0-9a-z_]+\"[^>]*>\\s*<script>", in: html) == 0)
        #expect(ScriptScan.matches(of: "function addCallback[0-9a-z_]+\\(", in: html) == 1)
        // non-void elements keep their end tags
        #expect(html.contains("id=\"phase1-plain-div\"></div>"))
        #expect(html.contains("id=\"phase1-plain-textarea\"></textarea>"))
    }

    @Test func contentNestedInAVoidElementIsEmittedOnceAfterIt() throws {
        let html = renderHTML { page in
            let image = page.create { el in
                el.elementName = "img"
                el.src("nested.png")
            }
            page.stack.append(image)
            _ = page.create { el in
                el.elementName = "span"
                el.innerHTML("nested-in-void")
            }
            page.stack.removeAll { $0 === image }
        }
        #expect(html.contains("</img>") == false)
        #expect(ScriptScan.occurrences(of: ">nested-in-void</span>", in: html) == 1)
        let image = try #require(html.range(of: "src=\"nested.png\">"))
        let nested = try #require(html.range(of: "nested-in-void"))
        #expect(image.upperBound < nested.lowerBound)
    }
}

// MARK: - DOMContentLoaded isolation (H12, renderer part)

@Suite("phase1 document: DOMContentLoaded scripts")
struct Phase1DocumentDomLoadedTests {

    static let documentStub = "({ handlers: [], addEventListener: function (name, fn) { if (name === 'DOMContentLoaded') { this.handlers.push(fn); } } })"
    static let consoleStub = "({ error: function (e) { __deep('consoleError')(String(e && e.message || e)); } })"
    /// A bound function prints as `[native code]`, like the browser's own reportError.
    static let nativeReportErrorStub = "(function (e) { __deep('reportError')(String(e && e.message || e)); }).bind(null)"
    /// A page's own helper of the same name.
    static let appReportErrorStub = "(function (e) { __deep('reportError')(String(e && e.message || e)); })"
    static let fireDOMContentLoaded = "document.handlers.forEach(function (fn) { fn(); });"

    static func render(domLoaded scripts: [String]) -> String {
        return renderHTML { page in
            for script in scripts {
                _ = page.create { $0.addAttribute(.domLoadedScript(script)) }
            }
        }
    }

    @Test func domContentLoadedScriptIsInsideTheBody() throws {
        let html = Self.render(domLoaded: ["window.phase1Inside = 1;"])
        let listener = try #require(html.range(of: "addEventListener('DOMContentLoaded'"))
        let bodyEnd = try #require(html.range(of: "</body>"))
        #expect(listener.lowerBound < bodyEnd.lowerBound)
        #expect(html.hasSuffix("    </body>\n</html>\n"))
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func aThrowingScriptDoesNotStopTheNextOne() throws {
        let html = Self.render(domLoaded: [
            "throw new Error('first-script-failed');",
            "window.secondScriptRan = 42;",
        ])
        let script = try #require(Phase1DocScan.domContentLoadedScript(in: html))
        let report = try #require(Phase1DocScan.reportFunction(in: html))
        // the failure is reported, not swallowed: with the browser's reportError (as an uncaught exception would
        // be, so window 'error' listeners see it), or with console.error where reportError doesn't exist or is
        // a function of the page's own
        for (reportError, reportedTo, notTo) in [(Self.nativeReportErrorStub, "reportError", "consoleError"),
                                                 ("undefined", "consoleError", "reportError"),
                                                 (Self.appReportErrorStub, "consoleError", "reportError")] {
            let result = try NodeJS.run(scripts: [report, script], code: report + "\n" + script,
                                        globals: ["document": Self.documentStub, "console": Self.consoleStub,
                                                  "reportError": reportError, "Function": "Function"],
                                        after: Self.fireDOMContentLoaded)
            #expect(result.syntaxErrors == [])
            #expect(result.error == nil, "the listener threw: \(result.error ?? "")")
            let ran = Phase1DocScan.records(result, op: "set", path: "window.secondScriptRan")
            #expect(ran.count == 1 && (ran.first?["value"] as? Int) == 42)
            let logged = Phase1DocScan.records(result, op: "call", path: reportedTo)
            #expect(logged.count == 1 && (logged.first?["args"] as? [String]) == ["first-script-failed"], "\(reportedTo)")
            #expect(Phase1DocScan.records(result, op: "call", path: notTo).isEmpty, "\(notTo)")
        }
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func scriptsHaveTheirOwnScopeAndMayEndInALineComment() throws {
        let html = Self.render(domLoaded: [
            "let shared = 'a'; window.thirdScript = shared;",
            "let shared = 'b'; window.fourthScript = shared;",
            "window.fifthScript = 5; // ends in a line comment",
            "window.sixthScript = 6;",
        ])
        let script = try #require(Phase1DocScan.domContentLoadedScript(in: html))
        let result = try NodeJS.run(scripts: [script], code: script,
                                    globals: ["document": Self.documentStub, "console": Self.consoleStub],
                                    after: Self.fireDOMContentLoaded)
        #expect(result.syntaxErrors == [])
        #expect(result.error == nil)
        #expect((Phase1DocScan.records(result, op: "set", path: "window.thirdScript").first?["value"] as? String) == "a")
        #expect((Phase1DocScan.records(result, op: "set", path: "window.fourthScript").first?["value"] as? String) == "b")
        #expect((Phase1DocScan.records(result, op: "set", path: "window.fifthScript").first?["value"] as? Int) == 5)
        #expect((Phase1DocScan.records(result, op: "set", path: "window.sixthScript").first?["value"] as? Int) == 6)
        #expect(Phase1DocScan.records(result, op: "call", path: "consoleError").isEmpty)
    }
}
