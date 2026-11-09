//
//  Phase1RenderDocumentTests.swift
//  WSwiftUITests
//
//  Phase 1 render slice: the character set is declared once, head output is deterministic, an element never
//  carries an attribute twice, the device kind is worked out once per request (CORE-26).
//

import Foundation
import Testing
@testable import WSwiftUI

@Suite("Phase 1 render: document head and attributes")
struct Phase1RenderDocumentTests {

    @Test func conflictingCharsetDeclarationsAreDroppedAndLoggedOnce() throws {
        let html = renderPage { page in
            page.head(.metaHttpEquiv(httpEquiv: "Content-Type", content: "text/html; charset=iso-8859-1"))
            page.head(.custom(tag: "META", attributes: ["Charset": "windows-1252"], innerHTML: nil))
            page.head(.custom(tag: "meta", attributes: ["http-equiv": "content-type", "content": "text/html"], innerHTML: nil))
            page.head(.metaCharset("latin1"))
            page.head(.metaCharset("UTF-8"))
            page.head(.metaHttpEquiv(httpEquiv: "refresh", content: "30"))
            page.head(.custom(tag: "meta", attributes: ["name": "robots", "content": "none"], innerHTML: nil))
            page.Text("body")
        }
        RenderInvariants.expectValid(html)
        let head = try #require(RenderDOM.parse(html).document.first(named: "head"))
        let metas = head.elements(named: "meta")
        #expect(metas.filter { $0.attributes.contains { $0.name == "charset" } }.count == 1)
        #expect(metas.first?.attribute("charset") == "utf-8")
        #expect(metas.contains { $0.attribute("http-equiv")?.lowercased() == "content-type" } == false)
        // unrelated entries stay
        #expect(metas.contains { $0.attribute("http-equiv") == "refresh" })
        #expect(metas.contains { $0.attribute("name") == "robots" })

        // each contradicting declaration is logged once per endpoint type, a duplicate UTF-8 one never
        let endpoint = String(describing: RenderPage.self)
        for entry: WebCoreHeadElement in [.metaHttpEquiv(httpEquiv: "Content-Type", content: "text/html; charset=iso-8859-1"),
                                          .metaCharset("latin1")] {
            let declaration = try #require(WebHTMLDocument.charsetDeclaration(in: entry))
            #expect(declaration.contradicts)
            #expect(WebHTMLDocument.logDroppedCharset(endpoint: endpoint, declaration: declaration) == false, "logged again")
        }
        #expect(WebHTMLDocument.charsetDeclaration(in: .metaCharset("utf-8"))?.contradicts == false)
        #expect(WebHTMLDocument.charsetDeclaration(in: .metaHttpEquiv(httpEquiv: "refresh", content: "1")) == nil)
    }

    @Test func headAttributesAreEmittedInAFixedOrder() {
        let html = renderPage { page in
            page.head(.link(rel: .other("preload"), href: "/f.woff2", attributes: ["type": "font/woff2", "as": "font", "crossorigin": ""]))
            page.head(.script(src: "/a.js", attributes: ["data-z": "1", "data-a": "2", "data-m": "3"]))
            page.head(.custom(tag: "meta", attributes: ["name": "n", "content": "c", "data-x": "x"], innerHTML: nil))
        }
        RenderInvariants.expectValid(html)
        #expect(html.contains("<link rel=\"preload\" href=\"/f.woff2\" as=\"font\" crossorigin=\"\" type=\"font/woff2\" />"))
        #expect(html.contains("<script src=\"/a.js\" data-a=\"2\" data-m=\"3\" data-z=\"1\"></script>"))
        #expect(html.contains("<meta content=\"c\" data-x=\"x\" name=\"n\" />"))
    }

    @Test func anElementNeverCarriesTheSameAttributeTwice() throws {
        var id = ""
        let html = renderPage { page in
            id = page.create { el in
                el.elementName = "input"
                el.id("first-id")
                el.addAttribute(.pair("id", "second-id"))
                el.required()
                el.addAttribute(.custom("required"))
                el.addAttribute(.custom("data-x=\"1\""))
                el.data("x=2")
                el.class(el.builderId)          // the id class again, as several controls add it
                el.addAttribute(.custom("class=\"raw\""))
                el.addAttribute(.custom("loading=\"lazy\" decoding=\"async\""))   // two attributes: kept as is
            }.builderId
        }
        RenderInvariants.expectValid(html)
        let input = try #require(RenderDOM.parse(html).document.descendants.first { $0.classes.contains(id) })
        // the first of each wins, as an HTML parser would have it
        #expect(input.attribute("id") == "first-id")
        #expect(input.attribute("data-x") == "1")
        #expect(input.classes == [id])
        #expect(input.attribute("loading") == "lazy" && input.attribute("decoding") == "async")
        #expect(ScriptScan.occurrences(of: "required", in: html) == 1)
    }

