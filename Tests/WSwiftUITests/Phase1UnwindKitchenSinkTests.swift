//
//  Phase1UnwindKitchenSinkTests.swift
//  WSwiftUITests
//
//  Unwind slice: a kitchen-sink page that builds every object in WebUI/objects, a normaliser that makes
//  its render comparable across runs (builderIds are random), and the golden comparison that proves the
//  builder-stack refactor (`withParent` everywhere) left valid pages byte-identical.
//
//  The golden data lives in Phase1UnwindKitchenSinkGoldenTests.swift, which is generated: after an intended
//  rendering change run `WSWIFTUI_UNWIND_UPDATE_GOLDEN=1 swift test --filter Phase1UnwindKitchenSinkTests`
//  and review the diff of that file.
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Kitchen sink

/// Builds every object of `Sources/WSwiftUI/WebUI/objects` (and every builder that takes content) once, in
/// valid nesting, inside the vertical and horizontal layout containers so both `WrapInLayoutContainer`
/// branches run. Used by the golden test, the duplicate-class test and the Bootstrap class check.
func phase1UnwindKitchenSink(_ p: CoreWebEndpoint) {
    p.head(.title("Kitchen sink"))

    let name = p.WString("Ada")
    let count = p.WInt(3)
    let flag = p.WBool(true)
    let ratio = p.WDouble(0.25)
    let choice = p.WString("b")
    let shown = p.WBool(false)

    p.NavBar(brand: "Brand", href: "/") {
        p.NavBarItem(title: "Home", href: "/", active: true)
        p.NavBarItem(title: "Off", href: "/off", disabled: true)
        p.NavDropdown(title: "More", id: "more") {
            p.NavDropdownHeader("Section")
            p.NavDropdownItem(title: "One", href: "/1")
            p.NavDropdownItem(title: "Two", href: "/2", disabled: true)
        }
    }
    p.Breadcrumb {
        p.BreadcrumbItem(title: "Home", url: "/")
        p.BreadcrumbItem(title: "Here", url: "/here", active: true)
    }
    p.Jumbotron(fluid: true) {
        p.JumbotronTitle("Title")
        p.JumbotronSubtitle("Subtitle")
    }
    p.Jumbotron(bgImageURL: "/hero.png") {
        p.Text("non-fluid jumbotron")
    }

    p.VStack(spacing: 8) {
        p.Text("plain text & <markup>")
        p.Text(name)
        p.Text("Hello $0, you have $1", name, count)
        p.Link("/somewhere", title: "A link", target: "_blank")
        p.Code(language: .swift, "let x = 1 < 2")
        p.Image("/img.png", alt: "picture").reloadImage(seconds: 5)
        p.Audio("/a.mp3")
        p.Badge("New", variant: .success, pill: true)
        p.Button("Press")
        p.Spacer()
        p.Spinner("Working")
        p.Spinner().size(.small)
        p.Spinner().type(.grow).size(.large)
        p.Toggle(value: flag)
    }
    p.HStack(alignment: .center, justify: .between, spacing: 16) {
        p.Text("in hstack")
        p.Link("/h", title: "h link")
        p.Code(language: .bash, "echo hi")
        p.Toggle("Flag", isOn: flag)
        p.Text(name)
        p.Text("$0!", name)
    }
    p.VStack(mode: .fit) {
        p.VStack { p.Text("nested vstack text") }
    }
    p.WrapInLayoutContainer {
        p.Text("wrapped")
    }
    p.Flex {
        p.Text("in flex")
    }.direction(.row)
    p.Callout(.info) {
        p.Text("callout")
    }
    p.Alert(.warning, dismissible: true) {
        p.Text("alert body")
    }
    p.Alert(.secondary) {
        p.Text("plain alert")
    }
    p.Alert("Heads up", isPresented: shown, variant: .danger, message: "message", dismissible: true)

    p.Card {
        p.CardImageTop(src: "/top.png", alt: "top")
        p.CardHeader { p.Text("header") }
        p.CardBody { p.Text("body") }
        p.CardFooter { p.Text("footer") }
        p.CardImageBottom(src: "/bottom.png")
    }
    p.Accordion {
        p.AccordionItem(title: "First") { p.Text("one") }
        p.AccordionItem(title: "Second") { p.Text("two") }
    }.expandFirst(true)
    p.Accordion {
        p.AccordionItem(title: "Third") { p.Text("three") }
        p.VStack { p.AccordionItem(title: "Fourth") { p.Text("four") } }
    }.alwaysOpen(true).expandItem(at: 1)
    p.Carousel(id: "car") {
        p.CarouselIndicators(id: "car", count: 2)
        p.CarouselInner {
            p.CarouselItem(active: true) { p.Image("/1.png") }
            p.CarouselItem(interval: 2000) { p.Image("/2.png") }
        }
        p.CarouselControlPrev(id: "car")
        p.CarouselControlNext(id: "car")
    }
    p.Chart(id: "chart1", type: .line, labels: ["a", "b"], dataSets: [ChartDataSet(label: "s", values: [1, 2])])
    p.ListGroup {
        p.ListGroupItem("one", variant: .info, active: true)
        p.ListGroupItem("two", disabled: true)
    }
    p.Pagination(size: .small, alignment: .center) {
        p.PaginationItem(page: 1, href: "/p/1", active: true)
        p.PaginationItem(page: 2, href: "/p/2")
        p.PaginationItem(page: 3, disabled: true)
    }
    p.Progress {
        p.ProgressBar(value: 40)
        p.ProgressBar(count, max: 10, variant: .success, striped: true, animated: true)
        p.ProgressBar(ratio, max: 1.0)
    }
    p.Table {
        p.TableHeader { p.Row { p.Cell { p.Text("H") } } }
        p.TableBody { p.Row { p.Cell { p.Text("B") }.colspan(2) } }
    }
    p.Form(action: "/submit") {
        p.TextField("Name", text: name, prompt: "your name")
        p.SecureField("Password", text: p.WString("").name("pw"))
        p.TextArea("Notes", text: p.WString("n").name("notes"))
        p.TextField(binding: p.WString("x").name("email"), type: .email).validate([.notEmpty, .validEmail])
        p.Picker("Pick", selection: choice) {
            p.Text("A").value("a")
            p.Text("B").value("b")
        }
        p.Picker("Segments", selection: choice, style: .segmented(.primary)) {
            p.Text("A").value("a")
            p.Text("B").value("b")
        }
        p.Picker("Radio", selection: choice, style: .radio(.horizontal)) {
            p.Text("A").value("a")
            p.Text("B").value("b")
        }
        p.Toggle("Agree", isOn: p.WBool(false).name("agree"))
        p.Button("Send", type: "submit")
    }
    p.FileUploader(action: "/upload", extraFields: ["token": "t"], onUpload: [.navigate("/done")]) {
        p.Text("Drop files here")
    }
    p.Modal(id: "m1") {
        p.ModalDialog {
            p.ModalContent {
                p.ModalHeader { p.ModalTitle { p.Text("Modal title") } }
                p.ModalBody { p.Text("modal body") }
                p.ModalFooter { p.Button("Close") }
            }
        }
    }
    p.Modal(id: "m2", isPresented: shown) {
        p.ModalDialog { p.ModalContent { p.ModalBody { p.Text("bound modal") } } }
    }
    p.Sheet(isPresented: shown, id: "sheet1") {
        p.ModalDialog { p.ModalContent { p.ModalBody { p.Text("sheet") } } }
    }
    p.OffCanvas(id: "oc", placement: .end) {
        p.OffCanvasHeader { p.OffCanvasTitle { p.Text("Panel") } }
        p.OffCanvasBody { p.Text("panel body") }
        p.OffCanvasFooter { p.Button("Done") }
    }
    p.OffCanvas(id: "oc2", isPresented: shown) {
        p.OffCanvasBody { p.Text("bound panel") }
    }
    p.WebSocket(url: "/ws", onRecieve: [.script("console.log(result);")])
    p.Footer {
        p.Text("footer text")
    }.sticky()
}

