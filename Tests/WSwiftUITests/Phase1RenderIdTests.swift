//
//  Phase1RenderIdTests.swift
//  WSwiftUITests
//
//  Phase 1 render slice: deterministic, namespaced element ids (LAYOUT-16, CORE-25) and render purity.
//

import Foundation
import Testing
@testable import WSwiftUI

private func matches(_ pattern: String, _ text: String) -> Bool {
    let regex = try! NSRegularExpression(pattern: pattern)
    return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
}

/// Every generated element id (class token of the `<namespace>_<n>` shape) in a page.
private func pageIds(_ html: String) -> Set<String> {
    var ids = Set<String>()
    for element in RenderDOM.parse(html).document.descendants where element.kind == .element {
        for cls in element.classes where RenderInvariants.isGeneratedId(cls) { ids.insert(cls) }
    }
    return ids
}

private func namespaces(_ ids: Set<String>) -> Set<String> {
    Set(ids.map { String($0.prefix(while: { $0 != "_" })) })
}

@Suite("Phase 1 render: element ids")
struct Phase1RenderIdTests {

    static let identifier = "^[A-Za-z_$][A-Za-z0-9_$]*$"

    @Test func idsAreNamespacedCounterValuesThatAreIdentifiersAndClasses() {
        var created: [WebElement] = []
        let page = buildPage(namespace: "page") { page in
            for index in 0..<200 {
                created.append(page.create { $0.elementName = "p"; $0.innerHTML("p\(index)") })
            }
            created.append(page.WString("v"))
            created.append(page.Text("text"))
        }
        let ids = created.map { $0.builderId }
        #expect(Set(ids).count == ids.count, "ids are unique")
        for id in ids {
            #expect(matches("^page_[0-9a-z]+$", id), "\(id)")
            #expect(matches(Self.identifier, id))
        }
        // base-36 counter, in creation order (the webpage fragment took the first one)
        #expect(created.first?.builderId == "page_2")
        #expect(created[34].builderId == "page_10")
        let html = page.renderWebPage()
        RenderInvariants.expectValid(html)
        #expect(html.contains("<p class=\"page_2\">p0</p>"))
    }

    @Test func theDefaultNamespaceIsRandomShortAndLetterFirst() {
        let first = buildPage(namespace: nil) { page in page.Text("a") }
        let second = buildPage(namespace: nil) { page in page.Text("a") }
        let a = first.currentElementIdNamespace
        let b = second.currentElementIdNamespace
        #expect(matches("^[a-z][a-z0-9]{4}$", a), "\(a)")
        #expect(matches("^[a-z][a-z0-9]{4}$", b), "\(b)")
        #expect(a != b)
        // ids of one endpoint share its namespace
        let html = first.renderWebPage()
        RenderInvariants.expectValid(html)
        let ids = pageIds(html)
        #expect(ids.isEmpty == false)
        #expect(namespaces(ids) == [a])
    }

    @Test func idsOfElementsCreatedOutsideAnEndpointAreNeverEmpty() {
        // the old id (a UUID with its leading/trailing digits trimmed) was empty for about 1 in 2.7 million
        for _ in 0..<20_000 {
            let id = WebElement().builderId
            #expect(matches("^[a-z][a-z0-9]{4}_[a-z0-9]{6}$", id), "\(id)")
        }
        // and stays a public, settable String
        let element = WebElement()
        element.builderId = "custom"
        #expect(element.builderId == "custom")
    }

    @Test func theNamespaceIsSanitized() {
        #expect(WebElementId.sanitizedNamespace("My-Page 1") == "MyPage1")
        #expect(WebElementId.sanitizedNamespace("9lives") == "n9lives")
        #expect(WebElementId.sanitizedNamespace("caf\u{E9}_x") == "cafx")
        #expect(WebElementId.sanitizedNamespace("--") == nil)
        #expect(WebElementId.sanitizedNamespace("") == nil)
        let page = buildPage(namespace: "--") { page in page.Text("x") }
        #expect(matches("^[a-z][a-z0-9]{4}$", page.currentElementIdNamespace))
        let custom = buildPage(namespace: "Home-Page") { page in page.Text("x") }
        #expect(custom.currentElementIdNamespace == "HomePage")
        RenderInvariants.expectValid(custom.renderWebPage())
    }

    @Test func aNamespaceSetHalfwayKeepsIdsUnique() {
        var ids: [String] = []
        _ = buildPage(namespace: "a") { page in
            ids.append(page.create { _ in }.builderId)
            page.elementIdNamespace = "b"
            ids.append(page.create { _ in }.builderId)
            page.elementIdNamespace = "a"
            ids.append(page.create { _ in }.builderId)
        }
        #expect(ids == ["a_2", "b_3", "a_4"])
    }

    @Test func registrableIdsExcludeReservedWordsAndUnsafeGlobals() {
        #expect(WebElementId.isRegistrable("t_1"))
        #expect(WebElementId.isRegistrable("abc"))
        for id in ["", "1a", "a-b", "class", "top", "location", "document", "name", "__wsuiElement", "a b"] {
            #expect(WebElementId.isRegistrable(id) == false, "\(id)")
        }
    }
}

@Suite("Phase 1 render: deterministic output")
struct Phase1RenderDeterminismTests {

