//
//  Phase1BuilderMisuseTests.swift
//  WSwiftUITests
//
//  Builder slice: misplaced compound-control parts are reported (log line + HTML comment) instead of
//  terminating the process, and parts are found through wrapper elements (nearest structural ancestor).
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Helpers (builder slice)

/// The marker `misuse(_:)` leaves in the page.
func phase1BuilderMisuseMarker(_ message: String) -> String {
    return "<template data-wsui-misuse><!-- WSwiftUI: \(message) --></template>"
}

/// The rendered subtree that starts at the first line containing `marker`: that line plus every following
/// line indented deeper than it, plus its closing line. Relies on the renderer's one-element-per-line,
/// indent-per-level output.
func phase1BuilderSubtree(containing marker: String, in html: String) -> String? {
    let lines = html.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
    func indent(_ line: String) -> Int { line.prefix(while: { $0 == " " }).count }
    let base = indent(lines[start])
    var out = [lines[start]]
    var index = start + 1
    while index < lines.count {
        let line = lines[index]
        if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
        if indent(line) <= base {
            if indent(line) == base, line.trimmingCharacters(in: .whitespaces).hasPrefix("</") { out.append(line) }
            break
        }
        out.append(line)
        index += 1
    }
    return out.joined(separator: "\n")
}

/// A misplaced part of a compound control, and what must appear in the page instead of a crash.
struct Phase1BuilderMisuseCase: Sendable, CustomTestStringConvertible {
    let name: String
    /// The message `misuse(_:)` reports.
    let message: String
    /// The file (`#fileID`) whose guard reports it.
    let file: String
    /// Text on the misplaced element's own line, proving it was still rendered.
    let rendered: String
    let build: @Sendable (CoreWebEndpoint) -> Void
    var testDescription: String { name }
}

/// One case per former `fatalError` guard (28).
let phase1BuilderMisuseCases: [Phase1BuilderMisuseCase] = [
    // Carousel (5)
    .init(name: "CarouselInner outside Carousel", message: "CarouselInner must be inside Carousel { ... } block",
          file: "WSwiftUI/Carousel.swift", rendered: "carousel-inner") { page in page.CarouselInner {} },
    .init(name: "CarouselItem outside CarouselInner", message: "CarouselItem must be inside CarouselInner { ... } block",
          file: "WSwiftUI/Carousel.swift", rendered: "carousel-item") { page in page.Carousel(id: "c1") { page.CarouselItem {} } },
    .init(name: "CarouselIndicators outside Carousel", message: "CarouselIndicators must be inside Carousel { ... } block",
          file: "WSwiftUI/Carousel.swift", rendered: "carousel-indicators") { page in page.CarouselIndicators(id: "c1", count: 2) },
    .init(name: "CarouselControlPrev outside Carousel", message: "CarouselControlPrev must be inside Carousel { ... } block",
          file: "WSwiftUI/Carousel.swift", rendered: "carousel-control-prev") { page in page.CarouselControlPrev(id: "c1") },
    .init(name: "CarouselControlNext outside Carousel", message: "CarouselControlNext must be inside Carousel { ... } block",
          file: "WSwiftUI/Carousel.swift", rendered: "carousel-control-next") { page in page.CarouselControlNext(id: "c1") },
    // Modal (6)
    .init(name: "ModalDialog outside Modal", message: "ModalDialog must be inside Modal { ... }",
          file: "WSwiftUI/Modal.swift", rendered: "modal-dialog") { page in page.ModalDialog {} },
    .init(name: "ModalContent outside ModalDialog", message: "ModalContent must be inside ModalDialog { ... }",
          file: "WSwiftUI/Modal.swift", rendered: "modal-content") { page in page.Modal(id: "m1") { page.ModalContent {} } },
    .init(name: "ModalHeader outside ModalContent", message: "ModalHeader must be inside ModalContent { ... }",
          file: "WSwiftUI/Modal.swift", rendered: "modal-header") { page in page.ModalHeader {} },
    .init(name: "ModalTitle outside ModalHeader", message: "ModalTitle must be inside ModalHeader { ... }",
          file: "WSwiftUI/Modal.swift", rendered: "modal-title") { page in page.ModalTitle {} },
    .init(name: "ModalBody outside ModalContent", message: "ModalBody must be inside ModalContent { ... }",
          file: "WSwiftUI/Modal.swift", rendered: "modal-body") { page in page.ModalBody {} },
    .init(name: "ModalFooter outside ModalContent", message: "ModalFooter must be inside ModalContent { ... }",
          file: "WSwiftUI/Modal.swift", rendered: "modal-footer") { page in page.ModalFooter {} },
    // Card (3)
    .init(name: "CardHeader outside Card", message: "CardHeader must be used inside a Card { ... } block",
          file: "WSwiftUI/Card.swift", rendered: "card-header") { page in page.CardHeader {} },
    .init(name: "CardBody outside Card", message: "CardBody must be used inside a Card { ... } block",
          file: "WSwiftUI/Card.swift", rendered: "card-body") { page in page.CardBody {} },
    .init(name: "CardFooter outside Card", message: "CardFooter must be used inside a Card { ... } block",
          file: "WSwiftUI/Card.swift", rendered: "card-footer") { page in page.CardFooter {} },
    // Progress (3)
    .init(name: "ProgressBar(value:) outside Progress", message: "ProgressBar must be used inside Progress { ... } block",
          file: "WSwiftUI/Progress.swift", rendered: "progress-bar") { page in page.ProgressBar(value: 40) },
    .init(name: "ProgressBar(Int variable) outside Progress", message: "Bound ProgressBar must be inside Progress { ... } block",
          file: "WSwiftUI/Progress.swift", rendered: "progress-bar") { page in page.ProgressBar(page.WInt(40), max: 100) },
    .init(name: "ProgressBar(Double variable) outside Progress", message: "Bound ProgressBar must be inside Progress { ... } block",
          file: "WSwiftUI/Progress.swift", rendered: "progress-bar") { page in page.ProgressBar(page.WDouble(0.4), max: 1.0) },
    // Table (4)
    .init(name: "TableHeader outside Table", message: "TableHeader must be used inside a Table { ... } block",
          file: "WSwiftUI/Table.swift", rendered: "<thead") { page in page.TableHeader {} },
    .init(name: "TableBody outside Table", message: "TableBody must be used inside a Table { ... } block",
          file: "WSwiftUI/Table.swift", rendered: "<tbody") { page in page.TableBody {} },
    .init(name: "Row directly in Table", message: "Row must be used inside a TableHeader or TableBody block",
          file: "WSwiftUI/Table.swift", rendered: "<tr") { page in page.Table { page.Row {} } },
    .init(name: "Cell directly in TableBody", message: "Cell must be used inside a Row { ... } block",
          file: "WSwiftUI/Table.swift", rendered: "<td") { page in page.Table { page.TableBody { page.Cell {} } } },
    // Pagination, Accordion, ListGroup (3)
    .init(name: "PaginationItem outside Pagination", message: "PaginationItem must be inside Pagination { ... } block",
          file: "WSwiftUI/Pagination.swift", rendered: "page-item") { page in page.PaginationItem(page: 1, href: "/p/1") },
    .init(name: "AccordionItem outside Accordion", message: "AccordionItem must be called within an Accordion { ... } block",
          file: "WSwiftUI/Accordion.swift", rendered: "accordion-item") { page in page.AccordionItem(title: "Orphan") {} },
    .init(name: "ListGroupItem outside ListGroup", message: "ListGroupItem must be inside ListGroup { ... } block",
          file: "WSwiftUI/ListGroup.swift", rendered: "list-group-item") { page in page.ListGroupItem("Orphan") },
    // OffCanvas (4)
    .init(name: "OffCanvasHeader outside OffCanvas", message: "OffCanvasHeader must be inside OffCanvas { ... }",
          file: "WSwiftUI/OffCanvas.swift", rendered: "offcanvas-header") { page in page.OffCanvasHeader {} },
    .init(name: "OffCanvasTitle outside OffCanvasHeader", message: "OffCanvasTitle must be inside OffCanvasHeader { ... }",
          file: "WSwiftUI/OffCanvas.swift", rendered: "offcanvas-title") { page in page.OffCanvas(id: "o1") { page.OffCanvasTitle {} } },
    .init(name: "OffCanvasBody outside OffCanvas", message: "OffCanvasBody must be inside OffCanvas { ... }",
          file: "WSwiftUI/OffCanvas.swift", rendered: "offcanvas-body") { page in page.OffCanvasBody {} },
    .init(name: "OffCanvasFooter outside OffCanvas", message: "OffCanvasFooter must be inside OffCanvas { ... }",
          file: "WSwiftUI/OffCanvas.swift", rendered: " wsui-offcanvas-footer mt-auto flex-shrink-0 p-3 border-top\"") { page in page.OffCanvasFooter {} },
]