// MARK: - Normalising a render

enum Phase1UnwindNormalizer {

    /// Every element reachable from `root` (sub-elements and picker items), depth first.
    static func elements(under root: WebElement) -> [WebElement] {
        var found: [WebElement] = []
        func visit(_ element: WebElement) {
            found.append(element)
            for attribute in element.attributes {
                if case .item(let item) = attribute { visit(item) }
            }
            for child in element.subElements { visit(child) }
        }
        visit(root)
        return found
    }

    /// Every builderId of the page's elements with the token that replaces it, `B0001`, `B0002`, ..., in
    /// element-tree order (depth first from the document root, which itself is left out). The numbering
    /// depends only on the tree the DSL built, not on where, or whether, the renderer writes an id.
    static func idTokens(for page: CoreWebEndpoint) -> [(id: String, token: String)] {
        var seen: Set<String> = []
        var tokens: [(id: String, token: String)] = []
        for element in elements(under: page.documentRoot).dropFirst() where seen.insert(element.builderId).inserted {
            tokens.append((element.builderId, "B" + padded(String(tokens.count + 1), to: 4)))
        }
        return tokens
    }

    /// `text` with every builderId in `ids` replaced by its token (longest id first, so an id that is part
    /// of a longer one can't change it), and the random suffix of the baseline's accordion item ids
    /// replaced by `XXXXXXXX`.
    static func normalized(_ text: String, ids: [(id: String, token: String)]) -> String {
        var text = text
        for (id, token) in ids.sorted(by: { $0.id.count > $1.id.count }) {
            text = text.replacingOccurrences(of: id, with: token)
        }
        let random = try! NSRegularExpression(pattern: "-item-[0-9A-F]{8}\\b")
        return random.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                               withTemplate: "-item-XXXXXXXX")
    }

    /// `html` normalised with the ids of `page`'s elements.
    static func normalized(_ html: String, page: CoreWebEndpoint) -> String {
        return normalized(html, ids: idTokens(for: page))
    }

    /// The markup between the page's `<body ...>` start tag and its `</body>`, with every inline `<script>`
    /// element (and the line it is on) left out.
    ///
    /// Most inline scripts are written by the renderer and the variable runtime (each element's
    /// registration script, a variable's runtime, the DOMContentLoaded block), which other parts of the
    /// framework own and change; leaving them out keeps this a check of the markup WebUI/objects build.
    /// The scripts WebUI/objects attach to elements are checked on their own (`objectScripts`).
    static func bodyMarkup(_ html: String) -> String {
        guard let bodyTag = html.range(of: "<body"),
              let startTagEnd = html.range(of: ">\n", range: bodyTag.upperBound..<html.endIndex),
              let bodyEnd = html.range(of: "</body>", options: .backwards),
              startTagEnd.upperBound <= bodyEnd.lowerBound else {
            return html
        }
        var inner = String(html[startTagEnd.upperBound..<bodyEnd.lowerBound])
        while let last = inner.last, last == " " || last == "\t" {
            inner.removeLast()   // the indent of the </body> line
        }
        let scripts = try! NSRegularExpression(pattern: "(?m)^[ \\t]*<script>[\\s\\S]*?</script>[ \\t]*\\n")
        return scripts.stringByReplacingMatches(in: inner, range: NSRange(location: 0, length: (inner as NSString).length),
                                                withTemplate: "")
    }

    /// The scripts WebUI/objects attach to the page's rendered elements (`.script` and `.domLoadedScript`
    /// attributes), in element-tree order. Each line names the element (its token and type), the kind of
    /// script and the UTF-8 length and FNV-1a of the normalised script; `script` is the normalised script
    /// itself. A variable's own scripts are the variable runtime (WebVariable.swift), so variables are left
    /// out.
    static func objectScripts(of page: CoreWebEndpoint, ids: [(id: String, token: String)]) -> [(line: String, script: String)] {
        let tokens = Dictionary(ids.map { ($0.id, $0.token) }, uniquingKeysWith: { first, _ in first })
        var found: [(line: String, script: String)] = []
        func visit(_ element: WebElement) {
            if (element is WebVariableElement) == false {
                for attribute in element.attributes {
                    let kind: String
                    let script: String
                    switch attribute {
                    case .script(let js): (kind, script) = ("script", js)
                    case .domLoadedScript(let js): (kind, script) = ("domLoadedScript", js)
                    default: continue
                    }
                    let body = normalized(script, ids: ids)
                    let owner = tokens[element.builderId] ?? "root"
                    found.append(("\(owner) \(type(of: element)) \(kind) \(body.utf8.count) bytes, fnv1a \(fnv1a(body))", body))
                }
            }
            element.subElements.forEach(visit)
        }
        visit(page.documentRoot)
        return found
    }

    /// FNV-1a (64-bit) of the UTF-8 bytes, as 16 hex digits.
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return padded(String(hash, radix: 16), to: 16)
    }

    /// `text` left-padded with zeros to `width` characters.
    static func padded(_ text: String, to width: Int) -> String {
        return String(repeating: "0", count: Swift.max(0, width - text.count)) + text
    }
}

