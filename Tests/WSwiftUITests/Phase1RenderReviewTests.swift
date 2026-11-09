//
//  Phase1RenderReviewTests.swift
//  WSwiftUITests
//
//  Phase 1 render slice, review fixes:
//   - the raw-JavaScript marker can't be forged by values: a value that looks like it is neither taken for
//     raw code nor changed;
//   - element references outside scripts register the element: `javascript:` URLs, every `.pair` and `.data`
//     value, head attribute values, and identifiers next to non-ASCII white space;
//   - classes and attributes are de-duplicated in order, also past the point where a set takes over;
//   - the deterministic kitchen sink renders the same bytes on many endpoint instances (Swift seeds each
//     dictionary's order separately, so this catches output that follows a dictionary's order).
//

import Foundation
import Testing
@testable import WSwiftUI

/// A `#fileID` inside the WSwiftUI module: scripts added "from" it count as framework code.
private let frameworkFile: StaticString = "WSwiftUI/Phase1RenderReviewFixture.swift"

private extension WebElement {
    @discardableResult
    func frameworkDOMLoaded(_ js: String) -> Self { addAttribute(.domLoadedScript(js), file: frameworkFile) }
}

/// The marker as the renderer uses it now, and the one an earlier version used (which values could contain).
private let markerLookalikes = [WebScriptOrigin.rawMarker, "/*wsui:raw*/"]

private func scalar(_ value: UInt32) -> String { String(Unicode.Scalar(value)!) }

@Suite("Phase 1 render review: the raw-JavaScript marker")
struct Phase1RenderRawMarkerTests {

    @Test func theMarkerCanNotBeWrittenByAScriptValue() {
        // every value the framework writes into a script goes through WebJSON, which never writes a `<`
        #expect(WebScriptOrigin.rawMarker.contains("<"))
        for marker in markerLookalikes {
            #expect(WebScriptOrigin.containsRawMarker(WebJSON.scriptString("a\(marker)b")) == false)
            #expect(WebScriptOrigin.containsRawMarker(WebJSON.scriptLiteral(any: ["k\(marker)": ["v\(marker)"]]) ?? "") == false)
            #expect(WebScriptOrigin.containsRawMarker(ScriptValue.loose("a\(marker)b")) == false)
        }
    }

    @Test(arguments: markerLookalikes)
    func valuesThatLookLikeTheMarkerAreKeptAndStayInTheFrameworkBlock(marker: String) throws {
        let values = ["x\(marker)y", "a\(marker)b", "c\(marker)d", "e\(marker)f", "/g\(marker)h"]
        let html = renderPage(namespace: "p") { page in
            let field = page.WString(values[0]).name("field")
            page.Text(field)
            page.Text("out").id("out")
            page.Button("b").onClick([.setVariable(field, to: values[1]), .alert(values[2]),
                                      .text(ref: "out", values[3]), .navigate(values[4])])
        }
        RenderInvariants.expectValid(html)
        // all of it is framework code: one <script> element, every chunk in its try/catch
        let scripts = RenderInvariants.bodyScripts(html)
        #expect(scripts.count == 1, "\(scripts.map { $0.text })")
        for value in values {
            #expect(html.contains(WebJSON.scriptString(value)), "\(value) is written into the script unchanged")
        }
        // the carrier submits the value it was given
        #expect(html.contains("value=\"\(WebEscape.attribute(values[0]))\""))
        #expect(html.contains(WebScriptOrigin.rawMarker) == false)
    }

