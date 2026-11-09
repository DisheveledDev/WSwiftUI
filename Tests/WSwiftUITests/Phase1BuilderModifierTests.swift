//
//  Phase1BuilderModifierTests.swift
//  WSwiftUITests
//
//  Builder slice: frame(alignment:) no longer recurses, modifiers emit valid CSS and existing Bootstrap
//  classes, and every hidden(...) overload hides the element the same way.
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Helpers (builder slice)

/// Every class an element carries, in order (multi-class strings are split).
func phase1BuilderClasses(_ element: WebElement) -> [String] {
    return element.attributes.flatMap { attribute -> [String] in
        if case .class(let value) = attribute {
            return value.split(separator: " ").map(String.init)
        }
        return []
    }
}

/// Every inline style declaration an element carries, in order.
func phase1BuilderStyles(_ element: WebElement) -> [String] {
    return element.attributes.compactMap { attribute -> String? in
        if case .style(let value) = attribute { return value }
        return nil
    }
}

/// Every script attached to an element, in order.
func phase1BuilderScripts(_ element: WebElement) -> [String] {
    return element.attributes.compactMap { attribute -> String? in
        if case .script(let value) = attribute { return value }
        return nil
    }
}

/// Runs `code` with node and returns what it wrote to stdout.
func phase1BuilderRunNode(_ code: String) throws -> String {
    guard let node = NodeJS.path else { throw NodeJS.HarnessError.nodeMissing }
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wsui-phase1-builder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let scriptURL = dir.appendingPathComponent("run.js")
    try Data(code.utf8).write(to: scriptURL)
    let outputURL = dir.appendingPathComponent("stdout.txt")
    let errorURL = dir.appendingPathComponent("stderr.txt")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    let outHandle = try FileHandle(forWritingTo: outputURL)
    let errHandle = try FileHandle(forWritingTo: errorURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: node)
    process.arguments = [scriptURL.path]
    process.standardOutput = outHandle
    process.standardError = errHandle
    try process.run()
    process.waitUntilExit()
    try? outHandle.close()
    try? errHandle.close()
    let stdout = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
    let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
    if process.terminationStatus != 0 {
        throw NodeJS.HarnessError.badOutput(stdout + "\n" + stderr)
    }
    return stdout
}

// MARK: - frame

@Suite("Phase 1 builder: frame(alignment:)")
struct Phase1BuilderFrameTests {

    @Test func alignmentOnlyFrameAddsAlignmentClasses() {
        // `frame(alignment:)` resolves to the fill overload, which used to call itself until the stack overflowed
        let cases: [(WebFrameAlignment, [String])] = [(.leading, ["align-self-start", "me-auto"]),
                                                      (.center, ["align-self-center", "mx-auto"]),
                                                      (.trailing, ["align-self-end", "ms-auto"])]
        for (alignment, expected) in cases {
            let element = WebElement().frame(alignment: alignment)
            #expect(phase1BuilderClasses(element) == expected)
            #expect(phase1BuilderStyles(element).isEmpty)
        }
    }

    @Test func fillOverloadWithAlignment() {
        let width = WebElement().frame(fillWidth: true, alignment: .leading)
        #expect(phase1BuilderClasses(width) == ["w-100", "align-self-start", "me-auto"])
        let height = WebElement().frame(fillHeight: true, alignment: .trailing)
        #expect(phase1BuilderClasses(height) == ["h-100", "align-self-end", "ms-auto"])
        let both = WebElement().frame(fillWidth: true, fillHeight: true, alignment: .center)
        #expect(phase1BuilderClasses(both) == ["w-100", "h-100", "align-self-center", "mx-auto"])
        let fillOnly = WebElement().frame(fillWidth: true, fillHeight: true)
        #expect(phase1BuilderClasses(fillOnly) == ["w-100", "h-100"])
    }