/// Captures the page out of the (synchronously executed) `renderHTML` closure.
final class Phase1UnwindBox: @unchecked Sendable {
    var page: CoreWebEndpoint? = nil
    var elements: [WebElement] = []
}

/// A rendered page in the forms the kitchen-sink tests compare.
struct Phase1UnwindRendering {
    /// The page as served.
    var raw: String
    /// `raw` with every builderId replaced by its token.
    var normalized: String
    /// The normalised `<body>` markup without inline scripts (`Phase1UnwindNormalizer.bodyMarkup`).
    var bodyMarkup: String
    /// The scripts WebUI/objects attached to the page's elements (`Phase1UnwindNormalizer.objectScripts`).
    var objectScripts: [(line: String, script: String)]
}

/// Renders `build` and returns the page in the forms the kitchen-sink tests compare.
///
/// Today a builderId is the first 12 characters of a UUID with digits trimmed from both ends, so about one
/// id in 1600 is shorter (even two characters), and a short random id can't be told apart from other text.
/// While the ids are of that kind (nearly all 12 characters), the page is rendered again, with new ids,
/// until every id has 12 characters. Ids of any other scheme are used as they are.
func phase1UnwindRender(_ build: @escaping (CoreWebEndpoint) -> Void) -> Phase1UnwindRendering {
    var last = Phase1UnwindRendering(raw: "", normalized: "", bodyMarkup: "", objectScripts: [])
    for _ in 0..<50 {
        let box = Phase1UnwindBox()
        let html = renderHTML { page in
            box.page = page
            build(page)
        }
        guard let page = box.page else {
            return Phase1UnwindRendering(raw: html, normalized: html, bodyMarkup: html, objectScripts: [])
        }
        let ids = Phase1UnwindNormalizer.idTokens(for: page)
        let normalized = Phase1UnwindNormalizer.normalized(html, ids: ids)
        last = Phase1UnwindRendering(raw: html, normalized: normalized,
                                     bodyMarkup: Phase1UnwindNormalizer.bodyMarkup(normalized),
                                     objectScripts: Phase1UnwindNormalizer.objectScripts(of: page, ids: ids))
        let lengths = Phase1UnwindNormalizer.elements(under: page.documentRoot).dropFirst().map(\.builderId.count)
        let twelve = lengths.filter { $0 == 12 }.count
        if twelve == lengths.count || twelve * 10 < lengths.count * 9 {
            return last
        }
    }
    return last
}