/// Something other than a table part declared directly in a Table, TableHeader, TableBody or Row, which
/// browsers move out of the table (a Form or VStack wrapped around rows or cells, a Text in a Row, ...).
struct Phase1BuilderTableContentCase: Sendable, CustomTestStringConvertible {
    let name: String
    /// The offending element's tag name.
    let element: String
    /// The table container it was declared in.
    let container: String
    /// Text inside it, proving it (and what it wraps) was still rendered.
    let content: String
    let build: @Sendable (CoreWebEndpoint) -> Void
    var message: String { tableContentMessage(element: element, container: container) }
    var testDescription: String { name }
}

let phase1BuilderTableContentCases: [Phase1BuilderTableContentCase] = [
    .init(name: "Form around a Row in a TableBody", element: "form", container: "TableBody", content: "per-row form") { page in
        page.Table { page.TableBody { page.Form(action: "/rows/1") {
            page.Row { page.Cell { page.Text("per-row form") }; page.Cell { page.Button("Save", type: "submit") } }
        } } }
    },
    .init(name: "VStack around a Row in a TableHeader", element: "div", container: "TableHeader", content: "header row") { page in
        page.Table { page.TableHeader { page.VStack { page.Row { page.Cell { page.Text("header row") } } } } }
    },
    .init(name: "VStack around a Cell in a Row", element: "div", container: "Row", content: "wrapped cell") { page in
        page.Table { page.TableBody { page.Row { page.VStack { page.Cell { page.Text("wrapped cell") } } } } }
    },
    .init(name: "Form around a TableBody in a Table", element: "form", container: "Table", content: "body in form") { page in
        page.Table { page.Form(action: "/t") { page.TableBody { page.Row { page.Cell { page.Text("body in form") } } } } }
    },
    .init(name: "VStack and HStack around a TableHeader", element: "div", container: "Table", content: "two wrappers") { page in
        page.Table { page.VStack { page.HStack { page.TableHeader { page.Row { page.Cell { page.Text("two wrappers") } } } } } }
    },
    .init(name: "Text directly in a Row (Text renders in a layout div)", element: "div", container: "Row", content: "loose text") { page in
        page.Table { page.TableBody { page.Row { page.Text("loose text"); page.Cell { page.Text("cell") } } } }
    },
    .init(name: "Table directly in a TableBody", element: "table", container: "TableBody", content: "inner table") { page in
        page.Table { page.TableBody { page.Table { page.TableBody { page.Row { page.Cell { page.Text("inner table") } } } } } }
    },
]