    @Test func sizedFrameOutputIsUnchanged() {
        let element = WebElement().frame(width: 10, height: 20, minWidth: 5, maxWidth: 30, minHeight: 6, maxHeight: 40, alignment: .center)
        #expect(phase1BuilderStyles(element) == ["width: 10px", "height: 20px", "min-width: 5px",
                                                 "max-width: 30px", "min-height: 6px", "max-height: 40px"])
        #expect(phase1BuilderClasses(element) == ["align-self-center", "mx-auto"])
        let trailing = WebElement().frame(maxWidth: 300, alignment: .trailing)
        #expect(phase1BuilderStyles(trailing) == ["max-width: 300px"])
        #expect(phase1BuilderClasses(trailing) == ["align-self-end", "ms-auto"])
    }

    @Test func pageUsingFrameAlignmentRenders() {
        let html = renderHTML { page in
            page.Text("centred").frame(alignment: .center)
            page.Text("filled").frame(fillWidth: true, fillHeight: true, alignment: .trailing)
        }
        #expect(html.contains("align-self-center mx-auto"))
        #expect(html.contains("w-100 h-100 align-self-end ms-auto"))
        #expect(html.hasSuffix("</html>\n"))
    }
}

// MARK: - Valid CSS

@Suite("Phase 1 builder: modifiers emit valid CSS")
struct Phase1BuilderCSSTests {

