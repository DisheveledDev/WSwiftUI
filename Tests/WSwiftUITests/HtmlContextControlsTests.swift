//
//  HtmlContextControlsTests.swift
//  WSwiftUITests
//
//  Every built-in control that shows caller-supplied text must HTML-escape it exactly once.
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Shared payloads and helpers (html-context slice)

/// Breaks out of an attribute value / injects a tag.
let htmlCtxAttrPayload = "\"><img src=x onerror=alert(1)>"
/// Breaks out of a <script> element / injects a script.
let htmlCtxScriptPayload = "</script><script>alert(1)</script>"
let htmlCtxPayloads = [htmlCtxAttrPayload, htmlCtxScriptPayload]

/// Asserts that neither payload's live markup appears anywhere in `html`.
func htmlCtxExpectNoLiveMarkup(_ html: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(html.contains("<img src=x onerror=alert(1)>") == false, sourceLocation: sourceLocation)
    #expect(html.contains("<script>alert(1)</script>") == false, sourceLocation: sourceLocation)
    #expect(html.contains("</script><script>alert(1)") == false, sourceLocation: sourceLocation)
}

/// Asserts that nothing in `html` was escaped twice.
func htmlCtxExpectNotDoubleEscaped(_ html: String, sourceLocation: SourceLocation = #_sourceLocation) {
    for entity in ["&amp;amp;", "&amp;lt;", "&amp;gt;", "&amp;quot;", "&amp;#39;", "&amp;#x2F;"] {
        #expect(html.contains(entity) == false, "double-escaped \(entity)", sourceLocation: sourceLocation)
    }
}

/// The first rendered line that opens `<tag ...>` and carries `builderId` (every element gets its builderId as a class).
func htmlCtxLine(_ html: String, tag: String, builderId: String) -> String? {
    return html.split(separator: "\n").map(String.init).first { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("<\(tag) ") && trimmed.contains(builderId)
    }
}

/// Captures values out of the (synchronously executed) `renderHTML` closure.
final class HtmlCtxBox: @unchecked Sendable {
    var ids: [String] = []
}

/// A control rendered with a caller-supplied text, and how that text is expected to be escaped.
struct HtmlCtxControlCase: Sendable, CustomTestStringConvertible {
    let name: String
    let escape: @Sendable (String) -> String
    let build: @Sendable (ClosurePage, String) -> Void
    var testDescription: String { name }
}

private let webEscaped: @Sendable (String) -> String = { WebEscape.html($0) }
private let textEscaped: @Sendable (String) -> String = { $0.escapedForHTML() }