    @Test(arguments: markerLookalikes)
    func aRawScriptKeepsTheValuesItCarries(marker: String) throws {
        let value = "q\(marker)r"
        let html = renderPage(namespace: "p") { page in
            let field = page.WString("start")
            page.Button("b").onClick([.script("window.rawRan = 1;"), .setVariable(field, to: value)])
        }
        RenderInvariants.expectValid(html)
        let scripts = RenderInvariants.bodyScripts(html).map { $0.text }
        let raw = try #require(scripts.first { $0.contains("window.rawRan = 1;") })
        #expect(raw.contains("try {") == false, "raw action code has a <script> element of its own")
        #expect(raw.contains(WebJSON.scriptString(value)), "the inserted marker is removed, the value is not touched")
        #expect(html.contains(WebScriptOrigin.rawMarker) == false)
    }

    @Test(.enabled(if: NodeJS.isAvailable), arguments: markerLookalikes)
    func valuesThatLookLikeTheMarkerRoundTripInTheBrowser(marker: String) throws {
        var ids: [String] = []
        let html = renderPage(namespace: "p") { page in
            let field = page.WString("x\(marker)y").name("field")
            let text = page.Text(field)
            let other = page.WString("start")
            let otherText = page.Text(other)
            ids = [field.builderId, text.builderId, other.builderId, otherText.builderId]
            _ = page.create { el in
                el.frameworkDOMLoaded(CompileActions([.setVariable(other, to: "a\(marker)b")], builderId: el.builderId))
            }
        }
        RenderInvariants.expectValid(html)
        let idsJSON = String(decoding: try JSONSerialization.data(withJSONObject: ids), as: UTF8.self)
        let outcome = try FormsBrowser.run(html: html, scenario: """
            const ids = \(idsJSON);
            h.fireDOMContentLoaded();
            await h.settle();
            return { field: h.win[ids[0]], text: h.el('class:' + ids[1]).innerText,
                     other: h.win[ids[2]], otherText: h.el('class:' + ids[3]).innerText };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.warnings.isEmpty, "\(outcome.warnings)")
        #expect(outcome.result["field"] as? String == "x\(marker)y")
        #expect(outcome.result["text"] as? String == "x\(marker)y")
        #expect(outcome.result["other"] as? String == "a\(marker)b")
        #expect(outcome.result["otherText"] as? String == "a\(marker)b")
    }
}

@Suite("Phase 1 render review: element references outside scripts")
struct Phase1RenderReferenceTests {

    @Test func javaScriptURLsAttributeValuesAndHeadAttributesRegisterTheElementsTheyName() {
        var expected: [String] = []
        var unusedIds: [String] = []
        let html = renderPage(namespace: "p") { page in
            let viaHref = page.Text("href")
            let viaSpacedHref = page.Text("spaced href")
            let viaSrc = page.Text("src")
            let viaFormaction = page.Text("formaction")
            let viaAlpine = page.Text("x-on")
            let viaHtmx = page.Text("hx-on")
            let viaData = page.Text("data")
            let viaHead = page.Text("head")
            let viaPlainHref = page.Text("plain href")
            let unused = page.Text("unused")
            expected = [viaHref, viaSpacedHref, viaSrc, viaFormaction, viaAlpine, viaHtmx, viaData, viaHead].map { $0.builderId }
            unusedIds = [viaPlainHref.builderId, unused.builderId]

            page.Link("javascript:\(viaHref.builderId).classList.add('on')", title: "go")
            page.Link(" \tJava\nScript:void(\(viaSpacedHref.builderId).focus())", title: "go")
            _ = page.create { el in
                el.elementName = "iframe"
                el.addAttribute(.src("javascript:\(viaSrc.builderId).focus()"))
            }
            _ = page.create { el in
                el.elementName = "button"
                el.addAttribute(.pair("formaction", "javascript:\(viaFormaction.builderId).click()"))
            }
            _ = page.create { $0.addAttribute(.pair("x-on:click", "\(viaAlpine.builderId).focus()")) }
            _ = page.create { $0.addAttribute(.pair("hx-on", "click: \(viaHtmx.builderId).focus()")) }
            _ = page.create { $0.data("target=\(viaData.builderId)") }
            page.head(.script(src: "/x.js", attributes: ["onload": "\(viaHead.builderId).hidden = false"]))
            // an ordinary URL is not code
            page.Link("/items/\(viaPlainHref.builderId)", title: "item")
        }
        RenderInvariants.expectValid(html)
        let registered = RenderInvariants.registeredIds(in: html)
        #expect(registered == expected)
        for id in unusedIds {
            #expect(registered.contains(id) == false)
        }
    }

    @Test func javaScriptURLsAreRecognizedAsABrowserReadsThem() {
        for url in ["javascript:x()", "JavaScript:x()", "  javascript:x()", "\(scalar(1))\(scalar(0x1F)) javascript:x()",
                    "java\tscript:x()", "java\nscr\ript:x()", "JAVASCRIPT:"] {
            #expect(WebScriptReferences.isJavaScriptURL(url), "\(url.debugDescription)")
        }
        for url in ["", "javascript", "/javascript:x()", "javascriptx:", "https://example.com/?javascript:x",
                    "\(scalar(0xA0))javascript:x()", "vbscript:x"] {
            #expect(WebScriptReferences.isJavaScriptURL(url) == false, "\(url.debugDescription)")
        }
    }

    @Test func nonASCIIWhiteSpaceSeparatesIdentifiers() {
        let separators: [UInt32] = [0xA0, 0x1680] + Array(0x2000...0x200A) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
        for separator in separators {
            var references = WebScriptReferences(candidates: ["p_1", "p_2"])
            references.scan("(\(scalar(separator))p_1\(scalar(separator))).x;\(scalar(separator))p_2")
            #expect(references.found == ["p_1", "p_2"], "U+\(String(separator, radix: 16, uppercase: true))")
        }
        // a character that can be part of an identifier makes it a different one
        for letter: UInt32 in [0xE9, 0x3042, 0x200C, 0x1D49C] {
            var references = WebScriptReferences(candidates: ["p_1"])
            references.scan("\(scalar(letter))p_1 + p_1\(scalar(letter))")
            #expect(references.found.isEmpty, "U+\(String(letter, radix: 16, uppercase: true))")
        }
    }

    @Test func jumpingBetweenUnderscoresFindsWhatReadingEveryTokenFinds() {
        // a small deterministic generator (SplitMix64), so a failure can be reproduced
        struct SplitMix: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
        }
        var random = SplitMix(state: 0x5EED)
        let ids = ["p_1", "p_2", "p_a", "p_10", "q_1", "ab_c_d", "$x_1", "_p_1"]
        let pieces = ids + ["p", "q", "_", "__", "1", "x", "$", "p_1x", "1p_1", " ", ".", "(", "'", "\"", "<", "=", "\n",
                            "\(scalar(0xE9))", "\(scalar(0x65E5))\(scalar(0x672C))", scalar(0x200C), scalar(0xA0), scalar(0x2028),
                            scalar(0x3000), scalar(0xFEFF), scalar(0x1680), scalar(0x1D49C)]
        var mismatches: [String] = []
        for _ in 0..<2000 {
            let length = Int.random(in: 1...30, using: &random)
            let text = (0..<length).map { _ in pieces.randomElement(using: &random)! }.joined()
            var jumping = WebScriptReferences(candidates: ids)
            var reading = WebScriptReferences(candidates: ids)
            reading.jumpsBetweenUnderscores = false
            jumping.scan(text)
            reading.scan(text)
            if jumping.found != reading.found {
                mismatches.append("\(text.debugDescription): \(jumping.found.sorted()) vs \(reading.found.sorted())")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
        // a long token full of underscores is read once
        var references = WebScriptReferences(candidates: ["p_1"])
        references.scan(String(repeating: "a_", count: 50_000) + " p_1")
        #expect(references.found == ["p_1"])
    }

    @Test func anIdentifierNextToANoBreakSpaceInAnAppScriptIsRegistered() {
        var targetId = ""
        let html = renderPage(namespace: "p") { page in
            let target = page.Text("target")
            targetId = target.builderId
            _ = page.create { $0.script("window.__r = (\(scalar(0xA0))\(target.builderId)).textContent;") }
        }
        RenderInvariants.expectValid(html)
        #expect(RenderInvariants.registeredIds(in: html) == [targetId])
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func aJavaScriptURLFindsTheElementItNames() throws {
        var targetId = ""
        let html = renderPage(namespace: "p") { page in
            let target = page.Text("target")
            targetId = target.builderId
            page.Link("javascript:\(target.builderId).classList.add('on')", title: "go")
        }
        RenderInvariants.expectValid(html)
        let link = try #require(RenderDOM.parse(html).document.elements(named: "a").first { $0.attribute("href")?.hasPrefix("javascript:") == true })
        let code = try #require(RenderDOM.code(ofAttribute: "href", value: link.attribute("href")))
        let outcome = try FormsBrowser.run(html: html, scenario: """
            h.fireDOMContentLoaded();
            let failure = null;
            try { new h.win.Function(\(WebJSON.scriptString(code)))(); } catch (e) { failure = String(e && e.message || e); }
            return { failure: failure, on: h.el('class:' + \(WebJSON.scriptString(targetId))).classList.contains('on') };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["failure"] is NSNull || outcome.result["failure"] == nil, "\(outcome.result)")
        #expect(outcome.result["on"] as? Bool == true)
    }
}

