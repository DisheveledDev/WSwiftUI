//
//  Phase1RenderKitchenSinkTests.swift
//  WSwiftUITests
//
//  Phase 1 render slice: the page invariants on a page that uses every object, modifier, action and variable
//  kind (`RenderKitchenSink`), and the checker itself.
//

import Foundation
import Testing
@testable import WSwiftUI

@Suite("Phase 1 render: invariants of the kitchen-sink page")
struct Phase1RenderKitchenSinkTests {

    @Test func kitchenSinkSatisfiesEveryInvariant() {
        let html = renderPage { page in RenderKitchenSink.build(page) }
        RenderInvariants.expectValid(html, "kitchen sink")
        // the page really exercises the script machinery
        #expect(RenderInvariants.registeredIds(in: html).count > 10)
        #expect(html.contains("function addCallbackt_"))
    }

    @Test func kitchenSinkWithARandomNamespaceSatisfiesEveryInvariant() {
        let html = renderPage(namespace: nil) { page in RenderKitchenSink.build(page) }
        RenderInvariants.expectValid(html, "kitchen sink (random namespace)")
    }

    @Test func kitchenSinkOnAMobileClientSatisfiesEveryInvariant() {
        let html = renderPage(headers: [("Sec-CH-UA-Mobile", "?1")]) { page in RenderKitchenSink.build(page) }
        #expect(html.contains("data-wsui-device=\"mobile\""))
        RenderInvariants.expectValid(html, "kitchen sink (mobile)")
    }

    @Test func kitchenSinkHasNoScriptInsideBodyContentAndOneFrameworkBlock() throws {
        let html = renderPage { page in RenderKitchenSink.build(page) }
        let body = try #require(RenderDOM.parse(html).document.first(named: "body"))
        let scripts = body.elements(named: "script")
        #expect(scripts.allSatisfy { $0.parent === body })
        // all of it is framework code (the kitchen sink has no raw JavaScript), so it shares one <script>
        // element: registrations, every element script and the DOMContentLoaded listener
        #expect(scripts.count == 1)
        let block = try #require(scripts.first?.text)
        #expect(block.contains("__wsuiElement(") && block.contains("} catch (e) { __wsuiReport(e); }"))
        #expect(block.contains("document.addEventListener('DOMContentLoaded'"))
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func kitchenSinkScriptsParseAsClassicScripts() throws {
        let html = renderPage { page in RenderKitchenSink.build(page) }
        let scripts = ScriptScan.inlineScripts(in: html)
        let result = try NodeJS.run(scripts: scripts)
        #expect(result.syntaxErrors == [])
    }

    /// The whole kitchen sink, Accordion, Chart and FileUploader `extraFields` included, renders the same bytes
    /// every time.
    @Test func kitchenSinkRendersByteIdenticallyInDeterministicMode() {
        let first = renderPage { page in RenderKitchenSink.build(page) }
        let second = renderPage { page in RenderKitchenSink.build(page) }
        let third = buildPage(namespace: "t") { page in RenderKitchenSink.build(page) }.renderWebPage()
        #expect(first == second)
        #expect(first == third)
        RenderInvariants.expectValid(first)
        if first != second {
            let a = first.split(separator: "\n"), b = second.split(separator: "\n")
            if let index = zip(a, b).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                Issue.record("first difference at line \(index): \(a[index].prefix(200)) vs \(b[index].prefix(200))")
            }
        }
    }
}

@Suite("Phase 1 render: the invariant checker")
struct Phase1RenderCheckerTests {

    static let goodPage = """
    <!DOCTYPE html>
    <html lang="en">
        <head>
            <meta charset="utf-8" />
        </head>
        <body>
            <input class="t_1" id="hiddenInput_t_1" type="hidden" value="">
            <button class="t_2" onclick="updateWebVariablet_1(1)"></button>
            <script>
    var t_2;
    (function (__wsuiDocument) {
    function __wsuiElement(id) { return __wsuiDocument.getElementsByClassName(id)[0]; }
    t_2 = __wsuiElement("t_2");
    })(document);
    try {
    var t_1 = 0;
    function addCallbackt_1(c) {}
    function updateWebVariablet_1(v) {}
    t_2.addEventListener('click', function () { addCallbackt_1(1); });
    } catch (e) { __wsuiReport(e); }
            </script>
        </body>
    </html>
    """

    @Test func aGoodPagePasses() {
        #expect(RenderInvariants.violations(in: Self.goodPage) == [])
    }

    @Test func everyViolationIsFound() {
        func violations(_ replace: String, with: String) -> [String] {
            let html = Self.goodPage.replacingOccurrences(of: replace, with: with)
            #expect(html != Self.goodPage, "fixture not changed by \(replace)")
            return RenderInvariants.violations(in: html)
        }
        #expect(violations("<!DOCTYPE html>\n", with: "").contains { $0.contains("DOCTYPE") })
        #expect(violations("<meta charset=\"utf-8\" />", with: "<title>x</title><meta charset=\"utf-8\" />").contains { $0.contains("first element of <head>") })
        #expect(violations("</head>", with: "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=latin1\"></head>").contains { $0.contains("2 character set declarations") })
        #expect(violations("value=\"\">", with: "value=\"\"></input>").contains { $0.contains("</input>") })
        #expect(violations("type=\"hidden\"", with: "type=\"hidden\" type=\"text\"").contains { $0.contains("repeats the attribute type") })
        #expect(violations("<button class=\"t_2\"", with: "<button id=\"hiddenInput_t_1\" class=\"t_2\"").contains { $0.contains("is used 2 times") })
        #expect(violations("</button>", with: "</button><script>var a = 1;</script><p>after</p>").contains { $0.contains("after a <script>") })
        #expect(violations("t_2 = __wsuiElement(\"t_2\");\n", with: "").contains { $0.contains("t_2 is referenced") })
        // a javascript: URL is code too
        #expect(violations("<button class=\"t_2\"", with: "<a class=\"t_3\"></a><a href=\" JavaScript:t_3.click()\">x</a><button class=\"t_2\"")
            .contains { $0.contains("t_3 is referenced") })
        #expect(violations("function addCallbackt_1(c) {}", with: "").contains { $0.contains("addCallbackt_1 is called but never defined") })
        #expect(violations("<button class", with: "<div name=\"HTML\"></div><button class").contains { $0.contains("name=\"HTML\"") })
        #expect(violations("<button class=\"t_2\"", with: "<div><script>x()</script></div><button class=\"t_2\"").contains { $0.contains("inside the body's content") })
    }
}
