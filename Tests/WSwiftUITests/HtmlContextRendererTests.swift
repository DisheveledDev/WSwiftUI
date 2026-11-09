//
//  HtmlContextRendererTests.swift
//  WSwiftUITests
//
//  Renderer-level HTML context guarantees (BaseWebEndpoint+Render.swift).
//

import Foundation
import Testing
@testable import WSwiftUI

@Suite("html-context: renderer")
struct HtmlContextRendererTests {

    @Test func passwordInputNeverRendersAValue() {
        let html = renderHTML { page in
            _ = page.create { el in
                el.elementName = "input"
                el.type("password")
                el.value("hunter2-typed")
            }
            _ = page.create { el in
                el.elementName = "input"
                el.addAttribute(.pair("type", "PASSWORD"))
                el.value("hunter2-pair")
            }
            _ = page.create { el in
                el.elementName = "input"
                el.type("text")
                el.value("plain-value")
            }
        }
        #expect(html.contains("hunter2-typed") == false)
        #expect(html.contains("hunter2-pair") == false)
        #expect(html.contains("value=\"plain-value\""))
    }

    @Test(arguments: htmlCtxPayloads)
    func labelsErrorMessagesAndOptionsAreEscaped(_ payload: String) {
        let html = renderHTML { page in
            _ = page.create { el in
                el.elementName = "input"
                el.label(payload)
                el.addAttribute(.errorMessage(payload))
                el.placeholder(payload)
                el.value(payload)
            }
        }
        htmlCtxExpectNoLiveMarkup(html)
        htmlCtxExpectNotDoubleEscaped(html)
        #expect(html.contains(">\(WebEscape.html(payload))</label>"))
        #expect(html.contains(">\(WebEscape.html(payload))</div>"))
        #expect(html.contains("placeholder=\"\(WebEscape.attribute(payload))\""))
    }

    @Test func attributeNamesCannotInjectAttributes() {
        let html = renderHTML { page in
            _ = page.create { el in
                el.elementName = "div"
                el.addAttribute(.pair("data-x onmouseover", "1"))
                el.addAttribute(.pair("aria-label", "ok"))
                el.data("y\" onclick=\"alert(1)")
            }
            page.head(.link(rel: .other("preload"), href: "/font.woff2",
                            attributes: ["as\" onload=\"alert(1)": "font"]))
            page.head(.script(src: "/a.js", attributes: ["data-website-id": "abc"]))
            page.head(.custom(tag: "meta", attributes: ["x onerror": "y"], innerHTML: nil))
        }
        #expect(html.contains(" onmouseover=") == false)
        #expect(html.contains(" onclick=") == false)
        #expect(html.contains(" onload=") == false)
        #expect(html.contains(" onerror=") == false)
        #expect(html.contains("data-xonmouseover=\"1\""))
        #expect(html.contains("aria-label=\"ok\""))
        // ordinary names are untouched
        #expect(html.contains("data-website-id=\"abc\""))
    }

    @Test func headCommentCannotBeClosedEarly() {
        let html = renderHTML { page in
            page.head(.comment("--><script>alert(1)</script><!--"))
            page.head(.comment("built by WSwiftUI"))
        }
        htmlCtxExpectNoLiveMarkup(html)
        #expect(html.contains("<!-- built by WSwiftUI -->"))
    }

    @Test(arguments: htmlCtxPayloads)
    func headValuesAreEscaped(_ payload: String) {
        let html = renderHTML { page in
            page.head(.metaDescription(payload))
            page.head(.metaProperty(property: "og:title", content: payload))
            page.head(.link(rel: .other("canonical"), href: payload))
            page.head(.title(payload))
        }
        htmlCtxExpectNoLiveMarkup(html)
        htmlCtxExpectNotDoubleEscaped(html)
        #expect(html.contains("content=\"\(WebEscape.attribute(payload))\""))
        #expect(html.contains("<title>\(WebEscape.html(payload))</title>"))
    }

    @Test func syntaxHelpers() {
        #expect(WebHTMLSyntax.attributeName("data-website-id") == "data-website-id")
        #expect(WebHTMLSyntax.attributeName("x\" y='z'>/=") == "xyz")
        #expect(WebHTMLSyntax.commentText("a --> b") == "a --&gt; b")
        #expect(WebHTMLSyntax.isPasswordType(" Password "))
        #expect(WebHTMLSyntax.isPasswordType("text") == false)
    }
}
