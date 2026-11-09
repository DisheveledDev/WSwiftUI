//
//  Phase1RenderScriptTests.swift
//  WSwiftUITests
//
//  Phase 1 render slice: every script runs from the end of <body> (LAYOUT-11, M12, CORE-26). Registrations
//  only for referenced elements, one framework block, raw JavaScript isolated in its own <script>, order kept,
//  runtime and syntax errors isolated, DOMContentLoaded scripts isolated, and Bootstrap sibling structure.
//

import Foundation
import Testing
@testable import WSwiftUI

/// A `#fileID` inside the WSwiftUI module: scripts added "from" it count as framework code.
private let frameworkFile: StaticString = "WSwiftUI/Phase1RenderFixture.swift"

private extension WebElement {
    /// Adds a script as framework code (as if a WSwiftUI control had added it).
    @discardableResult
    func frameworkScript(_ js: String) -> Self { addAttribute(.script(js), file: frameworkFile) }
    @discardableResult
    func frameworkDOMLoaded(_ js: String) -> Self { addAttribute(.domLoadedScript(js), file: frameworkFile) }
}

private func scriptsAndHandlers(_ html: String) -> (scripts: [String], handlers: [String]) {
    let document = RenderDOM.parse(html).document
    let scripts = document.elements(named: "script").filter { $0.attribute("src") == nil }.map { $0.text }
    var handlers: [String] = []
    for element in document.descendants where element.kind == .element {
        for attribute in element.attributes {
            if let code = RenderDOM.code(ofAttribute: attribute.name, value: attribute.value) {
                handlers.append(code)
            }
        }
    }
    return (scripts, handlers)
}

@Suite("Phase 1 render: scripts at the end of <body>")
struct Phase1RenderScriptPlacementTests {

    @Test func aStaticPageHasNoScriptAtAll() {
        let html = renderPage { page in
            page.VStack {
                for index in 0..<20 { page.Text("row \(index)") }
            }
            page.Table { page.TableBody { page.Row { page.Cell { page.Text("cell") } } } }
        }
        RenderInvariants.expectValid(html)
        #expect(ScriptScan.scriptOpeners(in: html) == 0, "one registration script per element used to follow every element")
    }

    @Test func onlyElementsAScriptRefersToAreRegistered() throws {
        var buttonId = ""
        let html = renderPage { page in
            for index in 0..<50 { page.Text("static \(index)") }
            buttonId = page.Button("Go").onClick(.navigate("/next")).builderId
        }
        RenderInvariants.expectValid(html)
        #expect(RenderInvariants.registeredIds(in: html) == [buttonId])
        let scripts = RenderInvariants.bodyScripts(html)
        #expect(scripts.count == 1)
        let block = try #require(scripts.first?.text)
        #expect(block.contains("\(buttonId).addEventListener('click'"))
    }

    @Test func idsReferencedByHandlersAppScriptsAndRawHTMLAreRegistered() {
        var ids: [String] = []
        let html = renderPage { page in
            let target = page.create { $0.elementName = "span" }
            let viaApp = page.create { $0.elementName = "span" }
            let viaMarkup = page.create { $0.elementName = "span" }
            let unused = page.create { $0.elementName = "span" }
            ids = [target.builderId, viaApp.builderId, viaMarkup.builderId, unused.builderId]
            _ = page.create { el in
                el.elementName = "button"
                el.addAttribute(.custom("onclick=\"\(target.builderId).focus()\""))
            }
            _ = page.create { $0.script("\(viaApp.builderId).textContent = 'app';") }
            _ = page.create { $0.innerHTML("<a href=\"#\" onclick=\"\(viaMarkup.builderId).click()\">x</a>") }
        }
        RenderInvariants.expectValid(html)
        let registered = RenderInvariants.registeredIds(in: html)
        #expect(registered == Array(ids.prefix(3)))
        #expect(registered.contains(ids[3]) == false)
    }

    @Test func elementsMarkedDontRegisterAndVariablesAreNeverRegistered() {
        var hiddenId = ""
        var variableId = ""
        let html = renderPage { page in
            let variable = page.WString("x")
            variableId = variable.builderId
            let hidden = page.create { $0.addAttribute(.dontRegisterObject) }
            hiddenId = hidden.builderId
            _ = page.create { $0.frameworkScript("console.log(\(hidden.builderId), \(variable.builderId));") }
        }
        // the element the app asked not to register is the only reference the checker reports
        #expect(RenderInvariants.violations(in: html) == ["\(hiddenId) is referenced by a script or handler but neither registered nor defined"])
        let registered = RenderInvariants.registeredIds(in: html)
        #expect(registered.contains(hiddenId) == false)
        #expect(registered.contains(variableId) == false)
        #expect(html.contains("var \(variableId) = \"x\";"))
    }