/// Writes the golden file (Phase1UnwindKitchenSinkGoldenTests.swift) from a rendering of the kitchen sink.
enum Phase1UnwindGoldenFile {

    /// The golden file next to this source file.
    static var url: URL {
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Phase1UnwindKitchenSinkGoldenTests.swift")
    }

    /// The object-script lines as the golden stores them.
    static func scriptLines(_ rendering: Phase1UnwindRendering) -> String {
        return rendering.objectScripts.map(\.line).joined(separator: "\n")
    }

    /// The Swift source of the golden file for `rendering`.
    static func source(for rendering: Phase1UnwindRendering) -> String {
        return """
        //
        //  Phase1UnwindKitchenSinkGoldenTests.swift
        //  WSwiftUITests
        //
        //  GENERATED by Phase1UnwindKitchenSinkTests.regenerateTheGoldenWhenAsked: data only, no tests, do not
        //  edit by hand. After an intended rendering change, regenerate it with
        //
        //      WSWIFTUI_UNWIND_UPDATE_GOLDEN=1 swift test --filter Phase1UnwindKitchenSinkTests
        //
        //  and review the diff of this file: only the intended change may appear.
        //

        /// The kitchen sink's `<body>` markup, normalised (builderIds as B0001... in element-tree order), without
        /// its inline `<script>` elements.
        let phase1UnwindKitchenSinkGolden = \(rawLiteral(rendering.bodyMarkup))

        /// The scripts WebUI/objects attach to the kitchen sink's elements, in element-tree order: element,
        /// type, kind, and the UTF-8 length and FNV-1a of the normalised script.
        let phase1UnwindKitchenSinkObjectScriptsGolden = \(rawLiteral(scriptLines(rendering)))

        """
    }