/// Controls whose text is not bound to a variable, so the whole page can be checked.
let htmlCtxControlCases: [HtmlCtxControlCase] = [
    .init(name: "Button", escape: webEscaped) { page, t in page.Button(t) },
    .init(name: "Link title", escape: webEscaped) { page, t in page.Link("/x", title: t) },
    .init(name: "Link href", escape: webEscaped) { page, t in page.Link(t, title: "x") },
    .init(name: "Badge", escape: webEscaped) { page, t in page.Badge(t) },
    .init(name: "ListGroupItem", escape: webEscaped) { page, t in page.ListGroup { page.ListGroupItem(t) } },
    .init(name: "AccordionItem", escape: webEscaped) { page, t in page.Accordion { page.AccordionItem(title: t) {} } },
    .init(name: "BreadcrumbItem", escape: webEscaped) { page, t in page.Breadcrumb { page.BreadcrumbItem(title: t, url: t) } },
    .init(name: "NavBarItem", escape: webEscaped) { page, t in page.NavBar(brand: "Brand") { page.NavBarItem(title: t, href: t) } },
    .init(name: "NavDropdown", escape: webEscaped) { page, t in
        page.NavBar(brand: "Brand") { page.NavDropdown(title: t, id: t) { page.NavDropdownItem(title: t, href: t) } }
    },
    .init(name: "NavDropdownHeader", escape: webEscaped) { page, t in
        page.NavBar(brand: "Brand") { page.NavDropdown(title: "Menu", id: "menu") { page.NavDropdownHeader(t) } }
    },
    .init(name: "JumbotronTitle", escape: webEscaped) { page, t in page.Jumbotron { page.JumbotronTitle(t) } },
    .init(name: "JumbotronSubtitle", escape: webEscaped) { page, t in page.Jumbotron { page.JumbotronSubtitle(t) } },
    .init(name: "Spinner", escape: webEscaped) { page, t in page.Spinner(t) },
    .init(name: "Code", escape: webEscaped) { page, t in page.Code(language: .swift, t) },
    .init(name: "Text", escape: textEscaped) { page, t in page.Text(t) },
    .init(name: "Text(format:)", escape: textEscaped) { page, t in page.Text(t + " $0", page.WString("x")) },
    .init(name: "Toggle title", escape: textEscaped) { page, t in page.Toggle(t, isOn: page.WBool(false)) },
    .init(name: "Alert title/message", escape: textEscaped) { page, t in page.Alert(t, isPresented: page.WBool(true), message: t) },
    .init(name: "TextField label/prompt", escape: webEscaped) { page, t in page.TextField(t, text: page.WString(""), prompt: t) },
    .init(name: "SecureField label/prompt", escape: webEscaped) { page, t in page.SecureField(t, text: page.WString(""), prompt: t) },
    .init(name: "TextArea label/prompt", escape: webEscaped) { page, t in page.TextArea(t, text: page.WString(""), prompt: t) },
    .init(name: "Picker menu label/option", escape: webEscaped) { page, t in
        page.Picker(t, selection: page.WString("a")) {
            page.Text(t).value(t)
            page.Text("A").value("a")
        }
    },
    .init(name: "Picker radio option", escape: webEscaped) { page, t in
        page.Picker(selection: page.WString(""), style: .radio(.vertical)) { page.Text(t).value(t) }
    },
    .init(name: "Picker segmented option", escape: textEscaped) { page, t in
        page.Picker(selection: page.WString(""), style: .segmented(.primary)) { page.Text(t).value(t) }
    },
    .init(name: "Element title attribute", escape: webEscaped) { page, t in page.Text("x").title(t) },
    .init(name: "Footer collapsedClass", escape: { _ in "" }) { page, t in
        page.Footer { page.Text("footer") }.collapseOnScroll(threshold: 10, collapsedClass: t)
    },
]

// MARK: - Tests

@Suite("html-context: control text escaping")
struct HtmlContextControlsTests {

    @Test(arguments: htmlCtxControlCases, htmlCtxPayloads)
    func hostileTextIsEscapedOnce(_ control: HtmlCtxControlCase, payload: String) {
        let html = renderHTML { page in control.build(page, payload) }
        htmlCtxExpectNoLiveMarkup(html)
        htmlCtxExpectNotDoubleEscaped(html)
        let escaped = control.escape(payload)
        if escaped.isEmpty == false {
            #expect(html.contains(escaped), "expected the escaped text \(escaped)")
        }
    }

    @Test(arguments: htmlCtxControlCases)
    func ampersandIsEscapedExactlyOnce(_ control: HtmlCtxControlCase) {
        let html = renderHTML { page in control.build(page, "Tom & Jerry") }
        htmlCtxExpectNotDoubleEscaped(html)
        if control.escape("&").isEmpty == false {
            #expect(html.contains("Tom &amp; Jerry"))
        }
    }