    @Test func cornerRadiusUsesTheRealPropertyNames() {
        #expect(phase1BuilderStyles(WebElement().radius(.topLeft, 12)) == ["border-top-left-radius: 12px"])
        #expect(phase1BuilderStyles(WebElement().radius(.topRight, 1)) == ["border-top-right-radius: 1px"])
        #expect(phase1BuilderStyles(WebElement().radius(.bottomLeft, 2)) == ["border-bottom-left-radius: 2px"])
        #expect(phase1BuilderStyles(WebElement().radius(.bottomRight, 3)) == ["border-bottom-right-radius: 3px"])
        #expect(phase1BuilderStyles(WebElement().radius([.topLeft, .bottomRight], 4))
                == ["border-top-left-radius: 4px", "border-bottom-right-radius: 4px"])
        #expect(phase1BuilderStyles(WebElement().radius(8)) == ["border-radius: 8px"])
        let html = renderHTML { page in page.Text("r").radius(.topLeft, 12) }
        #expect(html.contains("style=\"border-top-left-radius: 12px\""))
    }

    @Test func autoOffsetsAreInlineStyles() {
        // Bootstrap has no top-auto / bottom-auto / start-auto / end-auto classes
        let top = WebElement().top(.auto)
        #expect(phase1BuilderClasses(top).isEmpty)
        #expect(phase1BuilderStyles(top) == ["top: auto"])
        #expect(phase1BuilderStyles(WebElement().bottom(.auto)) == ["bottom: auto"])
        #expect(phase1BuilderStyles(WebElement().start(.auto)) == ["left: auto"])
        #expect(phase1BuilderStyles(WebElement().end(.auto)) == ["right: auto"])
        for element in [WebElement().bottom(.auto), WebElement().start(.auto), WebElement().end(.auto)] {
            #expect(phase1BuilderClasses(element).isEmpty)
        }
    }

    @Test func otherOffsetsAreUnchanged() {
        #expect(phase1BuilderClasses(WebElement().top(.percent(50))) == ["top-50"])
        #expect(phase1BuilderClasses(WebElement().start(.percent(0))) == ["start-0"])
        #expect(phase1BuilderClasses(WebElement().end(.percent(100))) == ["end-100"])
        #expect(phase1BuilderStyles(WebElement().top(.percent(30))) == ["top: 30%"])
        #expect(phase1BuilderStyles(WebElement().bottom(.pixels(8))) == ["bottom: 8px"])
    }

    @Test func tableCellAndCardTextAlignmentUseBootstrap5Classes() {
        #expect(phase1BuilderClasses(WebTableCellElement().align("left")) == ["text-start"])
        #expect(phase1BuilderClasses(WebTableCellElement().align("right")) == ["text-end"])
        #expect(phase1BuilderClasses(WebTableCellElement().align("center")) == ["text-center"])
        #expect(phase1BuilderClasses(WebTableCellElement().align("start")) == ["text-start"])
        #expect(phase1BuilderClasses(WebTableCellElement().align("End")) == ["text-end"])
        let justified = WebTableCellElement().align("justify")
        #expect(phase1BuilderClasses(justified).isEmpty)
        #expect(phase1BuilderStyles(justified) == ["text-align: justify"])
        #expect(phase1BuilderClasses(WebTableCellElement().align("nowrap")) == ["text-nowrap"])
        #expect(phase1BuilderClasses(WebCardElement().textAlign("left")) == ["text-start"])
        #expect(phase1BuilderClasses(WebCardElement().textAlign("center")) == ["text-center"])
        #expect(phase1BuilderClasses(WebCardElement().textAlign("right")) == ["text-end"])
    }

    @Test func gradientAlwaysHasTwoStops() {
        #expect(phase1BuilderStyles(WebElement().background(.toTop, [.red]))
                == ["background-image: linear-gradient(to top,rgba(255,0,0,1),rgba(255,0,0,1))"])
        #expect(phase1BuilderStyles(WebElement().background(.toRight, [.red, .blue]))
                == ["background-image: linear-gradient(to right,rgba(255,0,0,1),rgba(0,0,255,1))"])
        #expect(phase1BuilderStyles(WebElement().background(.toTop, [])).isEmpty)
    }

    @Test func backgroundImageURLIsAQuotedCSSString() {
        #expect(phase1BuilderStyles(WebElement().backgroundImage("/img/hero.png"))
                == [#"background-image: url("/img/hero.png")"#])
        #expect(phase1BuilderStyles(WebElement().backgroundImage("/img/a b (1).png"))
                == [#"background-image: url("/img/a b (1).png")"#])
        // quotes and backslashes are escaped and a newline becomes a CSS hex escape, so the value stays one string
        #expect(phase1BuilderStyles(WebElement().backgroundImage("x\"); color: red; (\\\n"))
                == [#"background-image: url("x\"); color: red; (\\\a ")"#])
        let html = renderHTML { page in page.Text("bg").backgroundImage("/img/hero.png") }
        #expect(html.contains("style=\"background-image: url(&quot;/img/hero.png&quot;)\""))
    }

    /// Every class the layout modifiers can emit exists in Bootstrap 5.3.8 (the version the templates load).
    /// The allow-list was checked against bootstrap.css 5.3.8; a new class must be checked there first.
    @Test func modifiersOnlyEmitClassesBootstrapDefines() {
        var allowed: Set<String> = [
            "align-self-start", "align-self-center", "align-self-end", "me-auto", "mx-auto", "ms-auto", "my-auto", "m-auto",
            "w-100", "h-100", "justify-content-start", "justify-content-end", "justify-content-center",
            "align-items-start", "align-items-end", "align-items-center", "text-start", "text-end", "text-center",
            "text-nowrap", "text-wrap", "overflow-hidden", "visually-hidden", "d-none", "d-flex",
            "fw-bold", "fw-light", "fst-italic", "text-decoration-line-through", "text-decoration-underline",
            "text-decoration-none", "opacity-0", "opacity-25", "opacity-50", "opacity-75", "opacity-100", "collapse",
            "position-static", "position-relative", "position-absolute", "position-fixed", "sticky-top", "sticky-bottom",
            "translate-middle", "translate-middle-x", "translate-middle-y",
        ]
        for prefix in ["m", "mt", "mb", "ms", "me", "mx", "my", "p", "pt", "pb", "ps", "pe", "px", "py"] {
            for step in 0...5 { allowed.insert("\(prefix)-\(step)") }
        }
        for side in ["top", "bottom", "start", "end"] {
            for value in [0, 50, 100] { allowed.insert("\(side)-\(value)") }
        }
        for color in ["primary", "secondary", "success", "danger", "warning", "info", "light", "dark", "white"] {
            allowed.insert("text-\(color)")
            allowed.insert("bg-\(color)")
        }

        let element = WebElement()
        for alignment in [WebFrameAlignment.leading, .center, .trailing] {
            element.frame(alignment: alignment)
            element.frame(width: 1, alignment: alignment)
        }
        element.frame(fillWidth: true, fillHeight: true)
        let areas: [WebAreaPosition] = [.leading, .trailing, .top, .bottom, .horizontal, .vertical, .all]
        for pixels in [0, 4, 8, 16, 24, 48, 7] {
            element.margin(pixels)
            element.padding(pixels)
            for area in areas {
                element.margin(area, pixels)
                element.padding(area, pixels)
            }
        }
        element.margin(.auto)
        element.margin(.none)
        element.padding()
        let contentAlignments: [WebContentAlignment] = [.left, .right, .start, .end, .leading, .trailing, .middle, .top, .bottom, .center]
        for alignment in contentAlignments { element.align(alignment) }
        for alignment in [WebTextAlignment.left, .right, .start, .end, .center, .justify] { element.textalign(alignment) }
        for wrap in [WebTextWrapType.auto, .balance, .nowrap, .wrap, .stable] { element.wrap(wrap) }
        element.clip()
        for area in areas {
            element.centered(area)
            element.stretch(area)
        }
        element.bold().lightweight().italic().strikethrough().underline(true).underline(false)
        let colors: [WebColor] = [.red, .darkred, .lightred, .green, .lightgreen, .darkgreen, .blue, .lightblue, .darkblue,
                                  .yellow, .lightyellow, .darkyellow, .orange, .lightorange, .darkorange, .purple,
                                  .lightpurple, .darkpurple, .pink, .lightpink, .darkpink, .brown, .lightbrown, .darkbrown,
                                  .grey, .darkgrey, .lightgrey, .indigo, .lightindigo, .darkindigo, .teal, .lightteal,
                                  .darkteal, .cyan, .lightcyan, .darkcyan, .black, .white, .transparent, .custom("#123456")]
        for color in colors {
            element.foreground(color)
            element.background(color)
        }
        for opacity in [WebOpacity.opaque, .semiOpaque, .semiTransparent, .nearTransparent, .clear] { element.opacity(opacity) }
        for opacity in [0, 0.25, 0.5, 0.75, 1, 0.3] { element.opacity(opacity) }
        element.collapsible()
        for position in [WebPositionType.static, .relative, .absolute, .fixed, .sticky, .stickyBottom] { element.position(position) }
        let offsets: [WebPositionValue] = [.auto, .pixels(0), .pixels(10), .percent(0), .percent(50), .percent(100), .percent(30)]
        for offset in offsets {
            element.top(offset)
            element.bottom(offset)
            element.start(offset)
            element.end(offset)
        }
        for direction in [WebTranslateDirection.middle, .x, .y] { element.translate(direction) }
        element.hidden()
        element.visuallyHidden()
        for alignment in ["left", "right", "start", "end", "center", "justify"] {
            element.applyTextAlignment(alignment)
        }

        let unknown = Set(phase1BuilderClasses(element)).subtracting(allowed)
        #expect(unknown.isEmpty, "classes Bootstrap 5.3.8 does not define: \(unknown.sorted())")
    }
}

// MARK: - hidden

@Suite("Phase 1 builder: hidden()")
struct Phase1BuilderHiddenTests {

    @Test func hiddenWithoutArgumentsHides() {
        #expect(phase1BuilderClasses(WebElement().hidden()) == ["d-none"])
        #expect(phase1BuilderClasses(WebElement().hidden(true)) == ["d-none"])
        #expect(phase1BuilderClasses(WebElement().hidden(false)).isEmpty)
        let html = renderHTML { page in page.Text("gone").hidden() }
        #expect(html.contains("d-none"))
    }

    @Test func visuallyHiddenKeepsTheScreenReaderOnlyBehaviour() {
        #expect(phase1BuilderClasses(WebElement().visuallyHidden()) == ["visually-hidden"])
        #expect(phase1BuilderClasses(WebElement().visuallyHidden(false)).isEmpty)
    }

    @Test func boundHiddenRendersTheCurrentStateWithTheSameClass() {
        let box = Phase1BuilderBox()
        let html = renderHTML { page in
            let shown = page.WBool(false)
            let gone = page.WBool(true)
            let a = page.Text("bound shown").hidden(shown)
            let b = page.Text("bound hidden").hidden(gone)
            box.elements = [a, b]
            box.ids = [shown.builderId, gone.builderId]
        }
        let shownElement = box.elements[0]
        let goneElement = box.elements[1]
        #expect(phase1BuilderClasses(shownElement).contains("d-none") == false)
        #expect(phase1BuilderClasses(goneElement).contains("d-none"))
        for element in box.elements {
            #expect(phase1BuilderClasses(element).contains("visually-hidden") == false)
        }
        let script = phase1BuilderScripts(goneElement).joined(separator: "\n")
        #expect(script.contains("addCallback\(box.ids[1])(function (value, _meta)"))
        #expect(script.contains("classList.add(\"d-none\")"))
        #expect(script.contains("classList.remove(\"d-none\")"))
        #expect(script.contains("function updateVariable") == false)
        #expect(html.contains("visually-hidden") == false)
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func boundHiddenFollowsTheVariableAndCoexistsWithBoundDisabled() throws {
        // Run the element's hidden + disabled callbacks in one script (as a single end-of-body script would)
        // against a fake element, then drive both variables.
        let box = Phase1BuilderBox()
        _ = renderHTML { page in
            let hide = page.WBool(false)
            let disable = page.WBool(false)
            let button = page.Button("Go").hidden(hide).disabled(disable)
            box.elements = [button]
            box.ids = [hide.builderId, disable.builderId, button.builderId]
        }
        let button = box.elements[0]
        let (hideId, disableId, elementId) = (box.ids[0], box.ids[1], box.ids[2])
        let scripts = phase1BuilderScripts(button).joined(separator: "\n")
        let code = """
        var classes = {};
        var fake = {
            disabled: false,
            classList: { add: function (c) { classes[c] = true; }, remove: function (c) { delete classes[c]; } },
            setAttribute: function () {}, removeAttribute: function () {}
        };
        var registered = { hide: [], disable: [] };
        function addCallback\(hideId)(cb) { registered.hide.push(cb); }
        function addCallback\(disableId)(cb) { registered.disable.push(cb); }
        var \(elementId) = fake;
        \(scripts)
        function state() { return Object.keys(classes).sort().join(' ') + '|' + fake.disabled; }
        var out = [];
        registered.hide.forEach(function (cb) { cb(true, {}); });
        out.push(state());
        registered.disable.forEach(function (cb) { cb(true, {}); });
        out.push(state());
        registered.hide.forEach(function (cb) { cb(false, {}); });
        out.push(state());
        registered.disable.forEach(function (cb) { cb(false, {}); });
        out.push(state());
        process.stdout.write(JSON.stringify(out));
        """
        let output = try phase1BuilderRunNode(code)
        #expect(output == #"["d-none|false","d-none disabled|true","disabled|true","|false"]"#)
    }
}

// MARK: - hidden modifiers and the show/hide actions

/// Runs the compiled `actions` (targeting `#tgt`) against a fake element that starts with `classes`, and
/// returns whether the element is then hidden in any way: `hidden` or `visible`.
func phase1BuilderRunActions(_ actions: [WebAction], onElementWithClasses classes: [String]) throws -> String {
    let script = CompileActions(actions, builderId: "phase1Unused")
    let initial = String(decoding: try JSONSerialization.data(withJSONObject: classes), as: UTF8.self)
    let code = """
    var classes = new Set(\(initial));
    var element = {
        style: { display: '' },
        classList: {
            add: function () { for (var i = 0; i < arguments.length; i++) { classes.add(arguments[i]); } },
            remove: function () { for (var i = 0; i < arguments.length; i++) { classes.delete(arguments[i]); } },
            contains: function (c) { return classes.has(c); },
            toggle: function (c) { if (classes.has(c)) { classes.delete(c); } else { classes.add(c); } }
        },
        setAttribute: function () {}, removeAttribute: function () {}
    };
    var document = { getElementById: function (id) { return id === 'tgt' ? element : null; } };
    \(script)
    var hidden = classes.has('d-none') || classes.has('visually-hidden') || element.style.display === 'none';
    process.stdout.write(hidden ? 'hidden' : 'visible');
    """
    return try phase1BuilderRunNode(code)
}

@Suite("Phase 1 builder: hidden modifiers with the show/hide actions")
struct Phase1BuilderHiddenActionTests {

    /// The classes each hidden modifier leaves on an element: `.hidden()`, `.hidden(true)`, `.hidden(WBool(true))`.
    static func hiddenElements() -> [(String, [String])] {
        let box = Phase1BuilderBox()
        _ = renderHTML { page in
            box.elements = [page.Text("a").id("tgt").hidden(),
                            page.Text("b").id("tgt").hidden(true),
                            page.Text("c").id("tgt").hidden(page.WBool(true))]
        }
        return zip([".hidden()", ".hidden(true)", ".hidden(WBool(true))"], box.elements.map(phase1BuilderClasses))
            .map { ($0, $1) }
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func showActionRevealsEveryHiddenModifier() throws {
        for (name, classes) in Self.hiddenElements() {
            #expect(try phase1BuilderRunActions([], onElementWithClasses: classes) == "hidden", "\(name)")
            #expect(try phase1BuilderRunActions([.show(ref: "tgt")], onElementWithClasses: classes) == "visible", "\(name)")
            #expect(try phase1BuilderRunActions([.show(ref: "tgt"), .hide(ref: "tgt")], onElementWithClasses: classes) == "hidden", "\(name)")
        }
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func hiddenRefActionRevealsEveryHiddenModifier() throws {
        // `.hidden(ref:, false)` must undo every hidden modifier (they use `d-none`) and `.hide(ref:)`.
        let reveal = CompileActions([.hidden(ref: "tgt", false)], builderId: "phase1Unused")
        #expect(reveal.contains("d-none"))
        for (name, classes) in Self.hiddenElements() {
            #expect(try phase1BuilderRunActions([.hidden(ref: "tgt", false)], onElementWithClasses: classes) == "visible", "\(name)")
            #expect(try phase1BuilderRunActions([.hidden(ref: "tgt", true)], onElementWithClasses: classes) == "hidden", "\(name)")
        }
        #expect(try phase1BuilderRunActions([.hide(ref: "tgt"), .hidden(ref: "tgt", false)], onElementWithClasses: []) == "visible")
        #expect(try phase1BuilderRunActions([.hidden(ref: "tgt", false)], onElementWithClasses: ["visually-hidden"]) == "visible")
        // whichever class the action uses, hiding and un-hiding a visible element round-trips
        #expect(try phase1BuilderRunActions([.hidden(ref: "tgt", true)], onElementWithClasses: []) == "hidden")
        #expect(try phase1BuilderRunActions([.hidden(ref: "tgt", true), .hidden(ref: "tgt", false)], onElementWithClasses: []) == "visible")
    }
}