    static func samplePage(_ page: RenderPage) {
        let name = page.WString("Ada").name("name")
        let count = page.WInt(1)
        page.VStack {
            page.Text("Hello $0", name)
            page.Button("More").onClick([.setVariable(count, to: 2), .post(url: "/save", values: [name]),
                                         .get(url: "/load", params: [name]), .random([.alert("a"), .alert("b")])])
            page.TextField("Name", text: name)
            page.head(.link(rel: .other("preload"), href: "/f.woff2", attributes: ["as": "font", "crossorigin": "", "type": "font/woff2"]))
            page.head(.custom(tag: "meta", attributes: ["name": "x", "content": "y", "data-q": "z"], innerHTML: nil))
        }
    }

    @Test func theSamePageRendersByteIdenticallyOnEveryRequest() {
        let first = renderPage(namespace: "home") { Self.samplePage($0) }
        let second = renderPage(namespace: "home") { Self.samplePage($0) }
        let third = renderPage(namespace: "home") { Self.samplePage($0) }
        #expect(first == second)
        #expect(second == third)
        RenderInvariants.expectValid(first)
        // ids and the names actions declare come from the namespace
        #expect(first.contains("class=\"home_"))
        #expect(first.contains("postDatahome_"))
    }

    @Test func twoEndpointInstancesRenderTheSameBytes() {
        let a = buildPage(namespace: "x") { Self.samplePage($0) }
        let b = buildPage(namespace: "x") { Self.samplePage($0) }
        let html = a.renderWebPage()
        #expect(html == b.renderWebPage())
        RenderInvariants.expectValid(html)
    }

    @Test func pagesWithTheDefaultNamespaceNeverShareAnId() {
        let first = renderPage(namespace: nil) { Self.samplePage($0) }
        let second = renderPage(namespace: nil) { Self.samplePage($0) }
        RenderInvariants.expectValid(first)
        RenderInvariants.expectValid(second)
        let a = pageIds(first)
        let b = pageIds(second)
        #expect(a.count > 5)
        #expect(a.isDisjoint(with: b), "shared ids: \(a.intersection(b).sorted())")
        #expect(namespaces(a).count == 1 && namespaces(b).count == 1 && namespaces(a) != namespaces(b))
    }

    @Test func compiledActionsNameTheirVariablesAfterTheElement() {
        let detached = WebVariableElement()
        detached.builderId = "v_1"
        detached.name("field")
        let actions: [WebAction] = [
            .post(url: "/a", values: [detached], onSuccessful: [.post(url: "/b")]),
            .get(url: "/c", params: [detached]),
            .random([.alert("x")]),
        ]
        let first = CompileActions(actions, builderId: "t_9")
        #expect(first == CompileActions(actions, builderId: "t_9"))
        // one counter per compile, nested actions included: no two declare the same name
        #expect(first.contains("var postDatat_9_1 = {};"))
        #expect(first.contains("var postDatat_9_2 = {};"))
        #expect(first.contains("var baseUrlt_9_3 = "))
        #expect(first.contains("var randomIndext_9_4 = "))
        // an id an app assigned by hand is made identifier-safe
        #expect(CompileActions([.random([.alert("x")])], builderId: "my-id").contains("var randomIndexmy_id_1 = "))
    }

    @Test func renderingTwiceGivesTheSameOutput() {
        let page = buildPage { page in
            let name = page.WString("Ada").name("name")
            let shown = page.WBool(false)
            page.Form(action: "/save") {
                page.TextField("Name", text: name)
            }
            page.Modal(id: "m", isPresented: shown) {
                page.ModalDialog { page.ModalContent { page.ModalBody { page.Text("body") } } }
            }
            _ = page.create { $0.addAttribute(.domLoadedScript("window.loaded = (window.loaded || 0) + 1;")) }
        }
        let first = page.renderWebPage()
        let second = page.renderWebPage()
        #expect(first == second)
        #expect(ScriptScan.occurrences(of: "{ source: 'initial' }", in: first) == 2)
        #expect(page.domLoadedScripts.isEmpty, "rendering does not queue scripts on the endpoint")
        RenderInvariants.expectValid(first)
    }

    @Test func theFormFieldClaimsAreWorkedOutAgainForEveryRender() throws {
        var form: WebElement? = nil
        var carrierId = ""
        let page = buildPage { page in
            let flag = page.WBool(false).name("agree")
            carrierId = flag.builderId
            form = page.Form(action: "/save") {
                page.Text("no control submits 'agree' yet")
            }
        }
        let carrier = { (html: String) -> RenderNode? in
            RenderDOM.parse(html).document.descendants.first { $0.attribute("id") == "hiddenInput_\(carrierId)" }
        }
        // the carrier sits outside the form, nothing outside a form submits `agree`: it keeps its name
        let before = page.renderWebPage()
        #expect(try #require(carrier(before)).attribute("name") == "agree")

        // a checkbox named `agree` is added next to the carrier (outside any form) and the page re-rendered
        let checkbox = WebElement()
        checkbox.elementName = "input"
        checkbox.type("checkbox")
        checkbox.name("agree")
        page.documentRoot.subElements.append(checkbox)
        let after = page.renderWebPage()
        #expect(try #require(carrier(after)).attribute("name") == nil, "the claim cache was not recomputed")
        #expect(form != nil)
        RenderInvariants.expectValid(before)
        RenderInvariants.expectValid(after)
    }
}
