//
//  Phase1UnwindObjectTests.swift
//  WSwiftUITests
//
//  Unwind slice: object cleanup in WebUI/objects. Accordion ids and open-item markup, a valid OffCanvas
//  footer, the FileUploader progress bar inside its track, real Bootstrap classes (list group, spinner,
//  label alignment, no Bootstrap 4 leftovers), misuse instead of traps, deterministic JSON, and
//  `escapedForHTML` without a per-call dictionary.
//
//  These tests use only API that existed before this slice, so they also build (and fail) on the baseline.
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Helpers (unwind slice)

/// The start tag of `element` in `html` (every created element carries its builderId as its first class).
func phase1UnwindStartTag(of element: WebElement, in html: String) -> String? {
    let id = NSRegularExpression.escapedPattern(for: element.builderId)
    let regex = try! NSRegularExpression(pattern: "<[A-Za-z0-9]+ class=\"\(id)(?: [^\"]*)?\"[^>]*>")
    let ns = html as NSString
    guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return ns.substring(with: match.range)
}

/// The class tokens of a start tag.
func phase1UnwindClasses(_ tag: String) -> [String] {
    return phase1UnwindAttribute("class", in: tag)?.split(separator: " ").map(String.init) ?? []
}

/// The value of attribute `name` in a start tag (`nil` when absent).
func phase1UnwindAttribute(_ name: String, in tag: String) -> String? {
    let regex = try! NSRegularExpression(pattern: "\\s\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*\"([^\"]*)\"")
    let ns = tag as NSString
    guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return ns.substring(with: match.range(at: 1))
}

/// Start tags in `html` whose class list contains `token`.
func phase1UnwindTags(withClass token: String, in html: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: "<[A-Za-z0-9]+ [^>]*class=\"[^\"]*\"[^>]*>")
    let ns = html as NSString
    return regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range) }
        .filter { phase1UnwindClasses($0).contains(token) }
}

// MARK: - Accordion

/// The state an accordion item is rendered in: (button classes, aria-expanded, panel classes).
func phase1UnwindAccordionItemState(_ item: WebElement, in html: String) throws -> (button: [String], expanded: String?, panel: [String]) {
    let subtree = try #require(phase1BuilderSubtree(containing: "class=\"\(item.builderId) accordion-item", in: html))
    let button = try #require(phase1UnwindTags(withClass: "accordion-button", in: subtree).first)
    let panel = try #require(phase1UnwindTags(withClass: "accordion-collapse", in: subtree).first)
    return (phase1UnwindClasses(button), phase1UnwindAttribute("aria-expanded", in: button), phase1UnwindClasses(panel))
}

/// Records an issue unless `item` is rendered open (`open`) or closed, in Bootstrap 5.3's markup.
func phase1UnwindExpectItem(_ item: WebElement, open: Bool, in html: String, _ label: String,
                            sourceLocation: SourceLocation = #_sourceLocation) throws {
    let state = try phase1UnwindAccordionItemState(item, in: html)
    #expect(state.button.contains("accordion-button"), "\(label)", sourceLocation: sourceLocation)
    #expect(state.button.contains("collapsed") == !open, "\(label): button classes \(state.button)", sourceLocation: sourceLocation)
    #expect(state.button.filter { $0 == "collapsed" }.count <= 1, "\(label): \(state.button)", sourceLocation: sourceLocation)
    #expect(state.expanded == (open ? "true" : "false"), "\(label): aria-expanded=\(state.expanded ?? "nil")", sourceLocation: sourceLocation)
    #expect(state.panel.contains("show") == open, "\(label): panel classes \(state.panel)", sourceLocation: sourceLocation)
    #expect(state.panel.filter { $0 == "show" }.count <= 1, "\(label): \(state.panel)", sourceLocation: sourceLocation)
}

@Suite("Phase 1 unwind: Accordion")
struct Phase1UnwindAccordionTests {