/// A page that commits every misuse in `phase1BuilderMisuseCases`, served by its own server instance.
final class Phase1BuilderMisusePage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "phase1-builder-misuse"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }

    override func content() -> Any? {
        return webpage {
            for misuseCase in phase1BuilderMisuseCases {
                misuseCase.build(self)
            }
            Text("misuse page rendered to the end")
        }
    }
}

/// A well-formed page served next to `Phase1BuilderMisusePage`.
final class Phase1BuilderPlainPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "phase1-builder-plain"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }

    override func content() -> Any? {
        return webpage {
            Table {
                TableBody {
                    Row { Cell { Text("plain page") } }
                }
            }
        }
    }
}

/// A second endpoint type that makes one of the mistakes `Phase1BuilderMisusePage` makes (a Cell outside
/// any Row), to check that the log keys reports per endpoint type.
final class Phase1BuilderSecondMisusePage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "phase1-builder-misuse-2"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }

    override func content() -> Any? {
        return webpage {
            Table { TableBody { Cell { Text("second endpoint") } } }
        }
    }
}

/// Captures values out of the (synchronously executed) `renderHTML` closure.
final class Phase1BuilderBox: @unchecked Sendable {
    var ids: [String] = []
    var elements: [WebElement] = []
    var page: CoreWebEndpoint? = nil
}

/// `Sources/WSwiftUI` of this package, found from this test file's path.
let phase1BuilderSourcesRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()      // WSwiftUITests
    .deletingLastPathComponent()      // Tests
    .deletingLastPathComponent()      // package root
    .appendingPathComponent("Sources/WSwiftUI", isDirectory: true)

/// Every `.swift` file under `Sources/WSwiftUI/<folder>`.
func phase1BuilderSwiftFiles(in folder: String) -> [URL] {
    let root = phase1BuilderSourcesRoot.appendingPathComponent(folder, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
}

/// The source line a misuse site (`"WSwiftUI/Table.swift:160"`) points at, plus the line after it (a guard
/// call can wrap its message onto the next line).
func phase1BuilderSourceLines(at site: String) -> String? {
    guard let colon = site.lastIndex(of: ":"), let line = Int(site[site.index(after: colon)...]) else { return nil }
    let fileName = (String(site[..<colon]) as NSString).lastPathComponent
    guard let url = phase1BuilderSwiftFiles(in: "").first(where: { $0.lastPathComponent == fileName }),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\n")
    guard line >= 1, line <= lines.count else { return nil }
    return lines[(line - 1)..<min(line + 1, lines.count)].joined(separator: "\n")
}

/// Every element below `root`, depth first.
func phase1BuilderDescendants(of root: WebElement) -> [WebElement] {
    return root.subElements.flatMap { [$0] + phase1BuilderDescendants(of: $0) }
}

/// Every misuse marker element in the tree under `root`, in document order.
func phase1BuilderMisuseElements(in root: WebElement?) -> [WebBuilderMisuseElement] {
    guard let root else { return [] }
    var found: [WebBuilderMisuseElement] = []
    if let marker = root as? WebBuilderMisuseElement { found.append(marker) }
    for child in root.subElements { found += phase1BuilderMisuseElements(in: child) }
    return found
}

/// Elements that are direct children of `<table>`, `<thead>`, `<tbody>`, `<tfoot>` or `<tr>` in `html` but
/// are not allowed there, as `"<form> in <tbody>"`. The HTML parser moves such elements out of the table
/// ("foster parenting") or wraps them in implied rows, so the DOM a browser builds differs from the page's
/// structure. `<template>` and `<script>` are allowed everywhere. Comments and script bodies are skipped.
func phase1BuilderTableContentViolations(in html: String) -> [String] {
    var text = html
    for (pattern, replacement) in [("<!--[\\s\\S]*?-->", ""),
                                   ("(<script\\b[^>]*>)[\\s\\S]*?(</script\\s*>)", "$1$2")] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                              withTemplate: replacement)
    }
    let section: Set<String> = ["tr", "template", "script"]
    let allowed: [String: Set<String>] = [
        "table": ["caption", "colgroup", "thead", "tbody", "tfoot", "tr", "template", "script"],
        "thead": section, "tbody": section, "tfoot": section,
        "tr": ["td", "th", "template", "script"],
    ]
    let voids: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]
    let tag = try! NSRegularExpression(pattern: "<(/?)([A-Za-z][A-Za-z0-9-]*)[^>]*>")
    let ns = text as NSString
    var open: [String] = []
    var violations: [String] = []
    for match in tag.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let closing = ns.substring(with: match.range(at: 1)) == "/"
        let name = ns.substring(with: match.range(at: 2)).lowercased()
        if closing {
            if let index = open.lastIndex(of: name) { open.removeSubrange(index...) }
            continue
        }
        // the parser leaves <input type="hidden"> in place inside table structure
        let hiddenInput = name == "input"
            && ns.substring(with: match.range).range(of: "type=\"hidden\"", options: .caseInsensitive) != nil
        if let parent = open.last, let permitted = allowed[parent], permitted.contains(name) == false, hiddenInput == false {
            violations.append("<\(name)> in <\(parent)>")
        }
        if voids.contains(name) == false { open.append(name) }
    }
    return violations
}

// MARK: - Misuse is reported, never fatal

@Suite("Phase 1 builder: misuse never terminates the process")
struct Phase1BuilderMisuseTests {