@Suite("Phase 1 render review: de-duplication")
struct Phase1RenderDedupTests {

    @Test func manyClassesAndAttributesAreDeDuplicatedInOrderFirstWins() throws {
        let count = 40
        var elementId = ""
        let html = renderPage(namespace: "p") { page in
            elementId = page.create { el in
                el.elementName = "span"
                for index in 0..<count {
                    el.addAttribute(.class("c\(index)"))
                    el.addAttribute(.pair("data-k\(index)", "v\(index)"))
                }
                // repeats, before and after a set takes over
                el.addAttribute(.class("c3"))
                el.addAttribute(.class(el.builderId))
                el.addAttribute(.deviceClass(mobile: "c\(count - 1)", desktop: "c\(count - 1)"))
                el.addAttribute(.pair("data-k3", "second"))
                el.addAttribute(.pair("data-k\(count - 1)", "second"))
                el.addAttribute(.data("k5=second"))
                el.addAttribute(.class("extra"))
                el.addAttribute(.pair("data-extra", "x"))
            }.builderId
        }
        RenderInvariants.expectValid(html)
        let span = try #require(RenderDOM.parse(html).document.elements(named: "span").first { $0.classes.contains(elementId) })
        #expect(span.classes == [elementId] + (0..<count).map { "c\($0)" } + ["extra"])
        let dataNames = span.attributes.map { $0.name }.filter { $0.hasPrefix("data-") }
        #expect(dataNames == (0..<count).map { "data-k\($0)" } + ["data-extra"])
        #expect(span.attribute("data-k3") == "v3")
        #expect(span.attribute("data-k5") == "v5")
        #expect(span.attribute("data-k\(count - 1)") == "v\(count - 1)")
        #expect(html.contains("second") == false)
    }
}

@Suite("Phase 1 render review: determinism across endpoint instances")
struct Phase1RenderManyInstancesTests {

    /// Every dictionary gets its own hash seed (from its storage address), so output that follows a
    /// dictionary's order differs between renders in the same process with a high probability; rendering
    /// on several endpoints catches it without a second process.
    @Test func theKitchenSinkRendersTheSameBytesOnEveryEndpoint() {
        let renders = (0..<6).map { _ in
            buildPage(namespace: "k") { page in RenderKitchenSink.build(page) }.renderWebPage()
        }
        for (index, html) in renders.enumerated().dropFirst() {
            #expect(html == renders[0], "render \(index) differs")
        }
    }
}