    @Test func itemIdsAreDerivedFromBuilderIds() throws {
        let box = Phase1UnwindBox()
        let html = renderHTML { page in
            let first = page.AccordionItem(title: "orphan") {}   // outside any accordion: reported
            var items: [WebElement] = []
            let accordion = page.Accordion {
                items.append(page.AccordionItem(title: "One") { page.Text("1") })
                items.append(page.AccordionItem(title: "Two") { page.Text("2") })
            }
            box.elements = [accordion, first] + items
        }
        let accordion = try #require(box.elements.first)
        let orphan = box.elements[1]
        for item in box.elements.dropFirst(2) {
            let itemId = "\(accordion.builderId)-item-\(item.builderId)"
            #expect(html.contains("id=\"\(itemId)\""), "\(html)")
            #expect(html.contains("id=\"\(itemId)-header\""))
            #expect(html.contains("data-bs-target=\"#\(itemId)\""))
            #expect(html.contains("aria-controls=\"\(itemId)\""))
            #expect(html.contains("aria-labelledby=\"\(itemId)-header\""))
        }
        #expect(html.contains("id=\"wsui-accordion-item-\(orphan.builderId)\""))
        // nothing random is left in the ids (they used to end in 8 random UUID characters)
        #expect(ScriptScan.matches(of: "-item-[0-9A-F]{8}\"", in: html.replacingOccurrences(of: accordion.builderId, with: "")) == 0)
    }

    @Test func expandFirstRendersTheFirstItemOpen() throws {
        let box = Phase1UnwindBox()
        let html = renderHTML { page in
            var items: [WebElement] = []
            page.Accordion {
                items.append(page.AccordionItem(title: "One") { page.Text("1") })
                items.append(page.AccordionItem(title: "Two") { page.Text("2") })
                items.append(page.AccordionItem(title: "Three") { page.Text("3") })
            }.expandFirst(true)
            box.elements = items
        }
        try phase1UnwindExpectItem(box.elements[0], open: true, in: html, "first item")
        try phase1UnwindExpectItem(box.elements[1], open: false, in: html, "second item")
        try phase1UnwindExpectItem(box.elements[2], open: false, in: html, "third item")
        // rendered open, not opened by a script after load (which left the button marked collapsed)
        #expect(html.contains("classList.toggle('show'") == false)
        #expect(html.contains("data-wsui-misuse") == false)
    }

    @Test func expandItemCountsTheAccordionsOwnItemsThroughWrappers() throws {
        let box = Phase1UnwindBox()
        let html = renderHTML { page in
            var items: [WebElement] = []
            var nested: [WebElement] = []
            page.Accordion {
                items.append(page.AccordionItem(title: "A") {})
                page.VStack { items.append(page.AccordionItem(title: "B") {}) }
                items.append(page.AccordionItem(title: "C") {
                    page.Accordion { nested.append(page.AccordionItem(title: "Nested") {}) }
                })
                items.append(page.AccordionItem(title: "D") {})
            }.alwaysOpen(true).expandItem(at: 1).expandItem(at: 3)
            box.elements = items + nested
        }
        try phase1UnwindExpectItem(box.elements[0], open: false, in: html, "A")
        try phase1UnwindExpectItem(box.elements[1], open: true, in: html, "B (inside a VStack)")
        try phase1UnwindExpectItem(box.elements[2], open: false, in: html, "C")
        try phase1UnwindExpectItem(box.elements[3], open: true, in: html, "D (index 3: the nested item is not counted)")
        try phase1UnwindExpectItem(box.elements[4], open: false, in: html, "nested item")
        #expect(html.contains("data-wsui-misuse") == false)
    }

    @Test func collapsingAnOpenItemRestoresTheClosedMarkup() throws {
        let box = Phase1UnwindBox()
        let html = renderHTML { page in
            var items: [WebElement] = []
            page.Accordion {
                items.append(page.AccordionItem(title: "A") {})
                items.append(page.AccordionItem(title: "B") {})
            }.expandFirst(true).expandFirst(true).expandFirst(false).expandItem(at: 1).expandItem(at: 1, expanded: true)
            box.elements = items
        }
        try phase1UnwindExpectItem(box.elements[0], open: false, in: html, "A, opened then closed")
        try phase1UnwindExpectItem(box.elements[1], open: true, in: html, "B, opened twice")
        // the closed button's markup is exactly a never-opened one
        let state = try phase1UnwindAccordionItemState(box.elements[0], in: html)
        #expect(Array(state.button.dropFirst()) == ["accordion-button", "collapsed"])
    }

