//
//  Phase1UnwindStackTests.swift
//  WSwiftUITests
//
//  Unwind slice: every builder in WebUI/objects leaves the builder stack at the depth it found it, whatever
//  its content did: plain content, content that reports misuse, and content whose own builder pushed an
//  element and never popped it (which used to capture everything declared after the container).
//

import Foundation
import Testing
@testable import WSwiftUI

/// Records the builder stack around the one call under test.
final class Phase1UnwindProbe: @unchecked Sendable {
    var depthBefore: Int? = nil
    var depthAfter: Int? = nil
    var parentBefore: WebElement? = nil
    var parentAfter: WebElement? = nil
    var leaked: WebElement? = nil

    /// Runs `call` (the builder under test) and records the stack before and after it.
    func measure(_ page: CoreWebEndpoint, _ call: () -> Void) {
        depthBefore = page.stack.count
        parentBefore = page.stack.last
        call()
        depthAfter = page.stack.count
        parentAfter = page.stack.last
    }
}

/// What the content of the container under test does.
enum Phase1UnwindContent: String, CaseIterable, Sendable {
    /// A plain leaf (`Text`).
    case plain
    /// Builders that report misuse: a direct `misuse(_:)` and a `CarouselIndicators` with a negative count
    /// (reported wherever it is declared).
    case misuse
    /// A nested builder that pushed an element and never popped it, after reporting misuse.
    case leak
}

/// The content closure for `kind`.
func phase1UnwindContent(_ kind: Phase1UnwindContent, page: CoreWebEndpoint, probe: Phase1UnwindProbe) -> () -> Void {
    switch kind {
    case .plain:
        return { page.Text("inside") }
    case .misuse:
        return {
            page.misuse("unwind probe")
            page.CarouselIndicators(id: "probe", count: -1)
        }
    case .leak:
        return {
            page.misuse("unwind probe before a leak")
            let leaked = WebElement()
            probe.leaked = leaked
            page.stack.append(leaked)
        }
    }
}

/// A builder under test, built in the context it needs, with `probe.measure` around exactly the call under test.
struct Phase1UnwindContainerCase: Sendable, CustomTestStringConvertible {
    let name: String
    /// `false` for builders without a content closure (they are run once, with plain content unused).
    let takesContent: Bool
    /// `false` for a builder that takes content but never runs it (a not implemented picker style).
    let runsContent: Bool
    let build: @Sendable (_ page: CoreWebEndpoint, _ probe: Phase1UnwindProbe, _ content: @escaping () -> Void) -> Void

    init(_ name: String, takesContent: Bool = true, runsContent: Bool = true,
         _ build: @escaping @Sendable (_ page: CoreWebEndpoint, _ probe: Phase1UnwindProbe, _ content: @escaping () -> Void) -> Void) {
        self.name = name
        self.takesContent = takesContent
        self.runsContent = runsContent
        self.build = build
    }

    var testDescription: String { name }
}