    @Test func frameworkScriptsShareOneBlockAndAppScriptsGetTheirOwnInOrder() throws {
        let html = renderPage { page in
            _ = page.create { $0.frameworkScript("order.push('A');") }
            _ = page.create { $0.script("order.push('B');") }
            _ = page.create { $0.frameworkScript("order.push('C');") }
            _ = page.create { $0.frameworkScript("order.push('D');") }
            _ = page.create { $0.frameworkDOMLoaded("order.push('E');") }
        }
        RenderInvariants.expectValid(html)
        let scripts = RenderInvariants.bodyScripts(html).map { $0.text }
        #expect(scripts.count == 3)
        #expect(scripts[0].contains("order.push('A');") && scripts[0].contains("try {"))
        // the app's script is emitted exactly as it used to be: unwrapped, in an element of its own
        #expect(scripts[1] == "order.push('B');")
        #expect(scripts[2].contains("order.push('C');") && scripts[2].contains("order.push('D');"))
        // the DOMContentLoaded listener comes last, after every element script
        let listener = try #require(scripts[2].range(of: "document.addEventListener('DOMContentLoaded'"))
        let d = try #require(scripts[2].range(of: "order.push('D');"))
        #expect(d.lowerBound < listener.lowerBound)
        #expect(html.contains(WebScriptOrigin.rawMarker) == false, "the app-code marker is removed")
    }

    @Test func scriptsRunChildrenFirstThenTheParentAsBefore() throws {
        let html = renderPage { page in
            let outer = page.create { $0.frameworkScript("order.push('outer');") }
            page.stack.append(outer)
            _ = page.create { $0.frameworkScript("order.push('child1');") }
            _ = page.create { $0.frameworkScript("order.push('child2');") }
            page.stack.removeAll { $0 === outer }
            _ = page.create { $0.frameworkScript("order.push('after');") }
        }
        RenderInvariants.expectValid(html)
        let block = try #require(RenderInvariants.bodyScripts(html).first?.text)
        let positions = ["child1", "child2", "outer", "after"].map { block.range(of: "order.push('\($0)')")?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil })
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
    }

    @Test func rawActionCodeIsIsolatedFromFrameworkCode() {
        let html = renderPage { page in
            page.Button("Framework").onClick(.navigate("/a"))
            page.Button("Raw").onClick([.script("window.raw = 1;")])
            page.Button("Animate").onClick(.animate(ref: nil, keyframes: "[{opacity: 0}]", options: "{duration: 1}"))
            page.Button("Framework 2").onClick(.alert("b"))
        }
        RenderInvariants.expectValid(html)
        let scripts = RenderInvariants.bodyScripts(html).map { $0.text }
        // [registrations + Framework], [Raw], [Animate], [Framework 2]
        #expect(scripts.count == 4)
        #expect(scripts[1].contains("window.raw = 1;") && scripts[1].contains("try {") == false)
        #expect(scripts[2].contains("[{opacity: 0}]"))
        #expect(scripts[3].contains("window.alert(\"b\")"))
        #expect(html.contains(WebScriptOrigin.rawMarker) == false, "the markers are removed from the emitted scripts")
    }

    @Test func manyRegistrationsAreFoundInOneWalkOverTheDocument() {
        var ids: [String] = []
        let html = renderPage { page in
            page.Table {
                page.TableBody {
                    for index in 0..<(WebPageScripts.lookupsPerElementLimit + 8) {
                        page.Row {
                            ids.append(page.Cell { page.Text("row \(index)") }.onClick(.navigate("/row/\(index)")).builderId)
                        }
                    }
                }
            }
        }
        RenderInvariants.expectValid(html)
        #expect(RenderInvariants.registeredIds(in: html) == ids)
        #expect(html.contains("__wsuiElement(") == false)
        #expect(html.contains("getElementsByTagName('*')"))
    }
}

@Suite("Phase 1 render: scripts run in a browser-like context", .enabled(if: NodeJS.isAvailable))
struct Phase1RenderScriptRuntimeTests {

