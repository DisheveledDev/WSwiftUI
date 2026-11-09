//
//  EscapingFoundationTests.swift
//  WSwiftUITests
//

import Foundation
import Testing
@testable import WSwiftUI

@Suite("WebEscape / WebJSON")
struct EscapingHelperTests {

    @Test func htmlEscapesTheFiveSpecialCharacters() {
        #expect(WebEscape.html(#"<a href="x">'&'</a>"#) == "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;")
        #expect(WebEscape.html("plain text") == "plain text")
        #expect(WebEscape.attribute("\"") == "&quot;")
    }

    @Test func scriptStringCannotCloseTheScriptElement() {
        let literal = WebJSON.scriptString("</script><script>alert(1)</script>")
        #expect(literal.contains("</") == false)
        #expect(literal.contains("<") == false)
        #expect(literal.hasPrefix("\"") && literal.hasSuffix("\""))
    }

    @Test func scriptStringRoundTripsThroughJSON() throws {
        let nasty = "O'Brien \"quoted\" \\ back\nslash\t<tag> & \u{2028}\u{2029} `tick` ${x} \u{0001}"
        let literal = WebJSON.scriptString(nasty)
        let decoded = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        #expect(decoded == nasty)
        #expect(literal.contains("'") == false)
        #expect(literal.contains("`") == false)
        #expect(literal.contains("\u{2028}") == false)
    }

    @Test func scriptLiteralAnyHandlesVariableTypes() {
        #expect(WebJSON.scriptLiteral(any: true) == "true")
        #expect(WebJSON.scriptLiteral(any: 42) == "42")
        #expect(WebJSON.scriptLiteral(any: 1.5) == "1.5")
        #expect(WebJSON.scriptLiteral(any: Double.nan) == "NaN")
        #expect(WebJSON.scriptLiteral(any: ["a", "</script>"]) == #"["a","\u003c/script\u003e"]"#)
        #expect(WebJSON.scriptLiteral(any: ["k": "<v>"]) == #"{"k":"\u003cv\u003e"}"#)
        #expect(WebJSON.scriptLiteral(any: Date()) == nil)   // not JSON-representable; must not crash
    }

    @Test func scriptLiteralEncodable() throws {
        struct Row: Codable, Equatable { var name: String; var when: Date }
        let row = Row(name: "</script>", when: Date(timeIntervalSince1970: 0))
        let literal = try #require(WebJSON.scriptLiteral(row))
        #expect(literal.contains("<") == false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Row.self, from: Data(literal.utf8)) == row)
    }
}

@Suite("Renderer central escaping", .serialized)
struct RendererEscapingTests {

    @Test func attributeValuesAreEscaped() {
        let html = renderHTML { page in
            let el = page.create { el in
                el.elementName = "a"
                el.addAttribute(.href("/x?a=1&b=\"2\""))
                el.addAttribute(.title("\"><script>alert(1)</script>"))
                el.addAttribute(.pair("data-x", "\"onmouseover=alert(1)"))
            }
            _ = el
        }
        #expect(html.contains("href=\"/x?a=1&amp;b=&quot;2&quot;\""))
        #expect(html.contains("<script>alert(1)</script>") == false)
        #expect(html.contains("data-x=\"&quot;onmouseover=alert(1)\""))
    }

    @Test func pageTitleIsEscaped() {
        let html = renderHTML { page in
            page.head(.title("</title><script>alert(1)</script>"))
        }
        #expect(html.contains("<title>&lt;/title&gt;&lt;script&gt;alert(1)&lt;/script&gt;</title>"))
    }
}