    /// `text` as a multi-line raw string literal whose value is exactly `text`: enough `#`s that nothing in
    /// it can end the literal or start an escape, and the closing delimiter in the first column so no
    /// indentation is stripped.
    static func rawLiteral(_ text: String) -> String {
        var hashes = "#"
        while text.contains("\"\"\"" + hashes) || text.contains("\\" + hashes) {
            hashes += "#"
        }
        return hashes + "\"\"\"\n" + text + "\n\"\"\"" + hashes
    }
}

/// Class tokens of the kitchen sink that Bootstrap 5.3.8 defines (each checked against its
/// dist/css/bootstrap.css when this list was written). Hand-maintained: a class added to the kitchen sink
/// goes here only after checking that bootstrap.css 5.3.8 defines it.
let phase1UnwindBootstrapClasses: Set<String> = [
    "accordion", "accordion-body", "accordion-button", "accordion-collapse", "accordion-header", "accordion-item",
    "active", "alert", "alert-danger", "alert-dismissible", "alert-secondary", "alert-warning",
    "align-items-center", "align-items-stretch", "badge", "bg-light", "bg-success", "border", "border-top",
    "breadcrumb", "breadcrumb-item", "btn", "btn-close", "btn-group", "btn-outline-primary", "card", "card-body",
    "card-footer", "card-header", "card-img-bottom", "card-img-top", "carousel", "carousel-control-next",
    "carousel-control-next-icon", "carousel-control-prev", "carousel-control-prev-icon", "carousel-indicators",
    "carousel-inner", "carousel-item", "col", "col-md-auto", "collapse", "collapsed", "container",
    "container-fluid", "d-flex", "d-none", "disabled", "display-4", "dropdown", "dropdown-header", "dropdown-item",
    "dropdown-menu", "dropdown-toggle", "fade", "fixed-bottom", "flex-column", "flex-grow-1", "flex-row",
    "flex-shrink-0", "form-check", "form-check-inline", "form-check-input", "form-check-label", "form-control",
    "form-select", "fw-bold", "fw-light", "g-3", "gap-2", "justify-content-between", "justify-content-center", "lead",
    "list-group", "list-group-item", "list-group-item-info", "mb-2", "mb-4", "mb-lg-0", "modal", "modal-body",
    "modal-content", "modal-dialog", "modal-footer", "modal-header", "modal-title", "ms-auto", "mt-2", "mt-auto",
    "nav-item", "nav-link", "navbar", "navbar-brand", "navbar-collapse", "navbar-expand-lg", "navbar-nav",
    "navbar-toggler", "navbar-toggler-icon", "offcanvas", "offcanvas-body", "offcanvas-end", "offcanvas-header",
    "offcanvas-start", "offcanvas-title", "p-3", "p-5", "page-item", "page-link", "pagination", "pagination-sm",
    "progress", "progress-bar", "progress-bar-animated", "progress-bar-striped", "py-3", "rounded", "rounded-3",
    "rounded-pill", "row", "show", "spinner-border", "spinner-border-sm", "spinner-grow", "table", "text-danger",
    "visually-hidden",
]