    @Test func everyGlobalAnInlineHandlerUsesExistsAfterTheEndOfBodyScripts() throws {
        let html = renderPage { page in RenderKitchenSink.build(page) }
        let handlers = scriptsAndHandlers(html).handlers
        #expect(handlers.count >= 8)
        let names = Set(handlers.flatMap { RenderDOM.identifierTokens($0) }.filter {
            $0.hasPrefix("updateWebVariable") || $0.hasPrefix("addCallback") || RenderInvariants.isGeneratedId($0)
        })
        let handlersJSON = String(decoding: try JSONSerialization.data(withJSONObject: handlers), as: UTF8.self)
        let namesJSON = String(decoding: try JSONSerialization.data(withJSONObject: Array(names)), as: UTF8.self)
        let outcome = try FormsBrowser.run(html: html, scenario: """
            h.fireDOMContentLoaded();
            await h.settle();
            const missing = \(namesJSON).filter(function (n) { return typeof h.win[n] === 'undefined'; });
            const failures = [];
            \(handlersJSON).forEach(function (code) {
              try {
                const element = h.el('handler-target');
                element.value = 'v';
                element.checked = true;
                new h.win.Function('event', code).call(element, { type: 'test' });
              } catch (e) { failures.push(code + ' => ' + String(e && e.message || e)); }
            });
            return { missing: missing, failures: failures };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect((outcome.result["missing"] as? [String]) == [])
        #expect((outcome.result["failures"] as? [String]) == [])
    }

    @Test func anExceptionInOneElementScriptDoesNotStopTheOthers() throws {
        let html = renderPage { page in
            _ = page.create { $0.frameworkScript("window.first = 1;") }
            _ = page.create { $0.frameworkScript("throw new Error('chunk-failed');") }
            _ = page.create { $0.frameworkScript("window.third = 3;") }
        }
        RenderInvariants.expectValid(html)
        let outcome = try FormsBrowser.run(html: html, scenario: """
            return { first: h.win.first, third: h.win.third };
            """)
        #expect(outcome.result["first"] as? Int == 1)
        #expect(outcome.result["third"] as? Int == 3)
        // reported on the console, not thrown out of the block
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.warnings.contains { $0.contains("chunk-failed") })
    }

    @Test func aSyntaxErrorInAppJavaScriptDoesNotBreakTheFrameworkOrOtherElements() throws {
        var variableId = ""
        var textId = ""
        let html = renderPage { page in
            _ = page.create { $0.script("function broken( {") }                      // app raw JS, invalid
            page.Button("Raw action").onClick([.script("if (")])                  // raw action code, invalid
            let value = page.WString("before")
            variableId = value.builderId
            textId = page.Text(value).builderId
            _ = page.create { $0.script("window.appScriptRan = true;") }
        }
        RenderInvariants.expectValid(html)
        let outcome = try FormsBrowser.run(html: html, scenario: """
            h.fireDOMContentLoaded();
            const VAR = \(WebJSON.scriptString(variableId)), TEXT = \(WebJSON.scriptString(textId));
            const defined = typeof h.win['addCallback' + VAR] === 'function' && typeof h.win['updateWebVariable' + VAR] === 'function';
            h.win['updateWebVariable' + VAR]('after', { source: 'test' });
            return { defined: defined, text: h.el('class:' + TEXT).innerText, app: h.win.appScriptRan === true };
            """)
        #expect(outcome.result["defined"] as? Bool == true)
        #expect(outcome.result["text"] as? String == "after")
        #expect(outcome.result["app"] as? Bool == true)
        // exactly the two broken scripts failed to parse
        #expect(outcome.errors.count == 2, "\(outcome.errors)")
        #expect(outcome.errors.allSatisfy { $0.contains("Unexpected") || $0.contains("SyntaxError") || $0.contains("token") }, "\(outcome.errors)")
    }

    @Test func aReturnOrAnExceptionInADOMContentLoadedScriptDoesNotSkipTheNextOnes() throws {
        let html = renderPage { page in
            _ = page.create { $0.frameworkDOMLoaded("window.ran = ['a']; return; window.ran.push('never');") }
            _ = page.create { $0.frameworkDOMLoaded("window.ran.push('b'); throw new Error('dom-failed');") }
            _ = page.create { $0.frameworkDOMLoaded("window.ran.push('c');") }
            _ = page.create { $0.addAttribute(.domLoadedScript("window.ran.push('d'); return; window.ran.push('never');")) }
            _ = page.create { $0.addAttribute(.domLoadedScript("window.ran.push('e');")) }
            _ = page.create { $0.frameworkDOMLoaded("var shared = 'f'; window.ran.push(shared);") }
            _ = page.create { $0.frameworkDOMLoaded("window.ran.push(typeof shared);") }
        }
        RenderInvariants.expectValid(html)
        let outcome = try FormsBrowser.run(html: html, scenario: """
            h.fireDOMContentLoaded();
            return { ran: h.win.ran };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        // each script has its own scope: a `var` of one is not seen by the next
        #expect(outcome.result["ran"] as? [String] == ["a", "b", "c", "d", "e", "f", "undefined"])
        #expect(outcome.warnings.contains { $0.contains("dom-failed") })
    }

    @Test func theLiveUpdateRuntimeStartsBeforeThePageLoadSync() throws {
        var variableId = ""
        let html = renderPage { page in
            let value = page.WString("x").name("value")
            variableId = value.builderId
            value.liveUpdate(url: "/live", reference: "r", actions: [.read, .write], pollEverySeconds: nil)
            // runs with the page-load syncs: by then liveUpdate's own DOMContentLoaded listener has registered
            // its callback on the variable
            _ = page.create { $0.frameworkDOMLoaded("window.callbacksAtSync = callbacks\(value.builderId).length;") }
        }
        RenderInvariants.expectValid(html)
        let outcome = try FormsBrowser.run(html: html, scenario: """
            h.fireDOMContentLoaded();
            await h.settle();
            const afterLoad = h.fetches.length;
            h.win['updateWebVariable' + \(WebJSON.scriptString(variableId))]('edited', { source: 'input' });
            await h.advance(400);
            return { callbacksAtSync: h.win.callbacksAtSync, afterLoad: afterLoad, afterEdit: h.fetches.length };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["callbacksAtSync"] as? Int == 1)
        #expect(outcome.result["afterLoad"] as? Int == 0)
        #expect(outcome.result["afterEdit"] as? Int == 1)
    }

    @Test func theWalkOverTheDocumentRegistersTheFirstElementOfEachClass() throws {
        let html = renderPage { page in
            for index in 0..<(WebPageScripts.lookupsPerElementLimit + 8) {
                page.Button("b\(index)").onClick(.alert("\(index)"))
            }
        }
        RenderInvariants.expectValid(html)
        let block = try #require(RenderInvariants.bodyScripts(html).first?.text)
        let end = try #require(block.range(of: "]);\n"))
        let registration = String(block[..<end.upperBound])
        let ids = RenderInvariants.registeredIds(in: html)
        #expect(ids.count == WebPageScripts.lookupsPerElementLimit + 8)
        // a stub document: one element per id, then a later element that has the first id's class too
        let elements = ids.map { "{ name: \"\($0)\", classList: [\"btn\", \"\($0)\"] }" }
            + ["{ name: \"later\", classList: [\"\(ids[0])\"] }"]
        let result = try NodeJS.run(scripts: [block], code: registration,
                                    globals: ["document": "({ getElementsByTagName: function () { return [\(elements.joined(separator: ","))]; } })"])
        #expect(result.syntaxErrors == [])
        #expect(result.error == nil, "\(result.error ?? "")")
        let sets = result.records.compactMap { $0 as? [String: Any] }.filter { ($0["op"] as? String) == "set" }
        #expect(sets.map { $0["path"] as? String } == ids.map { "window.\($0)" })
        #expect(sets.map { ($0["value"] as? [String: Any])?["name"] as? String } == ids, "the first element of each class wins")
    }

    @Test func elementScriptsSeeEveryElementOfTheBody() throws {
        // an element's script can refer to an element declared after it (it used to run right after its own
        // element, before the later one was parsed and registered)
        var laterId = ""
        let html = renderPage { page in
            let early = page.create { $0.elementName = "span" }
            let later = page.create { $0.elementName = "div" }
            laterId = later.builderId
            early.frameworkScript("window.sawLater = (typeof \(laterId) !== 'undefined') && !!\(laterId);")
        }
        RenderInvariants.expectValid(html)
        let outcome = try FormsBrowser.run(html: html, scenario: "return { saw: h.win.sawLater };")
        #expect(outcome.result["saw"] as? Bool == true)
        #expect(RenderInvariants.registeredIds(in: html).contains(laterId))
    }

    @Test func showModalUsesBootstrapsInstanceForTheModal() throws {
        let html = renderPage { page in
            _ = page.create { el in
                el.frameworkDOMLoaded(CompileActions([.showModal(ref: "m1"), .hideModal(ref: "m1"),
                                                      .showModal(ref: "m2", contentURL: "/fragment")], builderId: el.builderId))
            }
        }
        RenderInvariants.expectValid(html)
        #expect(html.contains("ModalDialog") == false, "the undefined <md5>ModalDialog global is gone")
        let outcome = try FormsBrowser.run(html: html, scenario: """
            const calls = [];
            h.win.bootstrap = { Modal: { getOrCreateInstance: function (el) {
              return { show: function () { calls.push('show:' + el.key); }, hide: function () { calls.push('hide:' + el.key); } };
            } } };
            h.el('m2').querySelector = function (selector) { return selector === '.modal-body' ? h.el('m2-body') : null; };
            h.fireDOMContentLoaded();
            await h.settle();
            await h.respondText(0, '<p>fragment</p><script>window.fragmentRan = true;</' + 'script>', 200);
            return { calls: calls, url: h.fetches[0].url, body: h.el('m2-body').innerHTML, ran: h.win.fragmentRan === true };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.warnings.isEmpty, "\(outcome.warnings)")
        #expect(outcome.result["calls"] as? [String] == ["show:m1", "hide:m1", "show:m2"])
        #expect(outcome.result["url"] as? String == "/fragment")
        #expect((outcome.result["body"] as? String)?.contains("<p>fragment</p>") == true)
    }
}

@Suite("Phase 1 render: Bootstrap sibling structure")
struct Phase1RenderStructureTests {

