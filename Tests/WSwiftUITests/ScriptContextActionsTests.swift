//
//  ScriptContextActionsTests.swift
//  WSwiftUITests
//
//  H9: the action compiler must emit every Swift value as a script-safe literal. Every WebAction case
//  that carries a String (directly, or via WebColor.custom / Operator.equals / variable names) is in
//  `ActionCatalog`, and each one is checked three ways with the hostile payload:
//   1. statically: no raw payload fragment in the generated JS / rendered page, balanced <script> tags;
//   2. syntactically: every inline script of the rendered page compiles as a classic script (Node vm);
//   3. semantically: the compiled JS runs in a recording sandbox and must hand the *exact* Swift value
//      to the DOM/BOM API it targets.
//

import Foundation
import Testing
@testable import WSwiftUI

private let H = Hostile.payload
private let J = Hostile.jsonLiteral(Hostile.payload)

/// Variables referenced by the catalog's actions.
struct ActionFixture {
    let s: WebVariableElement   // string variable named with the payload
    let a: WebVariableElement   // array variable
    let t: WebVariableElement   // plain string variable used as a target

    /// Variables created on a page, so their own definition scripts are rendered and checked too.
    static func onPage(_ page: ClosurePage) -> ActionFixture {
        return ActionFixture(s: page.WString(H).name(H),
                             a: page.WArray([H, "x"]).name(H),
                             t: page.WString("").name("target"))
    }

    /// Detached variables with fixed identifiers for the sandbox (`vs`, `va`, `vt`).
    static func detached() -> ActionFixture {
        func variable(_ id: String, _ type: WebVariableType) -> WebVariableElement {
            let element = WebVariableElement()
            element.builderId = id
            element.variableType = type
            element.internalName = H
            return element
        }
        return ActionFixture(s: variable("vs", .string), a: variable("va", .array), t: variable("vt", .string))
    }
}

struct ActionSpec {
    var make: (ActionFixture) -> [WebAction]
    /// Strings the compiled code must pass to the DOM/BOM (exact match).
    var observe: [String] = []
    /// JSON object keys that must appear in a recorded value (e.g. a POST body).
    var observeKeys: [String] = []
    /// Substrings that some recorded string must contain.
    var contain: [String] = []
    /// Strings that must not be observed (the wrong branch ran).
    var notObserve: [String] = []
    /// Sandbox globals for the detached fixture (name -> JS expression).
    var globals: [String: String] = [:]
}

enum ActionCatalog {