    @Test func outOfRangeItemIndexIsReportedNotTrapped() throws {
        // `expandItem(at: Int.max)` trapped (`index + 1` overflowed); other bad indexes made the page's script
        // throw (querySelector found nothing). Opening an item past the end of an accordion that has items,
        // or at a negative index, is a mistake in the page and is reported.
        let html = renderHTML { page in
            page.Accordion {
                page.AccordionItem(title: "Only") {}
            }.expandItem(at: 1).expandItem(at: -1).expandItem(at: Int.max)
            page.Accordion {}.expandItem(at: -1)
            page.Text("after the accordions")
        }
        for (index, count) in [("1", 1), ("-1", 1), ("\(Int.max)", 1), ("-1", 0)] {
            let message = "Accordion expandItem(at: \(index)) is out of range: the accordion has \(count) item(s), so no item is expanded or collapsed"
            #expect(html.contains(phase1BuilderMisuseMarker(message)), "\(index) of \(count)")
        }
        #expect(ScriptScan.occurrences(of: "data-wsui-misuse", in: html) == 4)
        #expect(phase1UnwindTags(withClass: "show", in: html).isEmpty)
        #expect(html.contains("after the accordions"))
    }

    @Test func emptyAccordionsAndClosingAMissingItemAreSilent() throws {
        // An accordion built from an empty list is a normal page, not a builder mistake: expanding its first
        // item does nothing and reports nothing. Closing an item that doesn't exist does nothing either (it
        // is already closed), whatever the index.
        let box = Phase1UnwindBox()
        let faqs: [String] = []
        let html = renderHTML { page in
            page.Accordion {
                for faq in faqs { page.AccordionItem(title: faq) {} }
            }.expandFirst(true)
            page.Accordion {}.expandFirst(false).expandItem(at: 3).expandItem(at: Int.max)
            var items: [WebElement] = []
            page.Accordion {
                items.append(page.AccordionItem(title: "A") {})
                items.append(page.AccordionItem(title: "B") {})
            }.expandFirst(true).expandItem(at: 2, expanded: false).expandItem(at: -1, expanded: false)
                .expandItem(at: Int.max, expanded: false)
            box.elements = items
            page.Text("after the accordions")
        }
        #expect(html.contains("data-wsui-misuse") == false, "\(html)")
        // the valid request still applies, and the silent ones change nothing
        try phase1UnwindExpectItem(box.elements[0], open: true, in: html, "A")
        try phase1UnwindExpectItem(box.elements[1], open: false, in: html, "B")
        #expect(phase1UnwindTags(withClass: "wsui-accordion", in: html).count == 3)
        #expect(html.contains("after the accordions"))
    }
}

// MARK: - OffCanvas

@Suite("Phase 1 unwind: OffCanvas")
struct Phase1UnwindOffCanvasTests {

    @Test func footerIsPinnedWithBootstrapUtilities() throws {
        // Bootstrap 5.3.8 has no `offcanvas-footer`; the footer is made of utilities it does define.
        let box = Phase1UnwindBox()
        let html = renderHTML { page in
            var parts: [WebElement] = []
            let panel = page.OffCanvas(id: "panel") {
                parts.append(page.OffCanvasBody { page.Text("body") })
                parts.append(page.OffCanvasFooter { page.Button("Done") })
            }
            box.elements = [panel] + parts
        }
        let panel = try #require(box.elements.first)
        let footer = box.elements[2]
        let tag = try #require(phase1UnwindStartTag(of: footer, in: html))
        #expect(phase1UnwindClasses(tag) == [footer.builderId, "wsui-offcanvas-footer", "mt-auto", "flex-shrink-0", "p-3", "border-top"])
        #expect(phase1UnwindClasses(tag).contains("offcanvas-footer") == false)
        // a direct child of the panel (a flex column), after the body, so mt-auto pins it to the bottom
        #expect(panel.subElements.map(\.builderId) == [box.elements[1].builderId, footer.builderId])
        // classFooter() is the modifier that applies them
        let element = WebOffCanvasFooterElement().classFooter()
        let classes = element.attributes.compactMap { attribute -> String? in
            if case .class(let name) = attribute { return name }
            return nil
        }
        #expect(classes == ["wsui-offcanvas-footer", "mt-auto", "flex-shrink-0", "p-3", "border-top"])
    }