    @Test func listGroupItemsAreEachOthersSiblings() throws {
        let html = renderPage { page in
            page.ListGroup {
                page.ListGroupItem("One").onClick(.navigate("/1"))
                page.ListGroupItem("Two")
                page.ListGroupItem("Three").onClick(.navigate("/3"))
            }
        }
        RenderInvariants.expectValid(html)
        // `.list-group-item + .list-group-item` (no doubled borders) needs the items to be adjacent siblings
        let parsed = RenderDOM.parse(html)
        withExtendedLifetime(parsed) {
            let items = parsed.document.descendants.filter { $0.classes.contains("list-group-item") }
            #expect(items.count == 3)
            for (index, item) in items.enumerated() {
                let next = item.nextElementSibling
                if index + 1 < items.count {
                    #expect(next === items[index + 1], "item \(index) is followed by <\(next?.name ?? "nothing")>")
                } else {
                    #expect(next == nil, "the last item is followed by <\(next?.name ?? "")>")
                }
            }
        }
    }

    @Test func segmentedPickerButtonsAreEachOthersSiblings() throws {
        let html = renderPage { page in
            let unnamed = page.WString("a")
            page.Picker("Unnamed", selection: unnamed, style: .segmented(.primary)) {
                page.Text("a")
                page.Text("b")
                page.Text("c")
            }
        }
        RenderInvariants.expectValid(html)
        let parsed = RenderDOM.parse(html)
        try withExtendedLifetime(parsed) {
            let group = try #require(parsed.document.descendants.first { $0.classes.contains("btn-group") })
            let buttons = group.elementChildren
            #expect(buttons.count == 3)
            #expect(buttons.allSatisfy { $0.name == "button" })
            // `.btn-group > .btn:last-child` keeps its rounded corners: nothing follows the last button
            #expect(buttons.last?.parent === group)
            #expect(buttons.last?.nextElementSibling == nil)
            #expect(buttons.first?.nextElementSibling === buttons[1])
            #expect(buttons[1].nextElementSibling === buttons[2])
        }
    }