    /// `encodeURIComponent`, implemented independently of the code under test.
    static func encodeURIComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)!
    }

    static func jsonText(_ object: Any) -> String {
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: []), as: UTF8.self)
    }

    static let videoSource = "src=\"\(WebEscape.attribute(H))\""

    // BackgroundVideoOptions carrying the payload in both string fields (poster, videoType)
    static var hostileVideoOptions: BackgroundVideoOptions { BackgroundVideoOptions(poster: H, videoType: H) }
    static let videoPoster = "poster=\"\(WebEscape.attribute(H))\""
    static let videoTypeAttribute = "type=\"\(WebEscape.attribute(H))\""

    // regexExtract fixtures: a pattern full of quotes/script/backtick, and a source it matches.
    static let regexPattern = "O'Brien \"(\\w+)\" </script> `tick`"
    static let regexSource = "O'Brien \"quoted\" </script> `tick`"

    static func catalog() -> [(String, ActionSpec)] {
        let refOnly: [(String, (String) -> WebAction)] = [
            ("hidden(ref:)", { .hidden(ref: $0, true) }),
            ("underline(ref:)", { .underline(ref: $0, true) }),
            ("bold(ref:)", { .bold(ref: $0, true) }),
            ("italic(ref:)", { .italic(ref: $0, true) }),
            ("strikethrough(ref:)", { .strikethrough(ref: $0, true) }),
            ("opacity(ref:)", { .opacity(ref: $0, 0.5) }),
            ("showOffCanvas(ref:)", { .showOffCanvas(ref: $0) }),
            ("hideOffCanvas(ref:)", { .hideOffCanvas(ref: $0) }),
            ("carouselNext(ref:)", { .carouselNext(ref: $0) }),
            ("carouselPrev(ref:)", { .carouselPrev(ref: $0) }),
            ("carouselTo(ref:index:)", { .carouselTo(ref: $0, index: 2) }),
            ("accordionToggle(ref:)", { .accordionToggle(ref: $0) }),
            ("progressSet(ref:value:)", { .progressSet(ref: $0, value: 40) }),
            ("scrollTo(ref:)", { .scrollTo(ref: $0, behavior: .smooth) }),
            ("fadeIn(ref:)", { .fadeIn(ref: $0, duration: 0.25) }),
            ("fadeOut(ref:)", { .fadeOut(ref: $0, duration: 0.25) }),
            ("fadeToggle(ref:)", { .fadeToggle(ref: $0, duration: 0.25) }),
            ("show(ref:)", { .show(ref: $0) }),
            ("hide(ref:)", { .hide(ref: $0) }),
            ("enable(ref:)", { .enable(ref: $0) }),
            ("disable(ref:)", { .disable(ref: $0) }),
            ("focus(ref:)", { .focus(ref: $0) }),
            ("blur(ref:)", { .blur(ref: $0) }),
            ("click(ref:)", { .click(ref: $0) }),
            ("tooltipShow(ref:)", { .tooltipShow(ref: $0) }),
            ("tooltipHide(ref:)", { .tooltipHide(ref: $0) }),
            ("toastShow(ref:)", { .toastShow(ref: $0) }),
            ("toastHide(ref:)", { .toastHide(ref: $0) }),
            ("tabShow(ref:)", { .tabShow(ref: $0) }),
            ("fontSize(ref:)", { .fontSize(ref: $0, 12) }),
        ]

        let extractGlobals = ["result": Hostile.jsonLiteral(jsonText([H: "found"]))]

        var specs: [(String, ActionSpec)] = [
            // JavaScript source by design: still raw, still works
            ("script (raw JS by design)", ActionSpec(make: { _ in [.script("window.alert('raw ' + 1);")] }, observe: ["raw 1"])),
            ("post + handleResponse (raw JS by design)", ActionSpec(make: { f in
                [.post(url: H, values: [f.s], onSuccessful: [.handleResponse(script: "window.alert(body);")])]
            }, observe: [H], globals: ["vs": J])),
            ("setVariableFromExpression (raw JS by design)", ActionSpec(make: { f in
                [.setVariableFromExpression(into: f.t, expression: "'expr ' + 'value'")]
            }, observe: ["expr value"])),
            ("animate(ref:) (keyframes/options raw JS by design)", ActionSpec(make: { _ in
                [.animate(ref: H, keyframes: "[{ opacity: 0 }, { opacity: 1 }]", options: "{ duration: 10 }")]
            }, observe: [H])),

            ("load(ref:url:)", ActionSpec(make: { _ in [.load(ref: H, url: H)] }, observe: [H])),
            ("load(url:)", ActionSpec(make: { _ in [.load(url: H)] }, observe: [H])),
            ("navigate", ActionSpec(make: { _ in [.navigate(H)] }, observe: [H])),
            ("post(url:values:)", ActionSpec(make: { f in [.post(url: H, values: [f.s])] },
                                             observe: [H], observeKeys: [H], globals: ["vs": J])),
            ("setVariable(to: String)", ActionSpec(make: { f in [.setVariable(f.s, to: H)] }, observe: [H])),
            ("setVariable(to: non-primitive)", ActionSpec(make: { f in [.setVariable(f.s, to: [H])] },
                                                          observe: [String(describing: [H])])),
            ("setInput", ActionSpec(make: { _ in [.setInput(H, to: H)] }, observe: [H])),
            // the variable is found by its carrier's data-wsui-name, and its updater gets the value
            ("setVariableName", ActionSpec(make: { _ in [.setVariableName(H, to: H)] }, observe: [H],
                                           globals: ["document": "{ querySelectorAll: function () { return [{ id: 'hiddenInput_vx', getAttribute: function () { return \(Hostile.jsonLiteral(H)); } }]; } }",
                                                     "window": "{ updateWebVariablevx: __deep('updateWebVariablevx') }"])),
            ("addClass", ActionSpec(make: { _ in [.addClass(H)] }, observe: [H])),
            ("removeClass", ActionSpec(make: { _ in [.removeClass(H)] }, observe: [H])),
            ("if(.equals(String))", ActionSpec(make: { f in
                [.if(f.s, .equals(H), [.alert("matched")], [.alert("not matched")])]
            }, observe: ["matched"], notObserve: ["not matched"], globals: ["vs": J])),
            ("foregroundColor(.custom)", ActionSpec(make: { _ in [.foregroundColor(ref: H, .custom(H))] }, observe: [H])),
            ("backgroundColor(.custom)", ActionSpec(make: { _ in [.backgroundColor(ref: H, .custom(H))] }, observe: [H])),
            ("setBackgroundColor(.custom)", ActionSpec(make: { _ in [.setBackgroundColor(ref: H, color: .custom(H))] }, observe: [H])),
            ("setBackgroundColor(no ref)", ActionSpec(make: { _ in [.setBackgroundColor(color: .custom(H))] }, observe: [H])),
            ("setBackgroundImage(ref:url:)", ActionSpec(make: { _ in [.setBackgroundImage(ref: H, url: H)] }, observe: [H, "url(\(H))"])),
            ("setBackgroundImage(url:)", ActionSpec(make: { _ in [.setBackgroundImage(url: H)] }, observe: ["url(\(H))"])),
            ("setBackgroundVideo(ref:url:)", ActionSpec(make: { _ in [.setBackgroundVideo(ref: H, url: H, options: nil)] },
                                                        observe: [H, "video_\(H)"],
                                                        contain: [videoSource, "id=\"\(WebEscape.attribute("video_\(H)"))\""])),
            ("setBackgroundVideo(url:)", ActionSpec(make: { _ in [.setBackgroundVideo(url: H, options: nil)] }, contain: [videoSource])),
            ("setPageBackgroundColor(.custom)", ActionSpec(make: { _ in [.setPageBackgroundColor(color: .custom(H))] }, observe: [H])),
            ("setPageBackgroundImage", ActionSpec(make: { _ in [.setPageBackgroundImage(url: H)] }, observe: ["url(\(H))"])),
            ("setPageBackgroundVideo", ActionSpec(make: { _ in [.setPageBackgroundVideo(url: H, options: nil)] }, contain: [videoSource])),
            ("setBackgroundVideo(ref:url:options:) hostile options", ActionSpec(make: { _ in
                [.setBackgroundVideo(ref: H, url: H, options: hostileVideoOptions)]
            }, observe: [H, "video_\(H)"], contain: [videoSource, videoPoster, videoTypeAttribute])),
            ("setBackgroundVideo(url:options:) hostile options", ActionSpec(make: { _ in
                [.setBackgroundVideo(url: H, options: hostileVideoOptions)]
            }, contain: [videoSource, videoPoster, videoTypeAttribute])),
            ("setPageBackgroundVideo(options:) hostile options", ActionSpec(make: { _ in
                [.setPageBackgroundVideo(url: H, options: hostileVideoOptions)]
            }, contain: [videoSource, videoPoster, videoTypeAttribute])),
            ("underlineColor(.custom)", ActionSpec(make: { _ in [.underlineColor(ref: H, .custom(H))] }, observe: [H])),
            ("fontFamily", ActionSpec(make: { _ in [.fontFamily(ref: H, H)] }, observe: [H])),
            ("fontWeight", ActionSpec(make: { _ in [.fontWeight(ref: H, H)] }, observe: [H])),
            ("showModal(ref:contentURL:)", ActionSpec(make: { _ in [.showModal(ref: H, contentURL: H)] }, observe: [H])),
            ("showModal(ref:)", ActionSpec(make: { _ in [.showModal(ref: H)] })),
            ("hideModal(ref:)", ActionSpec(make: { _ in [.hideModal(ref: H)] })),
            ("collapse(ref:)", ActionSpec(make: { _ in [.collapse(ref: H)] }, observe: ["#\(H)"])),
            ("popover(title:content:)", ActionSpec(make: { _ in [.popover(title: H, content: H + "2")] }, observe: [H, H + "2"])),
            ("spinnerSet", ActionSpec(make: { _ in [.spinnerSet(ref: H, type: .grow, size: .small, color: .custom(H), label: H + "2")] },
                                      observe: [H, H + "2", "spinner-grow", "spinner-border-sm"])),
            ("src(ref:url:)", ActionSpec(make: { _ in [.src(ref: H, url: H)] }, observe: [H])),
            ("src(url:)", ActionSpec(make: { _ in [.src(url: H)] }, observe: [H])),
            ("addToArray", ActionSpec(make: { f in [.addToArray(variable: f.a, value: H)] }, observe: [H], globals: ["va": "'[]'"])),
            ("removeFromArray", ActionSpec(make: { f in [.removeFromArray(variable: f.a, value: H)] },
                                           observe: ["kept"], notObserve: [H],
                                           globals: ["va": Hostile.jsonLiteral(jsonText(["kept", H]))])),
            ("toggleArray", ActionSpec(make: { f in [.toggleArray(variable: f.a, value: H)] }, observe: [H], globals: ["va": "'[]'"])),
            // (`.extractJSON` shadows `result` with a hoisted `var`, so it never sees the outer value; that
            // pre-existing bug is out of scope here. Its key literal is checked in `extractJSONKeyLiteral`.)
            ("extractJSON(key:)", ActionSpec(make: { f in
                [.extractJSON(key: H, actions: [.setVariableFromExpression(into: f.t, expression: "result")])]
            }, globals: extractGlobals)),
            ("extractJSONInto(key:)", ActionSpec(make: { f in [.extractJSONInto(key: H, into: f.t)] },
                                                 observe: ["found"], globals: extractGlobals)),
            ("evaluate(.equals(String))", ActionSpec(make: { _ in
                [.evaluate(op: .equals(H), [.alert("matched")], [.alert("not matched")])]
            }, observe: ["matched"], notObserve: ["not matched"], globals: ["result": J])),
            ("text(ref:)", ActionSpec(make: { _ in [.text(ref: H, H)] }, observe: [H])),
            ("text", ActionSpec(make: { _ in [.text(H)] }, observe: [H])),
            ("html(ref:)", ActionSpec(make: { _ in [.html(ref: H, H)] }, observe: [H])),
            ("html", ActionSpec(make: { _ in [.html(H)] }, observe: [H])),
            ("appendHTML", ActionSpec(make: { _ in [.appendHTML(ref: H, H)] }, observe: [H])),
            ("prependHTML", ActionSpec(make: { _ in [.prependHTML(ref: H, H)] }, observe: [H])),
            ("setAttribute", ActionSpec(make: { _ in [.setAttribute(ref: H, name: H, value: H + "2")] }, observe: [H, H + "2"])),
            ("setAttribute(value: nil)", ActionSpec(make: { _ in [.setAttribute(name: H, value: nil)] }, observe: [H, ""])),
            ("removeAttribute", ActionSpec(make: { _ in [.removeAttribute(ref: H, name: H)] }, observe: [H])),
            ("toggleClass", ActionSpec(make: { _ in [.toggleClass(ref: H, className: H)] }, observe: [H])),
            ("setCSSVariable", ActionSpec(make: { _ in [.setCSSVariable(ref: H, name: H, value: H + "2")] }, observe: [H, H + "2"])),
            ("setStyles", ActionSpec(make: { _ in [.setStyles(ref: H, styles: [H: H + "2", "color": "red"])] }, observe: [H, H + "2", "red"])),
            ("addClassFor", ActionSpec(make: { _ in [.addClassFor(ref: H, className: H + "2", durationMs: 10)] }, observe: [H, H + "2"])),
            ("localStorageSet", ActionSpec(make: { f in [.localStorageSet(key: H, value: f.s)] }, observe: [H])),
            ("localStorageGet", ActionSpec(make: { f in [.localStorageGet(key: H, into: f.s)] }, observe: [H])),
            ("localStorageRemove", ActionSpec(make: { _ in [.localStorageRemove(key: H)] }, observe: [H])),
            ("sessionStorageSet", ActionSpec(make: { f in [.sessionStorageSet(key: H, value: f.s)] }, observe: [H])),
            ("sessionStorageGet", ActionSpec(make: { f in [.sessionStorageGet(key: H, into: f.s)] }, observe: [H])),
            ("sessionStorageRemove", ActionSpec(make: { _ in [.sessionStorageRemove(key: H)] }, observe: [H])),
            ("get(url:params:)", ActionSpec(make: { f in [.get(url: H, params: [f.s])] },
                                            observe: [H + "?" + encodeURIComponent(H) + "=v"], globals: ["vs": "'v'"])),
            ("download", ActionSpec(make: { _ in [.download(url: H, filename: H + "2")] }, observe: [H, H + "2"])),
            ("historyPush", ActionSpec(make: { _ in [.historyPush(url: H, title: H + "2")] }, observe: [H, H + "2"])),
            ("historyReplace", ActionSpec(make: { _ in [.historyReplace(url: H, title: H + "2")] }, observe: [H, H + "2"])),
            ("openNewWindow", ActionSpec(make: { _ in [.openNewWindow(url: H, target: H + "2")] }, observe: [H, H + "2"])),
            ("delay", ActionSpec(make: { _ in [.delay(seconds: 0.01, actions: [.alert(H)])] }, observe: [H])),
            ("alert", ActionSpec(make: { _ in [.alert(H)] }, observe: [H])),
            ("confirm", ActionSpec(make: { _ in [.confirm(H, ifYes: [.alert("yes")], ifNo: [.alert("no")])] },
                                   observe: [H, "yes"], notObserve: ["no"])),
            ("regexExtract(pattern:)", ActionSpec(make: { f in
                [.regexExtract(source: f.s, pattern: regexPattern, group: 1, into: f.t)]
            }, observe: ["quoted"], globals: ["vs": Hostile.jsonLiteral(regexSource)])),
            ("setAria", ActionSpec(make: { _ in [.setAria(ref: H, name: H, value: H + "2")] }, observe: [H, H + "2"])),
            ("ariaAnnounce", ActionSpec(make: { _ in [.ariaAnnounce(message: H, politeness: H + "2")] }, observe: [H, H + "2"],
                                        globals: ["document": "{ getElementById: function () { return null; }, createElement: function () { return __deep('liveRegion'); }, body: __deep('document.body') }"])),
            ("random", ActionSpec(make: { _ in [.random([.alert(H)])] }, observe: [H])),
        ]
        for (name, make) in refOnly {
            specs.append((name, ActionSpec(make: { _ in [make(H)] }, observe: [H])))
        }
        return specs
    }

    static let names: [String] = catalog().map { $0.0 }

    static func spec(_ name: String) -> ActionSpec {
        return catalog().first(where: { $0.0 == name })!.1
    }
}