    @Test func closeButtonDoesNotSubmitAForm() throws {
        let html = renderHTML { page in
            page.Form(action: "/save") {
                page.OffCanvas(id: "in-form") {
                    page.OffCanvasHeader { page.OffCanvasTitle { page.Text("Edit") } }
                }
            }
        }
        let close = try #require(phase1UnwindTags(withClass: "btn-close", in: html).first)
        #expect(phase1UnwindAttribute("type", in: close) == "button", "\(close)")
    }

    @Test func panelIsLabelledByItsTitle() throws {
        let box = Phase1UnwindBox()
        let html = renderHTML { page in
            var titles: [WebElement] = []
            let titled = page.OffCanvas(id: "titled") {
                page.OffCanvasHeader { titles.append(page.OffCanvasTitle { page.Text("Settings") }) }
                page.OffCanvasBody { page.OffCanvasHeader { titles.append(page.OffCanvasTitle { page.Text("second") }) } }
            }
            let ownId = page.OffCanvas(id: "own") {
                page.OffCanvasHeader { titles.append(page.OffCanvasTitle { page.Text("Mine") }.id("my-title")) }
            }
            let untitled = page.OffCanvas(id: "untitled") {
                page.OffCanvasBody { page.Text("no title") }
            }
            box.elements = [titled, ownId, untitled] + titles
        }
        let (titled, ownId, untitled) = (box.elements[0], box.elements[1], box.elements[2])
        let (first, second, mine) = (box.elements[3], box.elements[4], box.elements[5])
        let titledTag = try #require(phase1UnwindStartTag(of: titled, in: html))
        let firstTag = try #require(phase1UnwindStartTag(of: first, in: html))
        let secondTag = try #require(phase1UnwindStartTag(of: second, in: html))
        let mineTag = try #require(phase1UnwindStartTag(of: mine, in: html))
        let ownIdTag = try #require(phase1UnwindStartTag(of: ownId, in: html))
        let untitledTag = try #require(phase1UnwindStartTag(of: untitled, in: html))
        // the first title gets the id the panel's aria-labelledby names; a second title gets none
        #expect(phase1UnwindAttribute("aria-labelledby", in: titledTag) == "titledLabel")
        #expect(phase1UnwindAttribute("id", in: firstTag) == "titledLabel")
        #expect(phase1UnwindAttribute("id", in: secondTag) == nil)
        // a title with its own id keeps it, and the panel points at it
        #expect(phase1UnwindAttribute("id", in: mineTag) == "my-title")
        #expect(ScriptScan.occurrences(of: " id=", in: mineTag) == 1, "\(mineTag)")
        #expect(phase1UnwindAttribute("aria-labelledby", in: ownIdTag) == "my-title")
        // without a title there is nothing to name
        #expect(phase1UnwindAttribute("aria-labelledby", in: untitledTag) == nil)
        #expect(html.contains("untitledLabel") == false)
    }
}

// MARK: - Other objects

@Suite("Phase 1 unwind: object markup")
struct Phase1UnwindObjectMarkupTests {