/// Records the first line where `actual` and `golden` differ (the full strings are compared afterwards).
func phase1UnwindExpectSameLines(_ actual: String, _ golden: String, _ label: String,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
    let expectedLines = golden.components(separatedBy: "\n")
    let actualLines = actual.components(separatedBy: "\n")
    if let first = zip(expectedLines, actualLines).enumerated().first(where: { $0.element.0 != $0.element.1 }) {
        Issue.record("\(label): first difference at line \(first.offset + 1):\n  golden: \(first.element.0)\n  actual: \(first.element.1)",
                     sourceLocation: sourceLocation)
    }
    #expect(actualLines.count == expectedLines.count, "\(label): line count", sourceLocation: sourceLocation)
}

// MARK: - Tests

@Suite("Phase 1 unwind: kitchen sink renders as before")
struct Phase1UnwindKitchenSinkTests {

    @Test func normalisedRenderIsDeterministic() {
        // the normaliser removes every source of randomness (builderIds are random today), so two renders
        // compare equal
        let first = phase1UnwindRender(phase1UnwindKitchenSink)
        let second = phase1UnwindRender(phase1UnwindKitchenSink)
        #expect(first.normalized == second.normalized)
        #expect(first.bodyMarkup == second.bodyMarkup)
        #expect(first.objectScripts.map(\.line) == second.objectScripts.map(\.line))
        #expect(first.normalized.contains("data-wsui-misuse") == false, "the kitchen sink is a valid page")
    }

    @Test func noElementHasADuplicateClassToken() {
        // populateCreatedObject already adds the builderId class; Image, Link, Audio, Spinner, Toggle, Text
        // (bound and formatted) and Accordion added it a second time, and Card added `card` twice.
        let render = phase1UnwindRender(phase1UnwindKitchenSink)
        let regex = try! NSRegularExpression(pattern: "<[A-Za-z0-9]+ [^>]*class=\"([^\"]*)\"")
        let ns = render.normalized as NSString
        var duplicates: [String] = []
        var checked = 0
        for match in regex.matches(in: render.normalized, range: NSRange(location: 0, length: ns.length)) {
            let tokens = ns.substring(with: match.range(at: 1)).split(separator: " ").map(String.init)
            checked += 1
            if Set(tokens).count != tokens.count {
                duplicates.append(ns.substring(with: match.range))
            }
        }
        #expect(checked > 200)
        #expect(duplicates.isEmpty, "\(duplicates)")
    }