    @Test func ordinaryTitlesAndHrefsAreUnchanged() {
        let html = renderHTML { page in
            page.Link("/privacy", title: "Privacy Policy")
            page.Link("/search?q=swift&page=2", title: "Search")
            page.Button("Save changes")
            page.Badge("Active")
            page.ListGroup { page.ListGroupItem("1. Upload a signed build") }
            page.NavBar(brand: "WSwiftUI") { page.NavBarItem(title: "Home", href: "/home", active: true) }
            page.Breadcrumb { page.BreadcrumbItem(title: "Install Apps", url: "/install") }
            page.Jumbotron { page.JumbotronTitle("Dashboard") }
        }
        #expect(html.contains("href=\"/privacy\""))
        #expect(html.contains(">Privacy Policy</a>"))
        #expect(html.contains("href=\"/search?q=swift&amp;page=2\""))
        #expect(html.contains(">Save changes</button>"))
        #expect(html.contains(">Active</span>"))
        #expect(html.contains(">1. Upload a signed build</li>"))
        #expect(html.contains("href=\"/home\""))
        #expect(html.contains(">Home</a>"))
        #expect(html.contains("href=\"/install\""))
        #expect(html.contains(">Install Apps</a>"))
        #expect(html.contains(">Dashboard</h1>"))
        htmlCtxExpectNotDoubleEscaped(html)
    }

    @Test func navBarBrandStaysTrustedRawHTML() {
        let html = renderHTML { page in
            page.NavBar(brand: "<img src=\"logo.png\" height=\"50\">") {
                page.NavBarItem(title: "<b>Item</b>", href: "/item")
            }
        }
        #expect(html.contains("<img src=\"logo.png\" height=\"50\">"))
        // ...while the items are still plain text
        #expect(html.contains("&lt;b&gt;Item&lt;/b&gt;"))
        #expect(html.contains("<b>Item</b>") == false)
    }

    @Test func innerHTMLModifierStaysRaw() {
        let html = renderHTML { page in
            page.Button("ignored").innerHTML("<i class=\"bi bi-trash\"></i> Delete")
        }
        #expect(html.contains("<i class=\"bi bi-trash\"></i> Delete"))
    }

    @Test func codeIsShownLiterallyWithWhitespacePreserved() {
        let source = "let html = \"<b>bold</b>\" && a < b\n    indented\tTab"
        let html = renderHTML { page in page.Code(language: .swift, source) }
        #expect(html.contains("<b>bold</b>") == false)
        #expect(html.contains("let html = &quot;&lt;b&gt;bold&lt;/b&gt;&quot; &amp;&amp; a &lt; b\n    indented\tTab"))
        #expect(html.contains("&nbsp;") == false)
        #expect(html.contains("<code class = \"language-swift\">"))
        htmlCtxExpectNotDoubleEscaped(html)
    }

    @Test func textGraphemeClusterCannotHideMarkup() {
        // U+0600 is a Prepend mark: it forms one grapheme cluster with the following "<".
        let hostile = "\u{0600}<img src=x onerror=alert(1)>"
        let rendered = renderHTML { page in
            page.Text(hostile)
            page.Toggle(hostile, isOn: page.WBool(false))
        }
        // String.contains is grapheme-based and would not "see" a "<" clustered with U+0600 (which is exactly
        // what a browser's tokenizer does see), so drop the mark before searching.
        let html = String(String.UnicodeScalarView(rendered.unicodeScalars.filter { $0 != "\u{0600}" }))
        htmlCtxExpectNoLiveMarkup(html)
        #expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
    }

    @Test func textEscapingKeepsItsLineBreakBehaviour() {
        #expect("a\nb".escapedForHTML() == "a<br>b")
        #expect("a & <b>".escapedForHTML() == "a &amp; &lt;b&gt;")
        #expect("café ©".escapedForHTML() == "café &copy;")
        #expect("e\u{0301}<".escapedForHTML() == "e\u{0301}&lt;")
    }

    @Test func formattedTextScriptUsesScriptSafeLiteral() {
        let html = renderHTML { page in
            page.Text("Hello `$0` ${x} </script><script>alert(1)</script>", page.WString("world"))
        }
        htmlCtxExpectNoLiveMarkup(html)
        #expect(html.contains("var fmt = \"Hello \\u0060$0\\u0060 ${x} \\u003c/script\\u003e"))
    }

