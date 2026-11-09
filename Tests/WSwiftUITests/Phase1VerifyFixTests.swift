//
//  Phase1VerifyFixTests.swift
//  WSwiftUITests
//
//  Fixes for what the Phase 1 verification found: logout revokes the cookie's token as well, personalized
//  responses are `Cache-Control: private`, the array / extractJSON / setVariableName / resultInto / scrollTo /
//  Bootstrap-instance actions work, an input made a password input after creation is redacted, dropdown
//  menu entries can be marked active, and one odd script can't take the rest of the page's scripts down.
//

import Foundation
import Testing
@testable import WSwiftUI

/// Start tags of one element name, in document order.
enum P1VerifyHTML {
    static func tags(named name: String, in html: String) -> [FormsHTML.Tag] {
        let regex = try! NSRegularExpression(pattern: "<\(name)\\b([^>]*)>", options: [.caseInsensitive])
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { match in
            FormsHTML.Tag(name: name, attributes: FormsHTML.attributes(in: ns.substring(with: match.range(at: 1))), inner: nil)
        }
    }
}

// MARK: - Sessions

@Suite("Phase 1 verify: logout revokes every token the browser held")
struct P1VerifyLogoutTests {

    @Test func bearerPlusCookieLogoutEndsBothTokens() {
        let (server, ended) = P1Session.serverRecordingEnds()
        let response = P1Session.get(server, "/p1-api?do=logout", cookie: "auth=good-1",
                                     headers: [("Authorization", "Bearer good-2")])
        #expect(ended.all == ["good-2", "good-1"])
        #expect(P1Session.setCookies(response) == [P1Session.cleared("auth")])
    }

    @Test func cookieOnlyLogoutEndsItOnce() {
        let (server, ended) = P1Session.serverRecordingEnds()
        _ = P1Session.get(server, "/p1-private?do=logout", cookie: "auth=good-1")
        #expect(ended.all == ["good-1"])
    }

    @Test func loginThenLogoutInOneRequestEndsTheNewAndTheOldToken() {
        let (server, ended) = P1Session.serverRecordingEnds()
        _ = P1Session.get(server, "/p1-public?do=login,logout", cookie: "auth=good-1")
        #expect(ended.all == ["tok-new", "good-1"])
    }

    @Test func publicLogoutWithoutAnyTokenEndsNothing() {
        let (server, ended) = P1Session.serverRecordingEnds()
        _ = P1Session.get(server, "/p1-public?do=logout", cookie: "auth=")
        #expect(ended.all.isEmpty)
    }
}

@Suite("Phase 1 verify: personalized responses are Cache-Control: private")
struct P1VerifyCacheControlTests {

    private func cacheControl(_ response: HttpResponse) -> [String] {
        return response.allHeaders(named: "Cache-Control")
    }

    @Test func acceptedExplicitExpirySessionWithoutSetCookieIsPrivate() {
        let server = P1Session.server()
        let future = Int(Date().timeIntervalSince1970) + 3600
        let response = P1Session.get(server, "/p1-private", cookie: "auth=good-1; auth_exp=\(future)")
        #expect(P1Session.setCookies(response).isEmpty)
        #expect(cacheControl(response) == ["private"])
    }

    @Test func renewedLoginAndBearerResponsesArePrivate() {
        let server = P1Session.server()
        #expect(cacheControl(P1Session.get(server, "/p1-private", cookie: "auth=good-1")) == ["private"])
        #expect(cacheControl(P1Session.get(server, "/p1-public?do=login")) == ["private"])
        #expect(cacheControl(P1Session.get(server, "/p1-api", headers: [("Authorization", "Bearer good-2")])) == ["private"])
    }

    @Test func anonymousPublicAndLogoutResponsesAreLeftAlone() {
        let server = P1Session.server()
        #expect(cacheControl(P1Session.get(server, "/p1-public")).isEmpty)
        // a public endpoint never validates the cookie, so it isn't known to be personalized
        #expect(cacheControl(P1Session.get(server, "/p1-public", cookie: "auth=good-1")).isEmpty)
        #expect(cacheControl(P1Session.get(server, "/p1-public?do=logout", cookie: "auth=good-1")).isEmpty)
        // a rejected cookie: the 302 that clears it
        #expect(cacheControl(P1Session.get(server, "/p1-private", cookie: "auth=revoked")).isEmpty)
    }