@Suite("Script context: action compiler")
struct ScriptContextActionsTests {

    @Test("String-carrying WebAction emits script-safe JS", arguments: ActionCatalog.names)
    func actionIsScriptSafe(_ name: String) throws {
        let spec = ActionCatalog.spec(name)

        // 1. the compiled JS on its own
        let detached = ActionFixture.detached()
        let js = CompileActions(spec.make(detached), builderId: "el0")
        ScriptScan.expectScriptSafe(js)

        // 2. the action wired to a button on a real page
        let html = renderHTML { page in
            let fixture = ActionFixture.onPage(page)
            page.Button("Go").onClick(spec.make(fixture))
        }
        ScriptScan.expectNoBreakout(html)

        // 3. syntax of every inline script + semantics of the compiled JS
        guard NodeJS.isAvailable else { return }
        let result = try NodeJS.run(scripts: ScriptScan.inlineScripts(in: html) + [js],
                                    code: js,
                                    globals: spec.globals)
        #expect(result.syntaxErrors.isEmpty, "\(result.syntaxErrors.joined(separator: "\n"))")
        #expect(result.error == nil, "\(result.error ?? "")")
        let observed = result.observedStrings
        for value in spec.observe {
            #expect(observed.contains(value), "value not handed to the DOM intact: \(value.debugDescription)")
        }
        let keys = result.observedKeys
        for key in spec.observeKeys {
            #expect(keys.contains(key), "key not observed: \(key.debugDescription)")
        }
        for needle in spec.contain {
            #expect(observed.contains(where: { $0.contains(needle) }), "no recorded value contains \(needle.debugDescription)")
        }
        for value in spec.notObserve {
            #expect(observed.contains(value) == false, "unexpected value observed: \(value.debugDescription)")
        }
    }