    @Test func noProcessTerminatingTrapsRemainInTheBuilderSources() {
        // fatalError/precondition/assert stop the whole server (assert in debug builds); builder code reports
        // misuse with misuse(_:) instead.
        let trap = try! NSRegularExpression(pattern: "\\b(fatalError|preconditionFailure|precondition|assertionFailure|assert)\\s*\\(")
        let files = phase1BuilderSwiftFiles(in: "WebUI/objects") + phase1BuilderSwiftFiles(in: "WebUI/builder")
        #expect(files.count > 20, "sources not found under \(phase1BuilderSourcesRoot.path)")
        var found: [String] = []
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if trap.firstMatch(in: code, range: NSRange(location: 0, length: (code as NSString).length)) != nil {
                    found.append("\(file.lastPathComponent):\(number + 1): \(code)")
                }
            }
        }
        #expect(found.isEmpty, "\(found)")
    }

    @Test func everyStructuralGuardHasAMisuseCase() throws {
        // Each guard call (`requireStructuralParent({ ... }`) in the compound
        // controls, with its message (the last string literal on the call's first two lines), must match one
        // case of phase1BuilderMisuseCases, and there must be exactly the 28 former fatalError sites.
        let call = try NSRegularExpression(pattern: "requireStructuralParent\\(\\{")
        let literal = try NSRegularExpression(pattern: "\"([^\"]*)\"")
        let owned = ["Modal", "Carousel", "Table", "OffCanvas", "Progress", "Card", "Pagination", "ListGroup", "Accordion"]
        var messages: [String] = []
        for name in owned {
            let url = phase1BuilderSourcesRoot.appendingPathComponent("WebUI/objects/\(name).swift")
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where call.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                let text = lines[index..<min(index + 2, lines.count)].joined(separator: "\n") as NSString
                let match = try #require(literal.matches(in: text as String, range: NSRange(location: 0, length: text.length)).last,
                                         "\(name).swift:\(index + 1) has no message")
                messages.append(text.substring(with: match.range(at: 1)))
            }
        }
        #expect(messages.count == 28)
        #expect(messages.sorted() == phase1BuilderMisuseCases.map(\.message).sorted())
    }

    @Test(arguments: phase1BuilderMisuseCases)
    func misuseRendersCommentAndElement(_ misuseCase: Phase1BuilderMisuseCase) throws {
        let box = Phase1BuilderBox()
        let html = renderHTML { page in
            box.page = page
            misuseCase.build(page)
            page.Text("after the misuse")
        }
        let marker = phase1BuilderMisuseMarker(misuseCase.message)
        #expect(ScriptScan.occurrences(of: marker, in: html) == 1, "\(misuseCase.name): \(html)")
        // the marker sits immediately before the misplaced element, which is still rendered
        let lines = html.split(separator: "\n").map(String.init)
        let index = try #require(lines.firstIndex(where: { $0.contains(marker) }))
        #expect(lines[index + 1].contains(misuseCase.rendered), "\(misuseCase.name): \(lines[index + 1])")
        // the rest of the page still renders
        #expect(html.contains("after the misuse"))
        #expect(html.hasSuffix("</html>\n"))
        // the report came from this case's own guard: its site is in the expected file, and the source
        // line it points at declares this message
        let reports = phase1BuilderMisuseElements(in: box.page?.webRootElement)
        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect(report.message == misuseCase.message)
        #expect(report.site.hasPrefix(misuseCase.file + ":"), "\(report.site)")
        let source = try #require(phase1BuilderSourceLines(at: report.site), "\(report.site)")
        #expect(source.contains("\"\(misuseCase.message)\""), "\(report.site): \(source)")
        // and it was logged for this endpoint type and site
        #expect(BuilderMisuseLog.shared.hasReported(ClosurePage.misuseLogKey(endpoint: "ClosurePage", site: report.site)))
    }

    @Test func theSameMistakeIsLoggedForEachEndpointType() {
        let server = TestHTTP.server()
        server.register(Phase1BuilderMisusePage())
        server.register(Phase1BuilderSecondMisusePage())
        #expect(server.respond(to: TestHTTP.request(.GET, "/phase1-builder-misuse")).status == .ok)
        #expect(server.respond(to: TestHTTP.request(.GET, "/phase1-builder-misuse-2")).status == .ok)
        // the Cell-outside-a-Row guard reported for both endpoints, under separate log keys
        let cellSite = BuilderMisuseLog.shared.reportedSites
            .filter { $0.hasPrefix("Phase1BuilderSecondMisusePage|") }
            .map { String($0.drop(while: { $0 != "|" }).dropFirst()) }
        #expect(cellSite.count == 1)
        for site in cellSite {
            #expect(BuilderMisuseLog.shared.hasReported(ClosurePage.misuseLogKey(endpoint: "Phase1BuilderMisusePage", site: site)))
        }
        #expect(ClosurePage.misuseLogKey(endpoint: "A", site: "WSwiftUI/Table.swift:1")
                != ClosurePage.misuseLogKey(endpoint: "B", site: "WSwiftUI/Table.swift:1"))
    }

    @Test func serverKeepsServingAfterEveryMisuse() {
        let server = TestHTTP.server()
        server.register(Phase1BuilderMisusePage())
        server.register(Phase1BuilderPlainPage())
        for _ in 0..<2 {
            let misuse = server.respond(to: TestHTTP.request(.GET, "/phase1-builder-misuse"))
            #expect(misuse.status == .ok)
            let body = misuse.bodyString
            for misuseCase in phase1BuilderMisuseCases {
                #expect(body.contains(phase1BuilderMisuseMarker(misuseCase.message)), "\(misuseCase.name)")
            }
            #expect(ScriptScan.occurrences(of: "data-wsui-misuse", in: body) == phase1BuilderMisuseCases.count)
            #expect(body.contains("misuse page rendered to the end"))

            let plain = server.respond(to: TestHTTP.request(.GET, "/phase1-builder-plain"))
            #expect(plain.status == .ok)
            #expect(plain.bodyString.contains("plain page"))
            #expect(plain.bodyString.contains("data-wsui-misuse") == false)
        }
    }

    @Test func misuseLogReportsEachSiteOnce() {
        let log = BuilderMisuseLog()
        #expect(log.markReported("WSwiftUI/Table.swift:1"))
        #expect(log.markReported("WSwiftUI/Table.swift:1") == false)
        #expect(log.markReported("WSwiftUI/Table.swift:2"))
        #expect(log.hasReported("WSwiftUI/Table.swift:1"))
        #expect(log.reportedSites == ["WSwiftUI/Table.swift:1", "WSwiftUI/Table.swift:2"])
    }

    @Test func misuseLogIsThreadSafe() {
        let log = BuilderMisuseLog()
        let firsts = Phase1BuilderCounter()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            if log.markReported("site-\(i % 10)") { firsts.increment() }
        }
        #expect(firsts.value == 10)
    }

    @Test func misuseCommentTextCannotCloseTheComment() {
        let html = renderHTML { page in
            page.misuse("bad --> <b>still a comment</b>")
            page.Text("after")
        }
        #expect(html.contains("<!-- WSwiftUI: bad --&gt; <b&gt;still a comment</b&gt; -->"))
        #expect(html.contains("after"))
    }
}