/// Every builder in WebUI/objects that opens a container on the builder stack (directly or through
/// `WrapInLayoutContainer`), plus the leaf builders that open one internally.
let phase1UnwindContainerCases: [Phase1UnwindContainerCase] = [
    // Accordion
    .init("Accordion") { p, probe, c in probe.measure(p) { p.Accordion(c) } },
    .init("AccordionItem") { p, probe, c in p.Accordion { probe.measure(p) { p.AccordionItem(title: "t", c) } } },
    // Alert
    .init("Alert") { p, probe, c in probe.measure(p) { p.Alert(.info, c) } },
    .init("Alert dismissible") { p, probe, c in probe.measure(p) { p.Alert(.info, dismissible: true, c) } },
    .init("Alert(isPresented:)", takesContent: false) { p, probe, _ in
        let shown = p.WBool(true)
        probe.measure(p) { p.Alert("t", isPresented: shown, message: "m", dismissible: true) }
    },
    // Breadcrumb
    .init("Breadcrumb") { p, probe, c in probe.measure(p) { p.Breadcrumb(c) } },
    .init("BreadcrumbItem", takesContent: false) { p, probe, _ in
        p.Breadcrumb { probe.measure(p) { p.BreadcrumbItem(title: "t", url: "/", active: true) } }
    },
    .init("Callout") { p, probe, c in probe.measure(p) { p.Callout(.info, c) } },
    // Card
    .init("Card") { p, probe, c in probe.measure(p) { p.Card(c) } },
    .init("CardHeader") { p, probe, c in p.Card { probe.measure(p) { p.CardHeader(c) } } },
    .init("CardBody") { p, probe, c in p.Card { probe.measure(p) { p.CardBody(c) } } },
    .init("CardFooter") { p, probe, c in p.Card { probe.measure(p) { p.CardFooter(c) } } },
    // Carousel
    .init("Carousel") { p, probe, c in probe.measure(p) { p.Carousel(id: "c", c) } },
    .init("CarouselInner") { p, probe, c in p.Carousel(id: "c") { probe.measure(p) { p.CarouselInner(c) } } },
    .init("CarouselItem") { p, probe, c in
        p.Carousel(id: "c") { p.CarouselInner { probe.measure(p) { p.CarouselItem(active: true, c) } } }
    },
    .init("Code", takesContent: false) { p, probe, _ in probe.measure(p) { p.Code(language: .swift, "let x = 1") } },
    .init("FileUploader") { p, probe, c in probe.measure(p) { p.FileUploader(action: "/upload", c) } },
    .init("Flex") { p, probe, c in probe.measure(p) { p.Flex(c) } },
    .init("Footer") { p, probe, c in probe.measure(p) { p.Footer(c) } },
    .init("Form") { p, probe, c in probe.measure(p) { p.Form(action: "/f", c) } },
    .init("HStack") { p, probe, c in probe.measure(p) { p.HStack(c) } },
    // Jumbotron
    .init("Jumbotron") { p, probe, c in probe.measure(p) { p.Jumbotron(c) } },
    .init("Jumbotron fluid") { p, probe, c in probe.measure(p) { p.Jumbotron(fluid: true, c) } },
    .init("Link", takesContent: false) { p, probe, _ in probe.measure(p) { p.Link("/", title: "t") } },
    .init("ListGroup") { p, probe, c in probe.measure(p) { p.ListGroup(c) } },
    // Modal
    .init("Modal") { p, probe, c in probe.measure(p) { p.Modal(id: "m", c) } },
    .init("ModalDialog") { p, probe, c in p.Modal(id: "m") { probe.measure(p) { p.ModalDialog(c) } } },
    .init("ModalContent") { p, probe, c in p.Modal(id: "m") { p.ModalDialog { probe.measure(p) { p.ModalContent(c) } } } },
    .init("ModalHeader") { p, probe, c in
        p.Modal(id: "m") { p.ModalDialog { p.ModalContent { probe.measure(p) { p.ModalHeader(c) } } } }
    },
    .init("ModalTitle") { p, probe, c in
        p.Modal(id: "m") { p.ModalDialog { p.ModalContent { p.ModalHeader { probe.measure(p) { p.ModalTitle(c) } } } } }
    },
    .init("ModalBody") { p, probe, c in
        p.Modal(id: "m") { p.ModalDialog { p.ModalContent { probe.measure(p) { p.ModalBody(c) } } } }
    },
    .init("ModalFooter") { p, probe, c in
        p.Modal(id: "m") { p.ModalDialog { p.ModalContent { probe.measure(p) { p.ModalFooter(c) } } } }
    },
    .init("Modal(isPresented:)") { p, probe, c in
        let shown = p.WBool(false)
        probe.measure(p) { p.Modal(id: "m", isPresented: shown, c) }
    },
    .init("Sheet") { p, probe, c in
        let shown = p.WBool(false)
        probe.measure(p) { p.Sheet(isPresented: shown, c) }
    },
    // Navigation
    .init("NavBar") { p, probe, c in probe.measure(p) { p.NavBar(brand: "b", c) } },
    .init("NavBarItem", takesContent: false) { p, probe, _ in
        p.NavBar(brand: "b") { probe.measure(p) { p.NavBarItem(title: "t", href: "/", active: true) } }
    },
    .init("NavDropdown") { p, probe, c in p.NavBar(brand: "b") { probe.measure(p) { p.NavDropdown(title: "t", id: "d", c) } } },
    .init("NavDropdownItem", takesContent: false) { p, probe, _ in
        p.NavBar(brand: "b") { p.NavDropdown(title: "t", id: "d") { probe.measure(p) { p.NavDropdownItem(title: "i", href: "/") } } }
    },
    // OffCanvas
    .init("OffCanvas") { p, probe, c in probe.measure(p) { p.OffCanvas(id: "o", c) } },
    .init("OffCanvasHeader") { p, probe, c in p.OffCanvas(id: "o") { probe.measure(p) { p.OffCanvasHeader(c) } } },
    .init("OffCanvasTitle") { p, probe, c in p.OffCanvas(id: "o") { p.OffCanvasHeader { probe.measure(p) { p.OffCanvasTitle(c) } } } },
    .init("OffCanvasBody") { p, probe, c in p.OffCanvas(id: "o") { probe.measure(p) { p.OffCanvasBody(c) } } },
    .init("OffCanvasFooter") { p, probe, c in p.OffCanvas(id: "o") { probe.measure(p) { p.OffCanvasFooter(c) } } },
    .init("OffCanvas(isPresented:)") { p, probe, c in
        let shown = p.WBool(false)
        probe.measure(p) { p.OffCanvas(id: "o", isPresented: shown, c) }
    },
    // Pagination
    .init("Pagination") { p, probe, c in probe.measure(p) { p.Pagination(c) } },
    .init("PaginationItem", takesContent: false) { p, probe, _ in
        p.Pagination { probe.measure(p) { p.PaginationItem(page: 1, href: "/1", active: true) } }
    },
    // Picker
    .init("Picker menu") { p, probe, c in
        let choice = p.WString("a")
        probe.measure(p) { p.Picker("t", selection: choice, c) }
    },
    .init("Picker segmented") { p, probe, c in
        let choice = p.WString("a").name("choice")
        probe.measure(p) { p.Picker("t", selection: choice, style: .segmented(.primary), c) }
    },
    .init("Picker radio") { p, probe, c in
        let choice = p.WString("a")
        probe.measure(p) { p.Picker("t", selection: choice, style: .radio(.vertical), c) }
    },
    .init("Picker color (not implemented)", runsContent: false) { p, probe, c in
        let choice = p.WString("#fff")
        probe.measure(p) { p.Picker("t", selection: choice, style: .color, c) }
    },
    .init("Progress") { p, probe, c in probe.measure(p) { p.Progress(c) } },
    .init("Spinner", takesContent: false) { p, probe, _ in probe.measure(p) { p.Spinner("s") } },
    // Table
    .init("Table") { p, probe, c in probe.measure(p) { p.Table(c) } },
    .init("TableHeader") { p, probe, c in p.Table { probe.measure(p) { p.TableHeader(c) } } },
    .init("TableBody") { p, probe, c in p.Table { probe.measure(p) { p.TableBody(c) } } },
    .init("Row") { p, probe, c in p.Table { p.TableBody { probe.measure(p) { p.Row(c) } } } },
    .init("Cell") { p, probe, c in p.Table { p.TableBody { p.Row { probe.measure(p) { p.Cell(c) } } } } },
    // Text
    .init("Text", takesContent: false) { p, probe, _ in probe.measure(p) { p.Text("t") } },
    .init("Text(binding)", takesContent: false) { p, probe, _ in
        let name = p.WString("n")
        probe.measure(p) { p.Text(name) }
    },
    .init("Text(format:)", takesContent: false) { p, probe, _ in
        let name = p.WString("n")
        probe.measure(p) { p.Text("$0", name) }
    },
    .init("Text as a menu option", takesContent: false) { p, probe, _ in
        p.Picker("t", selection: p.WString("a")) { probe.measure(p) { p.Text("A").value("a") } }
    },
    .init("Text as a radio option", takesContent: false) { p, probe, _ in
        p.Picker("t", selection: p.WString("a"), style: .radio(.horizontal)) { probe.measure(p) { p.Text("A").value("a") } }
    },
    .init("Text as a segment", takesContent: false) { p, probe, _ in
        p.Picker("t", selection: p.WString("a"), style: .segmented(.success)) { probe.measure(p) { p.Text("A").value("a") } }
    },
    .init("Text in an HStack", takesContent: false) { p, probe, _ in p.HStack { probe.measure(p) { p.Text("t") } } },
    // Toggle
    .init("Toggle(value:)", takesContent: false) { p, probe, _ in
        let flag = p.WBool(true)
        probe.measure(p) { p.Toggle(value: flag) }
    },
    .init("Toggle(_:isOn:)", takesContent: false) { p, probe, _ in
        let flag = p.WBool(false)
        probe.measure(p) { p.Toggle("t", isOn: flag) }
    },
    // Stacks and layout containers
    .init("VStack") { p, probe, c in probe.measure(p) { p.VStack(c) } },
    .init("VStack(mode: .fit)") { p, probe, c in probe.measure(p) { p.VStack(mode: .fit, spacing: 7, c) } },
    .init("WrapInLayoutContainer") { p, probe, c in probe.measure(p) { p.WrapInLayoutContainer(c) } },
    .init("WrapInLayoutContainer in an HStack") { p, probe, c in p.HStack { probe.measure(p) { p.WrapInLayoutContainer(c) } } },
]