    @Test func aResponseThatSetsCacheControlKeepsIt() {
        let server = P1Session.server()
        server.register(P1VerifyOwnCachePage())
        let response = P1Session.get(server, "/p1-verify-own-cache", cookie: "auth=good-1")
        #expect(cacheControl(response) == ["no-store"])
    }

    @Test func aSharedResponseIsCopiedNotMarked() {
        let server = P1Session.server()
        let future = Int(Date().timeIntervalSince1970) + 3600
        let response = P1Session.get(server, "/p1-private?respond=shared", cookie: "auth=good-1; auth_exp=\(future)")
        #expect(cacheControl(response) == ["private"])
        #expect(response !== P1SessionActionPage.shared)
        #expect(cacheControl(P1SessionActionPage.shared).isEmpty)
    }
}

final class P1VerifyOwnCachePage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "p1-verify-own-cache"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.authenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }
    override func content() -> Any? {
        return HttpResponse().status(.ok).content(.text).header("Cache-Control", "no-store").body("own")
    }
}

// MARK: - Diagnostics

@Suite("Phase 1 verify: diagnostics")
struct P1VerifyDiagnosticsTests {

    @Test func printableTextCannotForgeLogLines() {
        let forged = WSwiftUIDiagnostics.printable("latin1\")\n[WSwiftUI] fake\r\u{2028}\u{0}")
        #expect(forged.contains("\n") == false && forged.contains("\r") == false)
        #expect(forged.contains("\u{2028}") == false && forged.contains("\u{0}") == false)
        #expect(forged.hasPrefix("latin1\")?[WSwiftUI] fake"))
        #expect(WSwiftUIDiagnostics.printable(String(repeating: "a", count: 500), limit: 10) == "aaaaaaaaaa...")
    }

    /// A broken standard error loses the line instead of aborting the process (`FileHandle.write(_:)` raised).
    @Test func loggingToABrokenPipeDoesNotStopTheProcess() {
        signal(SIGPIPE, SIG_IGN)   // as the server does
        let saved = dup(2)
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        close(fds[0])              // no reader: writes fail with EPIPE
        dup2(fds[1], 2)
        close(fds[1])
        WSwiftUIDiagnostics.log("[WSwiftUI test] written to a broken pipe")
        SessionNotice("[WSwiftUI test] notice to a broken pipe").log()
        dup2(saved, 2)
        close(saved)
        #expect(Bool(true), "still running")
    }

    @Test func droppedCharsetsAreLoggedOncePerKindWhateverTheValue() throws {
        let endpoint = "P1VerifyCharsetProbe"
        let first = try #require(WebHTMLDocument.charsetDeclaration(in: .metaCharset("latin1")))
        let second = try #require(WebHTMLDocument.charsetDeclaration(in: .metaCharset("koi8-r")))
        #expect(WebHTMLDocument.logDroppedCharset(endpoint: endpoint, declaration: first))
        #expect(WebHTMLDocument.logDroppedCharset(endpoint: endpoint, declaration: second) == false)
        let other = try #require(WebHTMLDocument.charsetDeclaration(in: .metaHttpEquiv(httpEquiv: "content-type", content: "x")))
        #expect(WebHTMLDocument.logDroppedCharset(endpoint: endpoint, declaration: other))
    }
}

// MARK: - Actions

@Suite("Phase 1 verify: actions")
struct P1VerifyActionTests {

    private static func variable(_ id: String, _ type: WebVariableType) -> WebVariableElement {
        let element = WebVariableElement()
        element.builderId = id
        element.variableType = type
        return element
    }