final class Phase1BuilderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// MARK: - Nearest structural ancestor: wrappers are allowed

@Suite("Phase 1 builder: parts are found through wrapper elements")
struct Phase1BuilderNestingTests {

    @Test func aFormPerRowGoesInsideACell() throws {
        // The supported per-row form: the Form inside a Cell. Its fields are its descendants, so the form's
        // own validation script (querySelectorAll on the form) and submission see them.
        let box = Phase1BuilderBox()
        let html = renderHTML { page in
            let table = page.Table {
                page.TableHeader {
                    page.Row { page.Cell { page.Text("Name") }; page.Cell { page.Text("Save") } }
                }
                page.TableBody {
                    for name in ["alpha", "beta"] {
                        page.Row {
                            page.Cell { page.Text(name) }
                            page.Cell {
                                page.Form(action: "/rows/\(name)") {
                                    page.TextField(binding: page.WString(name)).validate([.notEmpty])
                                    page.Button("Save", type: "submit")
                                }
                            }
                        }
                    }
                }
            }
            box.elements = [table]
            page.Text("after the table")
        }
        #expect(html.contains("data-wsui-misuse") == false, "\(html)")
        #expect(phase1BuilderTableContentViolations(in: html).isEmpty, "\(phase1BuilderTableContentViolations(in: html))")
        #expect(ScriptScan.occurrences(of: "<form", in: html) == 2)
        #expect(html.contains("action=\"/rows/alpha\"") && html.contains("action=\"/rows/beta\""))
        // the built structure: table > thead/tbody > tr > td, and each row's second cell holds its own form
        // with the validated field and the submit button inside it
        let table = try #require(box.elements.first as? WebTableElement)
        #expect(table.subElements.map(\.elementName) == ["thead", "tbody"])
        let rows = try #require(table.subElements.last).subElements
        #expect(rows.count == 2 && rows.allSatisfy { $0 is WebTableRowElement })
        for row in rows {
            #expect(row.subElements.count == 2 && row.subElements.allSatisfy { $0 is WebTableCellElement })
            let form = try #require(row.subElements.last?.subElements.first as? WebFormElement)
            let inside = phase1BuilderDescendants(of: form)
            #expect(inside.contains { element in
                element is WebInputElement && element.attributes.contains { if case .validation = $0 { return true }; return false }
            })
            #expect(inside.contains { element in
                element is WebButtonElement && element.attributes.contains { if case .type("submit") = $0 { return true }; return false }
            })
        }
    }

    @Test(arguments: phase1BuilderTableContentCases)
    func nonTableContentInTableStructureIsReported(_ contentCase: Phase1BuilderTableContentCase) throws {
        // A browser moves a non-table element out of table structure (the per-row Form ends up empty in
        // front of the row, a VStack <div> ends up in front of the table), so it is reported.
        let box = Phase1BuilderBox()
        let html = renderHTML { page in
            box.page = page
            contentCase.build(page)
            page.Text("after the table")
        }
        let marker = phase1BuilderMisuseMarker(contentCase.message)
        #expect(ScriptScan.occurrences(of: marker, in: html) == 1, "\(contentCase.name): \(html)")
        // reported once, by the table container's check of its children
        let reports = phase1BuilderMisuseElements(in: box.page?.webRootElement)
        #expect(reports.map(\.message) == [contentCase.message])
        let site = try #require(reports.first?.site)
        #expect(site.hasPrefix("WSwiftUI/Table.swift:"))
        #expect(phase1BuilderSourceLines(at: site)?.contains("misuseMarker(tableContentMessage(") == true, "\(site)")
        // the marker sits right in front of the offending element, which is still rendered with its
        // content, and the page completes
        let lines = html.split(separator: "\n").map(String.init)
        let index = try #require(lines.firstIndex(where: { $0.contains(marker) }))
        #expect(lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("<\(contentCase.element)"), "\(lines[index + 1])")
        #expect(html.contains(contentCase.content))
        #expect(html.contains("after the table"))
        // and this is exactly the structure the browser would rearrange
        #expect(phase1BuilderTableContentViolations(in: html).isEmpty == false)
    }

    @Test func everyTableStructureViolationIsReported() {
        // Over valid and invalid table nestings: whenever the page has a non-table element directly inside
        // table structure (which browsers move), a misuse marker reports it; and valid nestings have neither.
        var pages: [(name: String, valid: Bool, build: (CoreWebEndpoint) -> Void)] =
            phase1BuilderTableContentCases.map { ($0.name, false, $0.build) }
        pages += [
            ("plain table", true, { page in
                page.Table { page.TableHeader { page.Row { page.Cell { page.Text("h") } } }
                             page.TableBody { page.Row { page.Cell { page.Text("b") } } } }
            }),
            ("wrappers inside cells", true, { page in
                page.Table { page.TableBody { page.Row {
                    page.Cell { page.VStack { page.HStack { page.Text("deep") } } }
                    page.Cell { page.Form(action: "/x") { page.Button("Go", type: "submit") } }
                } } }
            }),
            ("nested table in a cell", true, { page in
                page.Table { page.TableBody { page.Row { page.Cell {
                    page.Table { page.TableBody { page.Row { page.Cell { page.Text("inner") } } } }
                } } } }
            }),
            ("table inside a form and a stack", true, { page in
                page.Form(action: "/all") { page.VStack {
                    page.Table { page.TableBody { page.Row { page.Cell { page.Text("in form") } } } }
                } }
            }),
            ("bound variables declared in a row and a body", true, { page in
                page.Table { page.TableBody {
                    let rowCount = page.WInt(1)
                    page.Row {
                        let flag = page.WBool(true)
                        page.Cell { page.Text("flag").hidden(flag) }
                        page.Cell { page.Text("count").hidden(rowCount) }
                    }
                } }
            }),
            ("caption, th and tfoot made with create", true, { page in
                page.Table {
                    _ = page.create { element in element.elementName = "caption" }
                    page.TableHeader { page.Row { _ = page.create { element in element.elementName = "th" } } }
                    _ = page.create { element in element.elementName = "tfoot" }
                }
            }),
            ("cell directly in a body", false, { page in page.Table { page.TableBody { page.Cell { page.Text("x") } } } }),
            ("row directly in a table", false, { page in page.Table { page.Row { page.Cell { page.Text("x") } } } }),
            ("th made with create directly in a body", false, { page in
                page.Table { page.TableBody { _ = page.create { element in element.elementName = "th" } } }
            }),
        ]
        for (name, valid, build) in pages {
            let html = renderHTML { page in build(page) }
            let violations = phase1BuilderTableContentViolations(in: html)
            let reported = html.contains("data-wsui-misuse")
            if violations.isEmpty == false {
                #expect(reported, "\(name): \(violations) not reported")
            }
            #expect(reported != valid, "\(name)")
            if valid {
                #expect(violations.isEmpty, "\(name): \(violations)")
            }
        }
    }

    @Test func tableContentCheckerSeesWhatTheParserMoves() {
        #expect(phase1BuilderTableContentViolations(in: "<table><tbody><tr><td><form><input></form></td></tr></tbody></table>").isEmpty)
        #expect(phase1BuilderTableContentViolations(in: "<table><tbody><template><!-- <div> --></template><script>if (a<b) {}</script><tr></tr></tbody></table>").isEmpty)
        #expect(phase1BuilderTableContentViolations(in: "<table><tbody><form><tr></tr></form></tbody></table>") == ["<form> in <tbody>"])
        #expect(phase1BuilderTableContentViolations(in: "<table><tr><div><td></td></div></tr></table>") == ["<div> in <tr>"])
        #expect(phase1BuilderTableContentViolations(in: "<table><tbody><input type=\"hidden\"></input><tr></tr></tbody></table>").isEmpty)
        #expect(phase1BuilderTableContentViolations(in: "<table><tbody><input type=\"text\"></input></tbody></table>") == ["<input> in <tbody>"])
    }

    @Test func nestedTablesUseTheInnermostTable() {
        let html = renderHTML { page in
            page.Table {
                page.TableBody {
                    page.Row {
                        page.Cell {
                            page.Table {
                                page.TableBody { page.Row { page.Cell { page.Text("inner") } } }
                            }
                        }
                    }
                }
            }
        }
        #expect(html.contains("data-wsui-misuse") == false)
        #expect(ScriptScan.occurrences(of: "<td", in: html) == 2)
    }

    @Test func structuralMisnestingIsStillReported() {
        // a Row whose nearest table part is a Cell is misplaced even though a TableBody is further up
        let html = renderHTML { page in
            page.Table { page.TableBody { page.Row { page.Cell { page.Row {} } } } }
            page.Card { page.CardBody { page.CardHeader {} } }
        }
        #expect(html.contains(phase1BuilderMisuseMarker("Row must be used inside a TableHeader or TableBody block")))
        #expect(html.contains(phase1BuilderMisuseMarker("CardHeader must be used inside a Card { ... } block")))
    }

    @Test func cardPartsInsideWrappers() throws {
        let html = renderHTML { page in
            page.Card {
                page.VStack {
                    page.CardHeader { page.Text("head") }
                    page.HStack { page.CardBody { page.Text("body") } }
                    page.CardFooter { page.Text("foot") }
                }
            }
        }
        #expect(html.contains("data-wsui-misuse") == false)
        let card = try #require(phase1BuilderSubtree(containing: "wsui-card", in: html))
        for part in ["card-header", "card-body", "card-footer"] {
            #expect(card.contains(part))
        }
    }

    @Test func modalPartsInsideWrappers() throws {
        let html = renderHTML { page in
            page.Modal(id: "wrapped") {
                page.VStack {
                    page.ModalDialog {
                        page.Form(action: "/save") {
                            page.ModalContent {
                                page.ModalHeader { page.HStack { page.ModalTitle { page.Text("title") } } }
                                page.VStack { page.ModalBody { page.Text("body") } }
                                page.ModalFooter { page.Button("OK") }
                            }
                        }
                    }
                }
            }
        }
        #expect(html.contains("data-wsui-misuse") == false)
        let modal = try #require(phase1BuilderSubtree(containing: "wsui-modal", in: html))
        for part in ["modal-dialog", "modal-content", "modal-header", "modal-title", "modal-body", "modal-footer", "btn-close"] {
            #expect(modal.contains(part), "\(part)")
        }
    }

    @Test func offCanvasCarouselAndListPartsInsideWrappers() {
        let html = renderHTML { page in
            page.OffCanvas(id: "panel") {
                page.VStack {
                    page.OffCanvasHeader { page.VStack { page.OffCanvasTitle { page.Text("t") } } }
                    page.OffCanvasBody { page.Text("b") }
                    page.OffCanvasFooter { page.Text("f") }
                }
            }
            page.Carousel(id: "slides") {
                page.VStack {
                    page.CarouselInner { page.VStack { page.CarouselItem(active: true) { page.Text("s1") } } }
                    page.CarouselIndicators(id: "slides", count: 1)
                    page.CarouselControlPrev(id: "slides")
                    page.CarouselControlNext(id: "slides")
                }
            }
            page.Progress { page.VStack { page.ProgressBar(value: 30) } }
            page.Pagination { page.VStack { page.PaginationItem(page: 1, href: "/p/1") } }
            page.ListGroup { page.VStack { page.ListGroupItem("item") } }
        }
        #expect(html.contains("data-wsui-misuse") == false, "\(html)")
        for part in ["offcanvas-title", " wsui-offcanvas-footer mt-auto flex-shrink-0 p-3 border-top\"", "carousel-item",
                     "carousel-control-next", "progress-bar", "page-item", "list-group-item"] {
            #expect(html.contains(part), "\(part)")
        }
        // the footer's old class, which Bootstrap 5.3 doesn't define, is not a class token any more
        #expect(html.range(of: "[\" ]offcanvas-footer[\" ]", options: .regularExpression) == nil)
    }

    @Test func accordionItemInsideAWrapperKeepsItsParent() throws {
        let box = Phase1BuilderBox()
        let html = renderHTML { page in
            let accordion = page.Accordion {
                page.VStack { page.AccordionItem(title: "Wrapped") { page.Text("content") } }
            }
            box.ids = [accordion.builderId]
        }
        #expect(html.contains("data-wsui-misuse") == false)
        let accordionId = try #require(box.ids.first)
        #expect(html.contains("data-bs-parent=\"#\(accordionId)\""))
    }

    @Test func accordionBodyContentIsInsideAccordionBody() throws {
        let html = renderHTML { page in
            page.Accordion {
                page.AccordionItem(title: "First") { page.Text("first body text") }
            }
        }
        let body = try #require(phase1BuilderSubtree(containing: "accordion-body", in: html))
        #expect(body.contains("first body text"), "\(html)")
        #expect(html.contains("accordion-body\"></div>") == false)
    }

    @Test func accordionAlwaysOpenRemovesOnlyItsOwnParentLinks() throws {
        let box = Phase1BuilderBox()
        let html = renderHTML { page in
            let outer = page.Accordion {
                page.AccordionItem(title: "One") {
                    let inner = page.Accordion { page.AccordionItem(title: "Inner") {} }
                    box.ids.append(inner.builderId)
                }
                page.AccordionItem(title: "Two") {}
            }.alwaysOpen(true)
            box.ids.append(outer.builderId)
            let normal = page.Accordion { page.AccordionItem(title: "Three") {} }.alwaysOpen(false)
            box.ids.append(normal.builderId)
        }
        let (innerId, outerId, normalId) = (box.ids[0], box.ids[1], box.ids[2])
        #expect(html.contains("data-bs-parent=\"#\(outerId)\"") == false)
        #expect(ScriptScan.occurrences(of: "data-bs-parent=\"#\(innerId)\"", in: html) == 1)
        #expect(ScriptScan.occurrences(of: "data-bs-parent=\"#\(normalId)\"", in: html) == 1)
        #expect(html.contains("accordion-always-open") == false)
    }

    @Test func accordionItemNestedInAnItemBodyIsReported() {
        // the inner item's nearest accordion part is the outer item, not an Accordion
        let html = renderHTML { page in
            page.Accordion {
                page.AccordionItem(title: "Outer") {
                    page.AccordionItem(title: "Inner") {}
                }
            }
            page.Accordion {
                page.AccordionItem(title: "Outer 2") {
                    page.Accordion { page.AccordionItem(title: "Properly nested") {} }
                }
            }
        }
        let marker = phase1BuilderMisuseMarker("AccordionItem must be called within an Accordion { ... } block")
        #expect(ScriptScan.occurrences(of: marker, in: html) == 1)
    }
}