    @Test func aNamedSegmentedPickerHasNoScriptAmongItsButtons() throws {
        let html = renderPage { page in
            let named = page.WString("a").name("choice")
            page.Picker("Named", selection: named, style: .segmented(.primary)) {
                page.Text("a")
                page.Text("b")
            }
        }
        RenderInvariants.expectValid(html)
        let parsed = RenderDOM.parse(html)
        try withExtendedLifetime(parsed) {
            let group = try #require(parsed.document.descendants.first { $0.classes.contains("btn-group") })
            #expect(group.elementChildren.contains { $0.name == "script" } == false)
            #expect(group.elementChildren.first?.parent === group)
            #expect(group.elementChildren.first?.nextElementSibling?.name == "button")
            // the bound hidden input follows the group instead of being its last child, so
            // `.btn-group > .btn:not(:last-child)` doesn't square off the last button
            let buttons = group.elementChildren
            #expect(buttons.count == 2)
            #expect(buttons.allSatisfy { $0.name == "button" })
            #expect(buttons.last?.nextElementSibling == nil)
            let hidden = try #require(parsed.document.descendants.first { $0.classes.contains("wsui-picker-hidden-binding") })
            #expect(hidden.parent !== group)
            #expect(hidden.attributes.first { $0.name == "name" }?.value == "choice")
        }
    }
}