    @Test func everyClassIsBootstrapsOrAFrameworkHook() {
        // Every class token in the kitchen sink is a builderId, a wsui-* hook, a class Bootstrap 5.3.8
        // defines (phase1UnwindBootstrapClasses, checked against bootstrap.css when it was written), or one
        // of the framework's own hooks below.
        let hooks: Set<String> = [
            "text",            // Text(String) / Text(format): the framework's marker class, unstyled
            "file-uploader",   // FileUploader: the drop-blocker script looks for it
            "hidden-input",    // a variable's hidden carrier input (WebVariable.swift)
            "slide",           // Carousel: Bootstrap's carousel.js checks it to animate (no CSS rule)
            "language-swift", "language-bash", // Code: Prism.js language hooks
        ]
        let render = phase1UnwindRender(phase1UnwindKitchenSink)
        let regex = try! NSRegularExpression(pattern: "class\\s*=\\s*\"([^\"]*)\"")
        let ns = render.normalized as NSString
        var unknown: Set<String> = []
        var allTokens: Set<String> = []
        for match in regex.matches(in: render.normalized, range: NSRange(location: 0, length: ns.length)) {
            for token in ns.substring(with: match.range(at: 1)).split(separator: " ").map(String.init) {
                allTokens.insert(token)
                let builderId = token.range(of: "^B[0-9]{4}$", options: .regularExpression) != nil
                if builderId || token.hasPrefix("wsui-") || hooks.contains(token) || phase1UnwindBootstrapClasses.contains(token) {
                    continue
                }
                unknown.insert(token)
            }
        }
        #expect(unknown.isEmpty, "\(unknown.sorted())")
        // and the classes this slice removed because Bootstrap 5.3.8 doesn't define them stay gone
        for gone in ["offcanvas-footer", "spinner-border-lg", "jumbotron", "btn-group-toggle", "breadcrumb-container", "navbar-light"] {
            #expect(phase1UnwindBootstrapClasses.contains(gone) == false)
            #expect(allTokens.contains(gone) == false, "\(gone)")
        }
        #expect(allTokens.count > 100)
    }

    @Test func normalisedMarkupMatchesTheGolden() {
        // The golden was first taken from the baseline's render of the kitchen sink (9aca932 + Phase 1
        // wave 1) with only the intended changes of the unwind slice applied:
        //  - no duplicate class tokens (Image, Link, Audio, Spinner, Toggle, Text binding/format, Accordion,
        //    Card's second `card`);
        //  - Accordion item ids `<accordion>-item-<item builderId>` instead of a random suffix, and
        //    expandFirst/expandItem rendered as Bootstrap's open-item markup instead of a `show` script;
        //  - OffCanvasFooter classes, the close button's type, the title id behind aria-labelledby (and
        //    no aria-labelledby without a title);
        //  - the FileUploader progress bar inside its track; a disabled ListGroupItem's `disabled` class;
        //    Spinner size/type classes; no `jumbotron`, `breadcrumb-container`, `btn-group-toggle` or
        //    `navbar-light`; sorted JSON keys in the chart data (the baseline's order was random).
        // Everything else, including every builder converted to withParent, renders byte for byte as
        // before. Only the <body> markup is compared here, without its inline scripts (the renderer and
        // the variable runtime write most of them); the scripts WebUI/objects attach to elements are
        // compared by objectScriptsMatchTheGolden.
        //
        // After an intended rendering change, regenerate the golden file with
        // `WSWIFTUI_UNWIND_UPDATE_GOLDEN=1 swift test --filter Phase1UnwindKitchenSinkTests` and review its diff.
        let render = phase1UnwindRender(phase1UnwindKitchenSink)
        phase1UnwindExpectSameLines(render.bodyMarkup, phase1UnwindKitchenSinkGolden, "body markup")
        #expect(render.bodyMarkup == phase1UnwindKitchenSinkGolden)
        // Chart asks for Chart.js in the head
        #expect(render.normalized.components(separatedBy: "</head>").first?.contains("chart.umd.min.js\"") == true)
    }