// MARK: - Builder stack discipline

@Suite("Phase 1 builder: stack helpers")
struct Phase1BuilderStackTests {

    @Test func containerUnwindsAChildThatForgotToPop() throws {
        // A child builder that pushes itself and never pops must not capture what follows its container.
        let html = renderHTML { page in
            page.Card {
                page.CardBody {
                    let leaked = page.create { element in element.class("leaky-builder") }
                    page.stack.append(leaked)
                }
                page.CardFooter { page.Text("footer text") }
            }
            page.Text("after the card")
        }
        #expect(html.contains("data-wsui-misuse") == false)
        let leaked = try #require(phase1BuilderSubtree(containing: "leaky-builder", in: html))
        #expect(leaked.contains("footer text") == false)
        let card = try #require(phase1BuilderSubtree(containing: "wsui-card", in: html))
        #expect(card.contains("card-footer"))
        #expect(card.contains("after the card") == false)
    }

    @Test func nearestAncestorLooksThroughWrappers() {
        let page = ClosurePage()
        let table = WebTableElement()
        let body = WebTableBodyElement()
        let form = WebFormElement()
        page.stack = [table, body, form, WebElement()]
        #expect(page.nearestAncestor(of: WebTableBodyElement.self) === body)
        #expect(page.nearestAncestor(of: WebTableElement.self) === table)
        #expect(page.nearestAncestor(of: WebTableRowElement.self) == nil)
        #expect(page.nearestAncestor(where: { $0 is WebFormElement }) === form)
    }