    @Test func theValidationAttributeHasNoLeadingSpace() {
        let html = renderPage { page in
            let value = page.WString("").name("email")
            page.Form(action: "/x") {
                page.TextField("Email", text: value).validate([.notEmpty, .validEmail])
            }
        }
        RenderInvariants.expectValid(html)
        #expect(html.contains("validation=\"notEmpty,validEmail\""))
    }

    @Test func theDeviceKindIsWorkedOutOncePerRequest() {
        let endpoint = CoreWebEndpoint()
        let mobile = TestHTTP.request(.GET, "/", headers: [("User-Agent", "Mozilla/5.0 (iPhone)")])
        endpoint.request = mobile
        #expect(endpoint.clientDeviceKind == .mobile)
        #expect(endpoint.deviceKindCache?.request === mobile)
        // a new request is looked at afresh
        endpoint.request = TestHTTP.request(.GET, "/", headers: [("user-agent", "Mozilla/5.0 (Macintosh)"), ("Sec-CH-UA-Mobile", "?1")])
        #expect(endpoint.clientDeviceKind == .mobile)
        endpoint.request = TestHTTP.request(.GET, "/", headers: [("Sec-CH-UA-Mobile", "?0"), ("User-Agent", "iPhone")])
        #expect(endpoint.clientDeviceKind == .desktop)
        // like `headerMap`, a repeated header counts with its last value
        let repeated = TestHTTP.request(.GET, "/", headers: [("User-Agent", "Android"), ("user-agent", "Macintosh")])
        #expect(repeated.clientDeviceKind == .desktop)
        #expect(TestHTTP.request(.GET, "/").clientDeviceKind == .desktop)
    }

    @Test func deviceClassesFollowTheRequest() {
        let build: (RenderPage) -> Void = { page in
            for _ in 0..<5 {
                _ = page.create { $0.deviceClass(mobile: "on-mobile", desktop: "on-desktop") }
            }
        }
        let desktop = renderPage(build)
        let mobile = renderPage(headers: [("User-Agent", "Mozilla/5.0 (Linux; Android 14)")], build)
        RenderInvariants.expectValid(desktop)
        RenderInvariants.expectValid(mobile)
        #expect(ScriptScan.occurrences(of: "on-desktop", in: desktop) == 5)
        #expect(ScriptScan.occurrences(of: "on-mobile", in: mobile) == 5)
        #expect(desktop.contains("on-mobile") == false && mobile.contains("on-desktop") == false)
    }

    @Test func voidElementNamesAreMatchedInAnyCase() {
        #expect(WebHTMLDocument.isVoidElement("input"))
        #expect(WebHTMLDocument.isVoidElement("IMG"))
        #expect(WebHTMLDocument.isVoidElement("Br"))
        #expect(WebHTMLDocument.isVoidElement("div") == false)
        #expect(WebHTMLDocument.isVoidElement("DIV") == false)
    }

    @Test func scriptsFromAppCodeAreMarkedRawAndFrameworkScriptsAreNot() {
        let element = WebElement()
        element.script("app()")
        element.addAttribute(.domLoadedScript("appLoaded()"))
        element.addAttribute(.script("framework()"), file: "WSwiftUI/Somewhere.swift")
        let chunks = element.attributes.compactMap { attribute -> WebPageScriptChunk? in
            switch attribute {
                case .script(let js), .domLoadedScript(let js): return WebScriptOrigin.chunk(js)
                default: return nil
            }
        }
        #expect(chunks.map { $0.code } == ["app()", "appLoaded()", "framework()"])
        #expect(chunks.map { $0.isRaw } == [true, true, false])
        // compiled actions that carry raw JavaScript are marked too
        #expect(WebScriptOrigin.chunk(CompileActions([.script("x()")], builderId: "t_1")).isRaw)
        #expect(WebScriptOrigin.chunk(CompileActions([.setVariableFromExpression(into: WebVariableElement(), expression: "1+1")], builderId: "t_1")).isRaw)
        #expect(WebScriptOrigin.chunk(CompileActions([.navigate("/x")], builderId: "t_1")).isRaw == false)
        #expect(WebScriptOrigin.isFramework("WSwiftUI/X.swift"))
        #expect(WebScriptOrigin.isFramework("WSwiftUITests/X.swift") == false)
        #expect(WebScriptOrigin.isFramework("WSwiftUITest/main.swift") == false)
    }
}