    @Test func objectScriptsMatchTheGolden() {
        // The scripts the objects attach to elements (bound Text, Toggle, Picker, Progress and form
        // controls, Image reload, Chart, FileUploader, bound Alert/Modal/OffCanvas, Form validation,
        // WebSocket), by length and FNV-1a of the normalised script. They embed the variable runtime's
        // function names and compiled actions, so a change there shows up here too: regenerate as above.
        let render = phase1UnwindRender(phase1UnwindKitchenSink)
        let actual = Phase1UnwindGoldenFile.scriptLines(render)
        let golden = phase1UnwindKitchenSinkObjectScriptsGolden.components(separatedBy: "\n")
        for (index, entry) in render.objectScripts.enumerated() where index >= golden.count || golden[index] != entry.line {
            Issue.record("object script \(index + 1) differs:\n  golden: \(index < golden.count ? golden[index] : "(none)")\n  actual: \(entry.line)\n\(entry.script)")
            break
        }
        #expect(actual == phase1UnwindKitchenSinkObjectScriptsGolden)
        #expect(render.objectScripts.count > 20)
    }

    @Test func comparedMarkupDoesNotDependOnInlineScripts() {
        // Rewriting every inline script (registration scripts, the variable runtime, the DOMContentLoaded
        // block: the renderer's and the variables' code) leaves the compared markup exactly as it was, so a
        // change there can't break normalisedMarkupMatchesTheGolden.
        let render = phase1UnwindRender(phase1UnwindKitchenSink)
        let scripts = try! NSRegularExpression(pattern: "<script>[\\s\\S]*?</script>")
        let html = render.normalized
        let rewritten = scripts.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length),
                                                         withTemplate: "<script>\nvar rewritten = 1;\n</script>")
        #expect(rewritten != html)
        #expect(Phase1UnwindNormalizer.bodyMarkup(rewritten) == render.bodyMarkup)
        #expect(render.bodyMarkup.contains("<script") == false)
        #expect(render.bodyMarkup.contains("wsui-offcanvas-footer"))
    }

    @Test func goldenLiteralsSurviveAnyContent() {
        // the generator picks enough #s for any content, so a regenerated golden file always compiles to
        // exactly the rendered text
        #expect(Phase1UnwindGoldenFile.rawLiteral("a") == "#\"\"\"\na\n\"\"\"#")
        #expect(Phase1UnwindGoldenFile.rawLiteral("x \"\"\"# y").hasPrefix("##\"\"\"\n"))
        #expect(Phase1UnwindGoldenFile.rawLiteral("x \\# y").hasSuffix("\n\"\"\"##"))
        #expect(Phase1UnwindGoldenFile.rawLiteral("x \\## \"\"\"# y").hasPrefix("###\"\"\"\n"))
    }

    @Test func regenerateTheGoldenWhenAsked() throws {
        // WSWIFTUI_UNWIND_UPDATE_GOLDEN=1 rewrites Phase1UnwindKitchenSinkGoldenTests.swift from this tree's
        // render. The comparisons in the same run still use the compiled (old) golden; run again to check.
        guard ProcessInfo.processInfo.environment["WSWIFTUI_UNWIND_UPDATE_GOLDEN"] == "1" else { return }
        let render = phase1UnwindRender(phase1UnwindKitchenSink)
        try Phase1UnwindGoldenFile.source(for: render)
            .write(to: Phase1UnwindGoldenFile.url, atomically: true, encoding: .utf8)
    }

    @Test func dumpForEvidence() throws {
        // Writes the kitchen sink when WSWIFTUI_UNWIND_DUMP names a directory: as served, normalised, the
        // body markup the golden compares, and the object scripts in full.
        guard let dir = ProcessInfo.processInfo.environment["WSWIFTUI_UNWIND_DUMP"], dir.isEmpty == false else { return }
        let render = phase1UnwindRender(phase1UnwindKitchenSink)
        try render.raw.write(toFile: dir + "/kitchen-sink.raw.html", atomically: true, encoding: .utf8)
        try render.normalized.write(toFile: dir + "/kitchen-sink.html", atomically: true, encoding: .utf8)
        try render.bodyMarkup.write(toFile: dir + "/kitchen-sink.body.html", atomically: true, encoding: .utf8)
        try render.objectScripts.map { "// \($0.line)\n\($0.script)\n" }.joined(separator: "\n")
            .write(toFile: dir + "/kitchen-sink.object-scripts.js", atomically: true, encoding: .utf8)
    }
}