    @Test func operatorEqualsUsesScriptSafeLiteral() throws {
        let condition = Operator.equals("</script><script>alert(1)</script>' + x + '").javascriptCondition
        #expect(condition.hasPrefix("== \""))
        #expect(condition.contains("<") == false)
        #expect(condition.contains("'") == false)
        let literal = String(condition.dropFirst(3))
        #expect(try JSONDecoder().decode(String.self, from: Data(literal.utf8)) == "</script><script>alert(1)</script>' + x + '")
        #expect(Operator.equals("on").javascriptCondition == "== \"on\"")
        #expect(Operator.equals(5).javascriptCondition == "== 5")
    }
}

@Suite("html-context: bound control values")
struct HtmlContextBoundValueTests {

    @Test(arguments: htmlCtxPayloads)
    func textBindingInitialValueIsEscaped(_ payload: String) throws {
        let box = HtmlCtxBox()
        let html = renderHTML { page in
            box.ids = [page.Text(page.WString(payload)).builderId]
        }
        let line = try #require(htmlCtxLine(html, tag: "span", builderId: box.ids[0]))
        htmlCtxExpectNoLiveMarkup(line)
        #expect(line.contains(payload.escapedForHTML()))
        htmlCtxExpectNotDoubleEscaped(line)
    }

    @Test func textBindingUpdatesAreWrittenAsText() throws {
        let box = HtmlCtxBox()
        let html = renderHTML { page in
            box.ids = [page.Text(page.WString("Tom & Jerry")).builderId]
        }
        let line = try #require(htmlCtxLine(html, tag: "span", builderId: box.ids[0]))
        #expect(line.contains(">Tom &amp; Jerry</span>"))
        #expect(html.contains("\(box.ids[0]).innerText = value;"))
        #expect(html.contains("\(box.ids[0]).innerHTML") == false)
    }

    @Test(arguments: htmlCtxPayloads)
    func textFieldValueIsEscaped(_ payload: String) throws {
        let box = HtmlCtxBox()
        let html = renderHTML { page in
            box.ids = [page.TextField("Name", text: page.WString(payload)).builderId]
        }
        let line = try #require(htmlCtxLine(html, tag: "input", builderId: box.ids[0]))
        htmlCtxExpectNoLiveMarkup(line)
        #expect(line.contains("value=\"\(WebEscape.attribute(payload))\""))
        htmlCtxExpectNotDoubleEscaped(line)
    }

    @Test func textFieldOrdinaryValueIsUnchanged() throws {
        let box = HtmlCtxBox()
        let html = renderHTML { page in
            box.ids = [page.TextField("Name", text: page.WString("Jane Doe")).builderId,
                       page.TextField("Company", text: page.WString("A&B Ltd")).builderId]
        }
        let first = try #require(htmlCtxLine(html, tag: "input", builderId: box.ids[0]))
        let second = try #require(htmlCtxLine(html, tag: "input", builderId: box.ids[1]))
        #expect(first.contains("value=\"Jane Doe\""))
        #expect(second.contains("value=\"A&amp;B Ltd\""))
        htmlCtxExpectNotDoubleEscaped(html)
    }

    @Test(arguments: htmlCtxPayloads)
    func textAreaContentIsEscaped(_ payload: String) throws {
        let box = HtmlCtxBox()
        let html = renderHTML { page in
            box.ids = [page.TextArea("Notes", text: page.WString(payload)).builderId]
        }
        let line = try #require(htmlCtxLine(html, tag: "textarea", builderId: box.ids[0]))
        htmlCtxExpectNoLiveMarkup(line)
        #expect(line.contains("</textarea>"))
        #expect(line.contains("&lt;"))
        htmlCtxExpectNotDoubleEscaped(line)
    }

    @Test(arguments: htmlCtxPayloads)
    func segmentedPickerHiddenBindingValueIsEscaped(_ payload: String) {
        let html = renderHTML { page in
            page.Picker(selection: page.WString(payload).name("choice"), style: .segmented(.primary)) {
                page.Text("A").value("a")
            }
        }
        #expect(html.contains("value=\"\(WebEscape.attribute(payload))\""))
    }
}