    /// Every inline script of a page carrying every catalogued action must pass the real `node --check`.
    @Test(.enabled(if: NodeJS.isAvailable))
    func allActionsOnOnePagePassNodeCheck() throws {
        let html = renderHTML { page in
            let fixture = ActionFixture.onPage(page)
            for (_, spec) in ActionCatalog.catalog() {
                page.Button("Go").onClick(spec.make(fixture))
            }
        }
        ScriptScan.expectNoBreakout(html)
        let scripts = ScriptScan.inlineScripts(in: html)
        // the element scripts share the end-of-body block (raw-JS actions get a <script> of their own); every
        // button's click listener is in one of them
        #expect(scripts.isEmpty == false)
        #expect(scripts.joined().components(separatedBy: ".addEventListener('click'").count - 1 == ActionCatalog.names.count)
        let diagnostics = try NodeJS.nodeCheck(scripts)
        #expect(diagnostics.isEmpty, "\(diagnostics.prefix(4000))")
    }

    /// Ordinary values keep their JS semantics (only the quoting style changed from '…' to "…").
    @Test func ordinaryValuesCompileAsBefore() {
        let v = ActionFixture.detached().s
        #expect(CompileActions([.setVariable(v, to: "Saved")], builderId: "el0")
                == "updateWebVariablevs(\"Saved\", { source: 'action.setVariable', origin: 'el0' });\n")
        #expect(CompileActions([.setVariable(v, to: 75)], builderId: "el0")
                == "updateWebVariablevs(75, { source: 'action.setVariable', origin: 'el0' });\n")
        #expect(CompileActions([.setVariable(v, to: 1.5)], builderId: "el0")
                == "updateWebVariablevs(1.5, { source: 'action.setVariable', origin: 'el0' });\n")
        #expect(CompileActions([.setVariable(v, to: true)], builderId: "el0")
                == "updateWebVariablevs(true, { source: 'action.setVariable', origin: 'el0' });\n")
        #expect(CompileActions([.setVariable(v, to: nil)], builderId: "el0")
                == "updateWebVariablevs(\"\", { source: 'action.setVariable', origin: 'el0' });\n")
        #expect(CompileActions([.navigate("/applications/edit?application=1")], builderId: "el0")
                == "window.location.href = \"/applications/edit?application=1\";\n")
        #expect(CompileActions([.text(ref: "target", "Updated text")], builderId: "el0")
                == "document.getElementById(\"target\").textContent = \"Updated text\";\n")
        #expect(CompileActions([.backgroundColor(ref: nil, .custom("#f8faff"))], builderId: "el0")
                == "el0.style.backgroundColor = \"#f8faff\";\n")
        #expect(CompileActions([.setStyles(styles: ["transform": "scale(1)", "boxShadow": ""])], builderId: "el0")
                == "(function(el, styles){ if(!el) return; for (var k in styles){ if (Object.prototype.hasOwnProperty.call(styles,k)) { el.style[k] = styles[k]; } } })(el0, {\"boxShadow\":\"\",\"transform\":\"scale(1)\"});\n")
        #expect(CompileActions([.if(v, .equals("Saved"), [.reload], nil)], builderId: "el0")
                == "if (vs == \"Saved\") {\nwindow.location.reload();\n\n}\n")
        #expect(CompileActions([.if(v, .equals(3), [.reload], nil)], builderId: "el0")
                == "if (vs == 3) {\nwindow.location.reload();\n\n}\n")
        #expect(CompileActions([.if(v, .isPositive, [.reload], nil)], builderId: "el0")
                == "if (vs > 0) {\nwindow.location.reload();\n\n}\n")
    }

    /// The key path of `.extractJSON` evaluates to exactly the Swift string.
    @Test(.enabled(if: NodeJS.isAvailable))
    func extractJSONKeyLiteral() throws {
        let js = CompileActions([.extractJSON(key: H, actions: [])], builderId: "el0")
        let regex = try NSRegularExpression(pattern: "var __path = (.*);\n", options: [])
        let ns = js as NSString
        let match = try #require(regex.firstMatch(in: js, range: NSRange(location: 0, length: ns.length)))
        let literal = ns.substring(with: match.range(at: 1))
        let result = try NodeJS.run(literals: ["path": literal])
        #expect(result.values["path"]?["str"] as? String == H)
    }

    /// Non-finite numbers become JS NaN/Infinity instead of the undefined identifiers `nan`/`inf`, and a
    /// non-finite delay no longer traps the server.
    @Test func nonFiniteNumbers() {
        #expect(CompileActions([.opacity(ref: nil, .nan)], builderId: "el0") == "el0.style.opacity = NaN;\n")
        #expect(CompileActions([.opacity(ref: nil, .infinity)], builderId: "el0") == "el0.style.opacity = Infinity;\n")
        #expect(CompileActions([.opacity(ref: nil, 0.5)], builderId: "el0") == "el0.style.opacity = 0.5;\n")
        #expect(CompileActions([.delay(seconds: .nan, actions: [])], builderId: "el0").hasSuffix("}, 0);\n"))
        #expect(CompileActions([.delay(seconds: 1.5, actions: [])], builderId: "el0").hasSuffix("}, 1500);\n"))
        // an infinite / huge delay waits as long as setTimeout can (2^31 - 1 ms) instead of overflowing
        #expect(CompileActions([.delay(seconds: .infinity, actions: [])], builderId: "el0").hasSuffix("}, 2147483647);\n"))
        #expect(CompileActions([.delay(seconds: 1e300, actions: [])], builderId: "el0").hasSuffix("}, 2147483647);\n"))
        #expect(CompileActions([.delay(seconds: -1, actions: [])], builderId: "el0").hasSuffix("}, 0);\n"))
    }

    /// Decodes the five entities `WebEscape.attribute` produces.
    private static func decodeAttribute(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Parses `<video …><source …></video>` strictly (attribute values must be double-quoted, as the
    /// compiler writes them). Returns each tag's decoded attributes, or nil if the markup has any other
    /// shape, e.g. because a value closed its quote and injected an attribute or an element.
    static func parseVideoMarkup(_ markup: String) -> (video: [String: String], source: [String: String])? {
        let attrs = "((?:\\s+[^\\s\"'>/=]+(?:=\"[^\"]*\")?)*)"
        let whole = try! NSRegularExpression(pattern: "^\\s*<video\(attrs)\\s*>\\s*<source\(attrs)\\s*>\\s*</video>\\s*$", options: [])
        let ns = markup as NSString
        guard let match = whole.firstMatch(in: markup, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let attribute = try! NSRegularExpression(pattern: "([^\\s\"'>/=]+)(?:=\"([^\"]*)\")?", options: [])
        func parse(_ range: NSRange) -> [String: String]? {
            let text = ns.substring(with: range)
            let tn = text as NSString
            var result: [String: String] = [:]
            for m in attribute.matches(in: text, range: NSRange(location: 0, length: tn.length)) {
                let name = tn.substring(with: m.range(at: 1))
                let value = m.range(at: 2).location == NSNotFound ? "" : decodeAttribute(tn.substring(with: m.range(at: 2)))
                if result[name] != nil { return nil }   // duplicate attribute
                result[name] = value
            }
            return result
        }
        guard let video = parse(match.range(at: 1)), let source = parse(match.range(at: 2)) else { return nil }
        return (video, source)
    }

    /// BackgroundVideoOptions.poster / videoType and the url are attribute values in markup inserted with
    /// insertAdjacentHTML: hostile values must come out as exactly those attribute values, with no extra
    /// attribute or element (the reviewer's probes plus the generic payload).
    @Test(.enabled(if: NodeJS.isAvailable), arguments: [
        ("x\" onerror=\"alert(1)", "video/mp4\"><img src=x onerror=alert(2)>", "movie.mp4' onerror='alert(3)"),
        (H, H, H),
    ])
    func backgroundVideoOptionsBecomeExactAttributeValues(poster: String, videoType: String, url: String) throws {
        let options = BackgroundVideoOptions(controls: true, poster: poster, videoType: videoType)
        let cases: [(WebAction, String, String)] = [
            (.setBackgroundVideo(ref: "hero", url: url, options: options), "video_hero", "background-video"),
            (.setBackgroundVideo(url: url, options: options), "video_el0", "background-video"),
            (.setPageBackgroundVideo(url: url, options: options), "pageBackgroundVideo", "page-background-video"),
        ]
        for (action, id, className) in cases {
            let js = CompileActions([action], builderId: "el0")
            ScriptScan.expectScriptSafe(js)
            let result = try NodeJS.run(scripts: [js], code: js)
            #expect(result.syntaxErrors.isEmpty, "\(result.syntaxErrors.joined(separator: "\n"))")
            #expect(result.error == nil, "\(result.error ?? "")")
            let inserts = result.records.compactMap { $0 as? [String: Any] }.filter {
                ($0["op"] as? String) == "call" && (($0["path"] as? String)?.hasSuffix(".insertAdjacentHTML") ?? false)
            }
            #expect(inserts.count == 1)
            let args = try #require(inserts.first?["args"] as? [Any])
            #expect(args.first as? String == "afterbegin")
            let markup = try #require(args.dropFirst().first as? String)
            let parsed = try #require(Self.parseVideoMarkup(markup), "markup is not a single <video><source></video>: \(markup)")
            #expect(Set(parsed.video.keys) == ["id", "class", "autoplay", "loop", "muted", "controls", "poster"])
            #expect(parsed.video["id"] == id)
            #expect(parsed.video["class"] == className)
            #expect(parsed.video["poster"] == poster)
            #expect(parsed.source == ["src": url, "type": videoType])
        }
    }

    /// With real timers an infinite delay does not fire (node would otherwise clamp an overflowing delay
    /// to 1 ms and warn), while a short one does.
    @Test(.enabled(if: NodeJS.isAvailable))
    func infiniteDelayNeverFires() throws {
        let forever = try NodeJS.alertsWithRealTimers(
            CompileActions([.delay(seconds: .infinity, actions: [.alert("x")])], builderId: "el0"), waitMs: 100)
        #expect(forever.alerts == 0)
        #expect(forever.stderr.contains("TimeoutOverflowWarning") == false, "\(forever.stderr)")
        let huge = try NodeJS.alertsWithRealTimers(
            CompileActions([.delay(seconds: 1e300, actions: [.alert("x")])], builderId: "el0"), waitMs: 100)
        #expect(huge.alerts == 0)
        let control = try NodeJS.alertsWithRealTimers(
            CompileActions([.delay(seconds: 0.01, actions: [.alert("x")])], builderId: "el0"), waitMs: 100)
        #expect(control.alerts == 1)
    }
}