@Suite("Phase 1 unwind: every builder restores the builder stack")
struct Phase1UnwindStackTests {

    @Test(arguments: phase1UnwindContainerCases)
    func builderRestoresTheStackWhateverItsContentDoes(_ container: Phase1UnwindContainerCase) {
        let variants: [Phase1UnwindContent] = container.takesContent ? Phase1UnwindContent.allCases : [.plain]
        for variant in variants {
            let probe = Phase1UnwindProbe()
            let html = renderHTML { page in
                let content = phase1UnwindContent(variant, page: page, probe: probe)
                page.VStack {
                    container.build(page, probe, content)
                    page.Text("declared after the container")
                }
                page.Text("end of page")
            }
            let label = "\(container.name) [\(variant.rawValue)]"
            #expect(probe.depthBefore != nil, "\(label): the builder under test did not run")
            #expect(probe.depthAfter == probe.depthBefore,
                    "\(label): stack depth \(probe.depthBefore ?? -1) before, \(probe.depthAfter ?? -1) after")
            #expect(probe.parentAfter === probe.parentBefore, "\(label): a different element is open after the builder")
            #expect(html.contains("declared after the container"), "\(label)")
            #expect(html.hasSuffix("</html>\n"), "\(label)")
            if variant == .leak && container.runsContent {
                #expect(probe.leaked != nil, "\(label): the content was not run")
            }
            if variant != .plain {
                // the misuse reported inside the content (or by the builder) is in the page
                #expect(html.contains("data-wsui-misuse"), "\(label)")
            }
        }
    }

    @Test func everyContainerInTheObjectsSourcesUnwindsWithWithParent() throws {
        // No builder in WebUI/objects pops the stack by hand any more: `stack.removeAll(where:)` left a
        // leaked child on the stack, and `removeLast()` popped the wrong elements.
        let manual = try NSRegularExpression(pattern: "\\bstack\\.(append|removeAll|removeLast|popLast|remove)\\b")
        var found: [String] = []
        for file in phase1BuilderSwiftFiles(in: "WebUI/objects") {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces).hasPrefix("//") == false {
                if manual.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                    found.append("\(file.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(found.isEmpty, "\(found)")
    }

    @Test func leakedChildDoesNotCaptureLaterSiblings() throws {
        // A NavBar whose content leaks: the next element is a sibling of the navbar, not a child of the leak
        // or of one of the navbar's inner containers (removeLast() used to pop the leak and leave the nav open).
        let box = Phase1UnwindBox()
        _ = renderHTML { page in
            let nav = page.NavBar(brand: "b") {
                page.NavBarItem(title: "Home", href: "/")
                page.stack.append(WebElement())
            }
            let after = page.Badge("after the navbar")
            box.elements = [nav, after]
            box.page = page
        }
        let nav = try #require(box.elements.first)
        let after = try #require(box.elements.last)
        let root = try #require(box.page?.documentRoot)
        let parent = try #require(Phase1UnwindNormalizer.elements(under: root).first { candidate in
            candidate.subElements.contains { $0 === nav }
        })
        #expect(parent.subElements.contains { $0 === after }, "the badge was captured by an element left open")
        #expect(Phase1UnwindNormalizer.elements(under: nav).contains { $0 === after } == false)
    }
}