    @Test func fileUploaderProgressBarIsInsideItsTrack() throws {
        // The bar used to be created next to the `.progress` track, so the track stayed empty and the bar
        // was drawn below it.
        let box = Phase1UnwindBox()
        let html = renderHTML { page in
            box.elements = [page.FileUploader(action: "/upload") { page.Text("Drop files") }]
        }
        let uploader = try #require(box.elements.first)
        let track = try #require(phase1BuilderSubtree(containing: "id=\"progress_\(uploader.builderId)\"", in: html))
        #expect(track.contains("id=\"progressbar_\(uploader.builderId)\""), "\(track)")
        #expect(phase1UnwindTags(withClass: "progress-bar", in: track).count == 1)
        let trackElement = try #require(Phase1UnwindNormalizer.elements(under: uploader).first { element in
            element.attributes.contains { if case .pair("id", "progress_\(uploader.builderId)") = $0 { return true }; return false }
        })
        #expect(trackElement.subElements.count == 1)
    }

    @Test func disabledListGroupItemGetsBootstrapsDisabledMarkup() throws {
        // `ListGroupItem(..., disabled: true)` called WebElement's disabled(), which only added a `disabled`
        // attribute (meaningless on an <li>) and not the `.disabled` class.
        let box = Phase1UnwindBox()
        let html = renderHTML { page in
            page.ListGroup {
                box.elements = [page.ListGroupItem("off", disabled: true), page.ListGroupItem("on")]
            }
        }
        let off = try #require(phase1UnwindStartTag(of: box.elements[0], in: html))
        #expect(phase1UnwindClasses(off).contains("disabled"), "\(off)")
        #expect(phase1UnwindAttribute("aria-disabled", in: off) == "true")
        #expect(off.hasSuffix(" disabled>") == false, "\(off)")
        let on = try #require(phase1UnwindStartTag(of: box.elements[1], in: html))
        #expect(phase1UnwindClasses(on).contains("disabled") == false)
    }

    @Test func spinnerSizesAndTypesUseClassesBootstrapDefines() throws {
        let box = Phase1UnwindBox()
        let html = renderHTML { page in
            box.elements = [
                page.Spinner().size(.large),
                page.Spinner().size(.medium),
                page.Spinner().size(.small),
                page.Spinner().type(.grow),
                page.Spinner().type(.grow).size(.small),
                page.Spinner().size(.small).type(.grow),
                page.Spinner().type(.border).size(.large).size(.medium),
            ]
        }
        let tags = try box.elements.map { try #require(phase1UnwindStartTag(of: $0, in: html)) }
        let classes = tags.map { Array(phase1UnwindClasses($0).dropFirst()) }
        // .large: Bootstrap has no spinner-border-lg; its documented custom size is 3rem
        #expect(classes[0] == ["spinner-border", "wsui-spinner"])
        #expect(phase1UnwindAttribute("style", in: tags[0]) == "width: 3rem; height: 3rem")
        // .medium: no empty class token
        #expect(classes[1] == ["spinner-border", "wsui-spinner"])
        #expect(tags[1].contains("  ") == false && tags[1].contains(" \"") == false, "\(tags[1])")
        #expect(classes[2] == ["spinner-border", "wsui-spinner", "spinner-border-sm"])
        // .grow replaces .border (both drew a growing ring), and the small class follows the type
        #expect(classes[3] == ["spinner-grow", "wsui-spinner"])
        #expect(classes[4] == ["spinner-grow", "wsui-spinner", "spinner-grow-sm"])
        #expect(classes[5] == ["spinner-grow", "wsui-spinner", "spinner-grow-sm"])
        #expect(classes[6] == ["spinner-border", "wsui-spinner"])
        #expect(phase1UnwindAttribute("style", in: tags[6]) == nil)
        #expect(html.contains("spinner-border-lg") == false)
    }

    @Test func largeSpinnerSizeIsOnlyAnInlineWidthAndHeight() throws {
        // A large spinner's size is the inline `width` and `height` Bootstrap documents, as their own
        // declarations next to any other style, and nothing else (no class, no custom property). So a
        // client-side resize only has to clear `style.width` and `style.height` to give the size back to
        // Bootstrap's classes. The `.spinnerSet` action doesn't do that yet (Actions.swift), so until it
        // does, it can't shrink a spinner built with `.size(.large)`.
        let box = Phase1UnwindBox()
        let html = renderHTML { page in
            box.elements = [
                page.Spinner().style("color: red").size(.large),
                page.Spinner().size(.large).style("color: red"),
                page.Spinner().size(.large).size(.small).style("color: red"),
            ]
        }
        let tags = try box.elements.map { try #require(phase1UnwindStartTag(of: $0, in: html)) }
        #expect(phase1UnwindAttribute("style", in: tags[0]) == "color: red;width: 3rem; height: 3rem")
        #expect(phase1UnwindAttribute("style", in: tags[1]) == "width: 3rem; height: 3rem;color: red")
        #expect(phase1UnwindAttribute("style", in: tags[2]) == "color: red")
        #expect(Array(phase1UnwindClasses(tags[1]).dropFirst()) == ["spinner-border", "wsui-spinner"])
        #expect(Array(phase1UnwindClasses(tags[2]).dropFirst()) == ["spinner-border", "wsui-spinner", "spinner-border-sm"])
        #expect(html.contains("--bs-spinner") == false)
    }

    @Test func bootstrap4LeftoverClassesAreGone() {
        // `jumbotron` and `btn-group-toggle` are Bootstrap 4 classes that 5.3.8 does not define, and
        // `breadcrumb-container` never existed; each had a wsui-* hook next to it.
        let html = renderHTML { page in
            page.Jumbotron { page.JumbotronTitle("Hello") }
            page.Breadcrumb { page.BreadcrumbItem(title: "Home", url: "/") }
            page.Picker("Seg", selection: page.WString("a"), style: .segmented(.primary)) { page.Text("A").value("a") }
        }
        for gone in ["jumbotron", "btn-group-toggle", "breadcrumb-container"] {
            #expect(phase1UnwindTags(withClass: gone, in: html).isEmpty, "\(gone)")
        }
        #expect(phase1UnwindTags(withClass: "wsui-jumbotron", in: html).count == 1)
        #expect(phase1UnwindTags(withClass: "p-5", in: html).count == 1)
        #expect(phase1UnwindTags(withClass: "wsui-breadcrumb", in: html).count == 1)
        #expect(phase1UnwindTags(withClass: "btn-group", in: html).count == 1)
    }

    @Test func jumbotronBackgroundURLStaysInsideItsCSSString() throws {
        // bgImageURL was written as url('<url>'), so a quote in the URL closed the string and the rest of
        // the URL became CSS declarations.
        let box = Phase1UnwindBox()
        let html = renderHTML { page in
            box.elements = [page.Jumbotron(bgImageURL: "/hero.png'); color: red; background: url('https://evil.example/x") {
                page.JumbotronTitle("Hello")
            }]
        }
        let jumbotron = try #require(box.elements.first)
        let tag = try #require(phase1UnwindStartTag(of: jumbotron, in: html))
        let style = try #require(phase1UnwindAttribute("style", in: tag))
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
        #expect(style == "background-image: url(\"/hero.png'); color: red; background: url('https://evil.example/x\");background-size: cover", "\(style)")
    }

    @Test func navbarColourSchemeUsesClassesBootstrapDefines() {
        // Bootstrap 5.3.8 navbars are light by default and define no `navbar-light`; `navbar-dark` still works.
        let html = renderHTML { page in
            page.NavBar(brand: "light") {}
            page.NavBar(brand: "dark", color: .dark, bg: .dark) {}
        }
        #expect(phase1UnwindTags(withClass: "navbar-light", in: html).isEmpty)
        #expect(phase1UnwindTags(withClass: "navbar", in: html).count == 2)
        #expect(phase1UnwindTags(withClass: "navbar-dark", in: html).count == 1)
        #expect(phase1UnwindTags(withClass: "bg-light", in: html).count == 1)
    }

    @Test func labelTextAlignUsesBootstrap5Classes() {
        func classes(_ element: WebElement) -> [String] {
            element.attributes.compactMap { attribute -> String? in
                if case .class(let name) = attribute { return name }
                return nil
            }
        }
        #expect(classes(WebLabelElement().textAlign("left")) == ["text-start"])
        #expect(classes(WebLabelElement().textAlign("right")) == ["text-end"])
        #expect(classes(WebLabelElement().textAlign("center")) == ["text-center"])
        #expect(classes(WebLabelElement().textAlign("justify")).isEmpty)
    }

    @Test func colorPickerIsReportedAndItsVariableStillSubmits() throws {
        // `.colorPicker` renders nothing; it used to drop its content silently and also took the field away
        // from the variable's hidden input, so the value was not submitted at all.
        let box = Phase1UnwindBox()
        let html = renderHTML { page in
            page.Form(action: "/colour") {
                let colour = page.WString("#ff0000").name("colour")
                box.elements = [colour]
                page.Picker("Colour", selection: colour, style: .color) { page.Text("never rendered") }
            }
        }
        #expect(html.contains(phase1BuilderMisuseMarker("Picker type .colorPicker (style .color) is not implemented: the picker and its content are not rendered")))
        #expect(html.contains("never rendered") == false)
        let colour = try #require(box.elements.first)
        let carrier = try #require(phase1UnwindStartTag(of: colour, in: html))
        #expect(phase1UnwindAttribute("name", in: carrier) == "colour", "\(carrier)")
        #expect(phase1UnwindAttribute("value", in: carrier) == "#ff0000")
    }

    @Test func reloadImageNeverTraps() throws {
        // `Int(seconds * 1000)` trapped for NaN, infinity and huge values. Intervals are now clamped to what
        // setInterval holds (2^31 - 1 ms; a longer delay fires after 1 ms), and NaN is reported.
        let cases: [(seconds: Double, interval: String?)] = [
            (5, "5000"), (0.25, "250"), (0, "100"), (-3, "100"), (-.infinity, "100"),
            (.infinity, "2147483647"), (1e300, "2147483647"), (3_000_000, "2147483647"), (.nan, nil),
        ]
        for testCase in cases {
            let box = Phase1UnwindBox()
            let html = renderHTML { page in
                box.elements = [page.Image("/cam.jpg").reloadImage(seconds: testCase.seconds)]
                page.Text("after the image")
            }
            #expect(html.contains("after the image"), "\(testCase.seconds)")
            if let interval = testCase.interval {
                #expect(html.contains("setInterval(reload, \(interval));"), "\(testCase.seconds)")
                #expect(html.contains("data-wsui-misuse") == false)
            } else {
                #expect(html.contains("setInterval(reload") == false)
                #expect(html.contains(phase1BuilderMisuseMarker("reloadImage(seconds:) needs a number of seconds (got NaN); the image is not reloaded")))
            }
        }
    }

    @Test func chartAndUploaderJSONIsTheSameEveryTime() {
        // JSONEncoder's key order changed between encodings, so the same chart (and the same extra upload
        // fields) produced a different page each time.
        func render() -> String {
            let html = renderHTML { page in
                page.Chart(id: "c", type: .line, labels: ["a"], dataSets: [
                    ChartDataSet(label: "s", values: [1.5]).background("red").border("blue").borderWidth(2).fill().tension(0.3),
                ])
                page.FileUploader(action: "/u", extraFields: ["zeta": "1", "alpha": "2", "mu": "3", "beta": "4"]) {}
            }
            return html
        }
        let first = render()
        #expect(first.contains("[{\"backgroundColor\":\"red\",\"borderColor\":\"blue\",\"borderWidth\":2,\"data\":[1.5],\"fill\":true,\"label\":\"s\",\"tension\":0.3}]"), "\(first)")
        #expect(first.contains("data-extra=\"{&quot;alpha&quot;:&quot;2&quot;,&quot;beta&quot;:&quot;4&quot;,&quot;mu&quot;:&quot;3&quot;,&quot;zeta&quot;:&quot;1&quot;}\""))
        for _ in 0..<5 {
            let again = render()
            #expect(phase1UnwindDataSets(again) == phase1UnwindDataSets(first))
        }
    }
}

/// The `datasets:` line of a rendered chart.
func phase1UnwindDataSets(_ html: String) -> String? {
    return html.components(separatedBy: "\n").first { $0.contains("datasets:") }?.trimmingCharacters(in: .whitespaces)
}

// MARK: - escapedForHTML

/// `escapedForHTML` as it was before this slice (the dictionary was built on every call), kept to prove the
/// cheaper version escapes exactly the same.
func phase1UnwindReferenceEscapedForHTML(_ text: String, preserveLineBreaks: Bool = true) -> String {
    let escapeMap: [Character: String] = [
        "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;", "/": "&#x2F;",
        "\u{A0}": "&nbsp;", "\t": "&#9;", "\r": "<br>", "\n": "<br>",
        "\u{A1}": "&iexcl;", "\u{A2}": "&cent;", "\u{A3}": "&pound;", "\u{A4}": "&curren;", "\u{A5}": "&yen;",
        "\u{A6}": "&brvbar;", "\u{A7}": "&sect;", "\u{A8}": "&uml;", "\u{A9}": "&copy;", "\u{AA}": "&ordf;",
        "\u{AB}": "&laquo;", "\u{AC}": "&not;", "\u{AE}": "&reg;", "\u{AF}": "&macr;", "\u{B0}": "&deg;",
        "\u{B1}": "&plusmn;", "\u{B2}": "&sup2;", "\u{B3}": "&sup3;", "\u{B4}": "&acute;", "\u{B5}": "&micro;",
        "\u{B6}": "&para;", "\u{B7}": "&middot;", "\u{B8}": "&cedil;", "\u{B9}": "&sup1;", "\u{BA}": "&ordm;",
        "\u{BB}": "&raquo;", "\u{BC}": "&frac14;", "\u{BD}": "&frac12;", "\u{BE}": "&frac34;", "\u{BF}": "&iquest;",
        "\u{D7}": "&times;", "\u{F7}": "&divide;", "\u{2030}": "&permil;", "\u{2212}": "&minus;",
        "\u{2013}": "&ndash;", "\u{2014}": "&mdash;", "\u{2022}": "&bull;", "\u{2026}": "&hellip;",
        "\u{2018}": "&lsquo;", "\u{2019}": "&rsquo;", "\u{201A}": "&sbquo;", "\u{201C}": "&ldquo;",
        "\u{201D}": "&rdquo;", "\u{201E}": "&bdquo;", "\u{2039}": "&lsaquo;", "\u{203A}": "&rsaquo;",
        "\u{3B1}": "&alpha;", "\u{3B2}": "&beta;", "\u{3B3}": "&gamma;", "\u{394}": "&Delta;", "\u{3C0}": "&pi;",
        "\u{3C6}": "&phi;", "\u{20AC}": "&euro;",
    ]
    var result = String()
    for c in text {
        if let entity = escapeMap[c] {
            result.append(entity)
        } else if c.unicodeScalars.count > 1 {
            result.append(WebEscape.html(String(c)))
        } else {
            result.append(c)
        }
    }
    if preserveLineBreaks {
        return result.replacingOccurrences(of: "\n", with: "<br>")
    }
    return result
}

@Suite("Phase 1 unwind: escapedForHTML")
struct Phase1UnwindEscapedForHTMLTests {

    @Test func escapesExactlyAsBefore() {
        var corpus: [String] = [
            "", "plain", "a & <b> \"q\" 'a' / end", "line\nbreak", "cr\rlf", "crlf\r\npair", "tab\there",
            "\u{1FFD}\u{0387}", "e\u{0301}<", "\u{0600}<", "\u{1F469}\u{200D}\u{1F4BB} & \u{1F1EC}\u{1F1E7}",
            "price: \u{A3}5 \u{2014} \u{2018}quoted\u{2019} \u{2026}", "<\u{0338} \u{226E}", "\u{FEFF}\u{0000}\u{FFFD}",
            String(repeating: "x <y> & z\n", count: 50),
        ]
        // every code point of the Basic Multilingual Plane (except surrogates) on its own and after "a"
        for value in 0...0xFFFF where (0xD800...0xDFFF).contains(value) == false {
            let scalar = Unicode.Scalar(UInt32(value))!
            corpus.append(String(Character(scalar)))
            corpus.append("a" + String(Character(scalar)) + "\u{0301}")
        }
        var mismatches: [String] = []
        for text in corpus {
            for preserve in [true, false]
            where text.escapedForHTML(preserveLineBreaks: preserve) != phase1UnwindReferenceEscapedForHTML(text, preserveLineBreaks: preserve) {
                mismatches.append(text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(20))")
    }

    @Test func theEntityTableIsNotBuiltOnEveryCall() throws {
        // CORE-26: the 60-entry dictionary was a local of escapedForHTML, so every Text built it again.
        let url = phase1BuilderSourcesRoot.appendingPathComponent("WebUI/objects/Text.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "func escapedForHTML("))
        let body = source[start.lowerBound...].prefix(while: { _ in true })
        let end = try #require(body.range(of: "\n    }\n"))
        let function = String(body[..<end.upperBound])
        #expect(function.contains("[Character: String]") == false, "\(function)")
        #expect(function.contains("\"&amp;\"") == false, "\(function)")
    }
}