    /// Runs `actions` in the node sandbox with `va` holding `initial`, and returns the arguments passed to
    /// `updateWebVariableva` (nil when it was not called).
    private func runArrayAction(_ actions: [WebAction], initial: String) throws -> [Any]? {
        let js = CompileActions(actions, builderId: "el0")
        let result = try NodeJS.run(scripts: [js], code: js,
                                    globals: ["va": initial, "updateWebVariableva": "__deep('updateWebVariableva')"])
        #expect(result.syntaxErrors.isEmpty, "\(result.syntaxErrors)")
        #expect(result.error == nil, "\(result.error ?? "")")
        let calls = Phase1DocScan.records(result, op: "call", path: "updateWebVariableva")
        #expect(calls.count <= 1)
        return calls.first?["args"] as? [Any]
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func arrayActionsWorkOnAJSArray() throws {
        let va = Self.variable("va", .array)
        let added = try runArrayAction([.addToArray(variable: va, value: "c")], initial: "['a', 'b']")
        #expect(added?.first as? [String] == ["a", "b", "c"])
        let removed = try runArrayAction([.removeFromArray(variable: va, value: "a")], initial: "['a', 'b']")
        #expect(removed?.first as? [String] == ["b"])
        let toggledOn = try runArrayAction([.toggleArray(variable: va, value: "z")], initial: "['a']")
        #expect(toggledOn?.first as? [String] == ["a", "z"])
        let toggledOff = try runArrayAction([.toggleArray(variable: va, value: "a")], initial: "['a', 'b']")
        #expect(toggledOff?.first as? [String] == ["b"])
        // the source passed along says which action it was
        #expect((added?.last as? [String: Any])?["source"] as? String == "action.addToArray")
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func arrayActionsAcceptJSONTextAndEmptyValues() throws {
        let va = Self.variable("va", .array)
        #expect(try runArrayAction([.addToArray(variable: va, value: "c")], initial: "'[\"a\"]'")?.first as? [String] == ["a", "c"])
        #expect(try runArrayAction([.addToArray(variable: va, value: "c")], initial: "''")?.first as? [String] == ["c"])
        #expect(try runArrayAction([.addToArray(variable: va, value: "c")], initial: "null")?.first as? [String] == ["c"])
        // nothing to remove, unparseable text, or not an array: the variable is left alone
        #expect(try runArrayAction([.removeFromArray(variable: va, value: "x")], initial: "['a']") == nil)
        #expect(try runArrayAction([.addToArray(variable: va, value: "c")], initial: "'not json'") == nil)
        #expect(try runArrayAction([.addToArray(variable: va, value: "c")], initial: "({ a: 1 })") == nil)
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func arrayActionsOnAStringVariableWriteJSONText() throws {
        let vs = Self.variable("va", .string)
        #expect(try runArrayAction([.addToArray(variable: vs, value: "c")], initial: "'[\"a\",\"b\"]'")?.first as? String == #"["a","b","c"]"#)
        #expect(try runArrayAction([.addToArray(variable: vs, value: "c")], initial: "''")?.first as? String == #"["c"]"#)
        #expect(try runArrayAction([.toggleArray(variable: vs, value: "a")], initial: "'[\"a\"]'")?.first as? String == "[]")
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func extractJSONRunsItsActionsOnTheExtractedValue() throws {
        let target = Self.variable("vt", .string)
        let js = CompileActions([.extractJSON(key: "nested", actions: [.extractJSONInto(key: "arr[1]", into: target)])],
                                builderId: "el0")
        let result = try NodeJS.run(scripts: [js], code: js,
                                    globals: ["result": #"'{"nested":{"name":"N","arr":[1,2,3]},"top":"T"}'"#,
                                              "updateWebVariablevt": "__deep('updateWebVariablevt')"])
        #expect(result.error == nil, "\(result.error ?? "")")
        let calls = Phase1DocScan.records(result, op: "call", path: "updateWebVariablevt")
        #expect(calls.count == 1)
        #expect((calls.first?["args"] as? [Any])?.first as? Int == 2)
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func setVariableNameFindsTheNamedCarrier() throws {
        let js = CompileActions([.setVariableName("nick", to: "Ada")], builderId: "el0")
        let carriers = "[{ id: 'hiddenInput_v1', getAttribute: function () { return 'other'; } }, "
            + "{ id: 'hiddenInput_v2', getAttribute: function () { return 'nick'; } }]"
        let result = try NodeJS.run(scripts: [js], code: js,
                                    globals: ["document": "{ querySelectorAll: function () { return \(carriers); } }",
                                              "window": "{ updateWebVariablev1: __deep('v1'), updateWebVariablev2: __deep('v2') }"])
        #expect(result.error == nil, "\(result.error ?? "")")
        #expect(Phase1DocScan.records(result, op: "call", path: "v1").isEmpty)
        let calls = Phase1DocScan.records(result, op: "call", path: "v2")
        #expect((calls.first?["args"] as? [Any])?.first as? String == "Ada")
    }

    @Test func aNamedCarrierKeepsItsNameForSetVariableName() {
        let html = renderHTML { page in
            page.Form {
                // the TextField claims the field, so the carrier has no `name`, but keeps data-wsui-name
                page.TextField("Nick", text: page.WString("").name("nick"))
            }
            _ = page.WString("x")
        }
        let carriers = P1VerifyHTML.tags(named: "input", in: html).filter { $0.attribute("type") == "hidden" }
        #expect(carriers.count == 2)
        #expect(carriers.filter { $0.attribute("data-wsui-name") == "nick" }.count == 1)
        #expect(carriers.filter { $0.has("data-wsui-name") }.count == 1)
    }

    @Test func resultIntoGoesThroughTheVariablesUpdater() {
        let target = Self.variable("vr", .string)
        let post = CompileActions([.post(url: "/x", values: [], resultInto: target)], builderId: "el0")
        let get = CompileActions([.get(url: "/x", resultInto: target)], builderId: "el0")
        for (js, source) in [(post, "action.post"), (get, "action.get")] {
            #expect(js.contains("updateWebVariablevr(xhr"), "\(source)")
            #expect(js.contains("source: '\(source)'"))
            #expect(js.contains("vr = xhr") == false)
        }
    }

    @Test func scrollToWithoutARefUsesTheElementsGlobal() {
        let js = CompileActions([.scrollTo(behavior: .auto)], builderId: "el0")
        #expect(js.contains("var element = el0;"))
        #expect(js.contains("getElementById") == false)
        #expect(js.contains("if (element)"))
    }

    @Test func bootstrapActionsReuseTheElementsInstance() {
        let js = CompileActions([.showOffCanvas(ref: "oc"), .hideOffCanvas(ref: "oc"), .carouselNext(ref: "c"),
                                 .carouselPrev(ref: "c"), .carouselTo(ref: "c", index: 2), .accordionToggle(ref: "a")],
                                builderId: "el0")
        #expect(js.contains("new bootstrap.") == false)
        #expect(js.contains("bootstrap.Offcanvas.getOrCreateInstance(offcanvasElement).show()"))
        #expect(js.contains("bootstrap.Offcanvas.getOrCreateInstance(offcanvasElement).hide()"))
        #expect(js.contains("bootstrap.Carousel.getOrCreateInstance(carouselElement).to(2)"))
        #expect(js.contains("bootstrap.Collapse.getOrCreateInstance(accordionElement, { toggle: false }).toggle()"))
        #expect(CompileActions([.popover(title: "t", content: "c")], builderId: "el0").contains("bootstrap.Popover.getOrCreateInstance(el0,"))
    }

    @Test func segmentedPickerUpdatesOnlyItsButtons() {
        let html = renderHTML { page in
            page.Picker(selection: page.WString("a"), style: .segmented(.primary)) {
                page.Text("A").value("a")
                page.Text("B").value("b")
            }
        }
        #expect(html.contains("document.querySelectorAll('button."))
        #expect(html.contains("document.querySelectorAll('.") == false)
    }
}

// MARK: - Password inputs made after creation

final class P1VerifyLatePasswordPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "p1-verify-late-password"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }

    override func content() -> Any? {
        return webpage {
            Form {
                TextField(binding: WString("seeded-p3").name("p3")).type("password")
                TextField(binding: WString("seeded-p4").name("p4")).addAttribute(.pair("type", "password"))
                TextField(binding: WString("seeded-p5").name("p5")).type(.password)
                TextField(binding: WString("kept").name("plain"))
                // a password field and a "show password" twin bound to the same variable
                let p6 = WString("").name("p6")
                TextField(binding: p6).type(.password)
                TextField(binding: p6)
                // and a later, separate variable with the same name
                TextField(binding: WString("").name("p3"))
            }
        }
    }

    override func persist() -> Any? {
        if validateData([.named("p3", [.atLeast(1000)]), .named("p4", [.atLeast(1000)]),
                         .named("p5", [.atLeast(1000)]), .named("p6", [.atLeast(1000)]), .named("plain", [])]) == false {
            return content()
        }
        return HttpResponse().status(.ok).content(.text).body("saved")
    }
}

@Suite("Phase 1 verify: inputs made password inputs after creation")
struct P1VerifyLatePasswordTests {

    @Test func seededValuesAreNeverRendered() {
        let server = TestHTTP.server()
        server.register(P1VerifyLatePasswordPage())
        let html = server.respond(to: TestHTTP.request(.GET, "/p1-verify-late-password")).bodyString
        for seeded in ["seeded-p3", "seeded-p4", "seeded-p5"] {
            #expect(html.contains(seeded) == false, "\(seeded)")
        }
        #expect(html.contains("kept"))
        // the last type wins: each is a real password input, with one type attribute
        let inputs = FormsHTML.controls(in: html).filter { $0.name == "input" && $0.attribute("type") != "hidden" }
        for name in ["p3", "p4", "p5", "p6"] {
            let field = inputs.first { $0.attribute("name") == name }
            #expect(field?.attribute("type") == "password", "\(name)")
            #expect(field?.all("type").count == 1, "\(name)")
        }
    }

    @Test func submittedSecretsAreNeverEchoedAfterAFailedValidation() {
        let server = TestHTTP.server()
        server.register(P1VerifyLatePasswordPage())
        let html = FormsHTML.post(server, "/p1-verify-late-password",
                                  [("p3", "SECRET-P3"), ("p4", "SECRET-P4"), ("p5", "SECRET-P5"), ("p6", "SECRET-P6"),
                                   ("plain", "typed")]).bodyString
        #expect(html != "saved")
        for secret in ["SECRET-P3", "SECRET-P4", "SECRET-P5", "SECRET-P6"] {
            #expect(html.contains(secret) == false, "\(secret) echoed")
        }
        // the plain field is still restored
        #expect(html.contains("typed"))
    }
}

// MARK: - Navigation

@Suite("Phase 1 verify: dropdown entries can be active")
struct P1VerifyNavigationTests {

    @Test func activeDropdownAndItemAreMarked() {
        let html = renderHTML { page in
            page.NavDropdown(title: "Controls", id: "dd", active: true) {
                page.NavDropdownItem(title: "Actions", href: "/actions", active: true)
                page.NavDropdownItem(title: "Forms", href: "/forms")
            }
        }
        #expect(html.contains("nav-link dropdown-toggle active"))
        let items = P1VerifyHTML.tags(named: "a", in: html).filter { $0.attribute("class")?.contains("dropdown-item") == true }
        #expect(items.count == 2)
        #expect(items.first?.attribute("class")?.contains("active") == true)
        #expect(items.first?.attribute("aria-current") == "page")
        #expect(items.last?.attribute("class")?.contains("active") == false)
        #expect(items.last?.has("aria-current") == false)
    }

    @Test func dropdownsAreInactiveByDefault() {
        let html = renderHTML { page in
            page.NavDropdown(title: "Controls", id: "dd") {
                page.NavDropdownItem(title: "Actions", href: "/actions")
            }
        }
        #expect(html.contains(" active") == false)
    }
}

// MARK: - Script isolation

/// The HTML tokenizer's script data states (WHATWG 13.2.5.4-13.2.5.31, simplified): where each `<script>`
/// element's content ends. Returns the content of every script element in order.
enum P1ScriptTokenizer {

    static func scriptContents(in html: String) -> [String] {
        let bytes = Array(html.utf8)
        var contents: [String] = []
        var i = 0
        func matches(_ s: String, at index: Int, caseInsensitive: Bool = true) -> Bool {
            let needle = Array(s.utf8)
            guard index + needle.count <= bytes.count else { return false }
            for k in 0..<needle.count {
                var b = bytes[index + k]
                if caseInsensitive, b >= 0x41, b <= 0x5A { b += 0x20 }
                if b != needle[k] { return false }
            }
            return true
        }
        func endsTagName(at index: Int) -> Bool {
            guard index < bytes.count else { return false }
            return [0x20, 0x09, 0x0A, 0x0C, 0x0D, 0x2F, 0x3E].contains(bytes[index])
        }
        while i < bytes.count {
            guard matches("<script", at: i), endsTagName(at: i + 7) else { i += 1; continue }
            // skip to the end of the start tag
            guard let close = bytes[i...].firstIndex(of: 0x3E) else { break }
            let start = close + 1
            enum State { case data, escaped, doubleEscaped }
            var state = State.data
            var j = start
            var end: Int? = nil
            while j < bytes.count {
                switch state {
                    case .data:
                        if matches("<!--", at: j) { state = .escaped; j += 4; continue }
                        if matches("</script", at: j), endsTagName(at: j + 8) { end = j }
                    case .escaped:
                        if matches("-->", at: j) { state = .data; j += 3; continue }
                        if matches("</script", at: j), endsTagName(at: j + 8) { end = j }
                        if matches("<script", at: j), endsTagName(at: j + 7) { state = .doubleEscaped; j += 7; continue }
                    case .doubleEscaped:
                        if matches("-->", at: j) { state = .data; j += 3; continue }
                        if matches("</script", at: j), endsTagName(at: j + 8) { state = .escaped; j += 8; continue }
                }
                if end != nil { break }
                j += 1
            }
            let stop = end ?? bytes.count
            contents.append(String(decoding: bytes[start..<stop], as: UTF8.self))
            i = stop + 1
        }
        return contents
    }
}

@Suite("Phase 1 verify: one script can't take the page's scripts down")
struct P1VerifyScriptIsolationTests {

    @Test func aRawScriptWithAnHTMLCommentOpenerEndsWhereItShould() {
        let html = renderHTML { page in
            page.Text("first").script("window.__raw1 = '<!--<script>';")
            let s = page.WString("init")
            page.Text("$0", s)
            page.Button("Go").onClick([.setVariable(s, to: "clicked")])
        }
        // every script element ends at its own end tag: the raw one doesn't swallow the framework block
        let byTokenizer = P1ScriptTokenizer.scriptContents(in: html)
        let byScan = ScriptScan.inlineScripts(in: html)
        #expect(byTokenizer.count == byScan.count)
        #expect(byTokenizer.contains { $0.contains("__raw1") && $0.hasSuffix("//-->\n") })
        #expect(byTokenizer.contains { $0.contains("function updateWebVariable") && $0.contains("__raw1") == false })
        #expect(html.hasSuffix("</html>\n"))
    }

    @Test func aHeadScriptWithAnHTMLCommentOpenerIsTerminatedToo() {
        let html = renderHTML { page in
            page.head(.inlineScript("var x = '<!--<script>';"))
            page.Text("body")
        }
        let contents = P1ScriptTokenizer.scriptContents(in: html)
        #expect(contents.first?.contains("var x") == true)
        #expect(contents.first?.contains("</head>") == false)
    }

    @Test func scriptsWithoutAnOpenerAreUnchanged() {
        let html = renderHTML { page in
            page.Text("x").script("window.y = 1;")
        }
        #expect(html.contains("//-->") == false)
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func anOddBuilderIdGetsEveryScriptItsOwnElement() throws {
        let html = renderHTML { page in
            let s = page.WString("init")
            page.Text("$0", s)
            let odd = page.Button("Odd")
            odd.builderId = "9lives"
            odd.onClick([.addClass("hit")])
            page.Button("Go").onClick([.setVariable(s, to: "clicked")])
        }
        let scripts = ScriptScan.inlineScripts(in: html)
        // the scripts that mention the odd id are syntax errors on their own; every other one still parses
        let result = try NodeJS.run(scripts: scripts)
        let broken = result.syntaxErrors.count
        #expect(broken >= 1)
        #expect(broken == scripts.filter { $0.contains("9lives") }.count)
        #expect(scripts.contains { $0.contains("function updateWebVariable") && $0.contains("9lives") == false })
    }

    @Test func generatedIdsKeepTheSharedBlock() {
        let html = renderHTML { page in
            let s = page.WString("init")
            page.Text("$0", s)
            page.Button("Go").onClick([.setVariable(s, to: "clicked")])
        }
        #expect(ScriptScan.inlineScripts(in: html).count == 1)
    }
}