    @Test func withParentAndUnwindStack() {
        let page = ClosurePage()
        let a = WebElement(), b = WebElement(), c = WebElement()
        page.stack = [a]
        let returned = page.withParent(b) {
            #expect(page.stack.last === b)
            page.stack.append(c)   // never popped
        }
        #expect(returned === b)
        #expect(page.stack.count == 1)
        #expect(page.stack.first === a)
        page.unwindStack(to: WebElement())  // not on the stack: no change
        #expect(page.stack.count == 1)
    }
}

// MARK: - Values that used to trap

@Suite("Phase 1 builder: bad values never terminate the process")
struct Phase1BuilderValueTrapTests {

    @Test func doubleProgressBarWithNaNOrInfinityRenders() throws {
        // Each of these trapped in an Int conversion ("Double value cannot be converted to Int because it is
        // either infinite or NaN").
        let cases: [(value: Double, max: Double, width: String, now: String, valueMax: String)] = [
            (.nan, 1.0, "width: 0%", "aria-valuenow=\"0.0\"", "aria-valuemax=\"1\""),
            (.infinity, 1.0, "width: 0%", "aria-valuenow=\"0.0\"", "aria-valuemax=\"1\""),
            (-.infinity, 2.0, "width: 0%", "aria-valuenow=\"0.0\"", "aria-valuemax=\"2\""),
            (0.5, .infinity, "width: 50%", "aria-valuenow=\"0.5\"", "aria-valuemax=\"1\""),
            (0.5, .nan, "width: 50%", "aria-valuenow=\"0.5\"", "aria-valuemax=\"1\""),
            (0.5, -.infinity, "width: 50%", "aria-valuenow=\"0.5\"", "aria-valuemax=\"1\""),
            (1e300, 1e300, "width: 100%", "aria-valuenow=\"1e+300\"", "aria-valuemax=\"\(Int.max)\""),
        ]
        for testCase in cases {
            let box = Phase1BuilderBox()
            let html = renderHTML { page in
                page.Progress {
                    box.elements = [page.ProgressBar(page.WDouble(testCase.value), max: testCase.max)]
                }
            }
            #expect(html.hasSuffix("</html>\n"))
            let bar = try #require(phase1BuilderSubtree(containing: "progress-bar", in: html))
            #expect(bar.contains(testCase.width), "\(testCase): \(bar)")
            #expect(bar.contains(testCase.now), "\(testCase): \(bar)")
            #expect(bar.contains(testCase.valueMax), "\(testCase): \(bar)")
            // the update script gets the same finite max (Swift prints NaN as `nan` and infinity as `inf`,
            // which are not JavaScript)
            let script = phase1BuilderScripts(try #require(box.elements.first)).joined()
            let finiteMax = (testCase.max.isFinite && testCase.max > 0) ? testCase.max : 1
            #expect(script.contains("Math.min(Math.max(numeric, 0), \(finiteMax));"), "\(script)")
            #expect(script.contains("nan") == false && script.contains("inf)") == false, "\(script)")
        }
    }

    @Test func intProgressBarWithExtremeValuesRenders() {
        let html = renderHTML { page in
            page.Progress {
                page.ProgressBar(value: Int.max, max: 0)
                page.ProgressBar(value: Int.min, max: Int.min)
                page.ProgressBar(page.WInt(Int.max), max: Int.max)
            }
        }
        #expect(html.hasSuffix("</html>\n"))
        #expect(ScriptScan.occurrences(of: "role=\"progressbar\"", in: html) == 3)
    }

    @Test func negativeCarouselIndicatorCountIsReported() {
        // `0..<count` trapped with "Range requires lowerBound <= upperBound".
        let html = renderHTML { page in
            page.Carousel(id: "c1") {
                page.CarouselIndicators(id: "c1", count: -1)
                page.CarouselIndicators(id: "c1", count: 0)
                page.CarouselIndicators(id: "c1", count: 2, activeIndex: 1)
            }
            page.Text("after the carousel")
        }
        #expect(html.contains(phase1BuilderMisuseMarker("CarouselIndicators count must not be negative (got -1); no indicators are rendered")))
        #expect(ScriptScan.occurrences(of: "data-wsui-misuse", in: html) == 1)
        #expect(ScriptScan.occurrences(of: "carousel-indicators", in: html) == 3)
        #expect(ScriptScan.occurrences(of: "data-bs-slide-to=", in: html) == 2)
        #expect(html.contains("after the carousel"))
    }
}
