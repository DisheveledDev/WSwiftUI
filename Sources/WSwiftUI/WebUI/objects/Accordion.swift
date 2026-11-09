//
//  Accordion.swift
//  SWWebAppServer
//
//  Created by Adrian on 06/07/2025.
//

import Foundation

// 1) Dedicated subclasses for Accordion and AccordionItem
public class WebAccordionElement: WebElement {
    /// The endpoint that built the accordion, for reporting misuse found by its modifiers.
    internal weak var builder: CoreWebEndpoint?
}

public class WebAccordionItemElement: WebElement {
    /// The accordion the item belongs to (`nil` for an item declared outside any accordion).
    internal weak var accordion: WebAccordionElement?
    /// The item's header button and its collapsible panel, which `setExpanded(_:)` updates.
    internal weak var toggleButton: WebElement?
    internal weak var collapsePanel: WebElement?

    /// Renders the item open (`expanded`) or closed, the way Bootstrap 5.3 marks it up: an open item's
    /// button has no `collapsed` class and `aria-expanded="true"`, and its panel has `show`; a closed item's
    /// button has `collapsed` and `aria-expanded="false"`, and its panel has no `show`.
    internal func setExpanded(_ expanded: Bool) {
        if let button = toggleButton {
            let isCollapsedClass: (WebCoreElementAttribute) -> Bool = { attribute in
                if case .class(let name) = attribute { return name == "collapsed" }
                return false
            }
            if expanded {
                button.attributes.removeAll(where: isCollapsedClass)
            } else if button.attributes.contains(where: isCollapsedClass) == false {
                // right after the accordion-button class, where a new item has it
                let index = button.attributes.firstIndex(where: { attribute in
                    if case .class(let name) = attribute { return name == "accordion-button" }
                    return false
                }).map { $0 + 1 } ?? button.attributes.count
                button.attributes.insert(.class("collapsed"), at: index)
            }
            button.attributes = button.attributes.map { attribute in
                if case .pair(let name, _) = attribute, name == "aria-expanded" {
                    return .pair("aria-expanded", expanded ? "true" : "false")
                }
                return attribute
            }
        }
        if let panel = collapsePanel {
            panel.attributes.removeAll { attribute in
                if case .class(let name) = attribute { return name == "show" }
                return false
            }
            if expanded {
                panel.addAttribute(.class("show"))
            }
        }
    }
}

// 2) Fluent methods for accordion-specific behaviors
public extension WebAccordionElement {
    /// Keeps all accordion items open at once: opening one item no longer closes the others.
    ///
    /// Bootstrap's "always open" accordion is an accordion whose items have no `data-bs-parent`, so this
    /// removes the `data-bs-parent` pointing at this accordion from the items already declared in it
    /// (call it on the result, `Accordion { ... }.alwaysOpen(true)`). Items of nested accordions keep theirs.
    /// `false` keeps the default behaviour (one item open at a time).
    @discardableResult
    func alwaysOpen(_ alwaysOpen: Bool) -> Self {
        guard alwaysOpen else { return self }
        let parentAttribute = "data-bs-parent=\"#\(builderId)\""
        func removeParent(from element: WebElement) {
            element.attributes.removeAll { attribute in
                if case .custom(let raw) = attribute { return raw == parentAttribute }
                return false
            }
            element.subElements.forEach(removeParent(from:))
        }
        subElements.forEach(removeParent(from:))
        return self
    }

    /// Renders the first item of the accordion open (`true`) or closed (`false`); see
    /// `expandItem(at:expanded:)`. On an accordion without items it does nothing (and reports nothing).
    @discardableResult
    func expandFirst(_ expandFirst: Bool) -> Self {
        return expandItem(at: 0, expanded: expandFirst)
    }

    /// Renders the item at `index` open (`expanded`, the default) or closed. Items are counted from 0 in
    /// the order they were declared in this accordion, through any wrappers; items of nested accordions
    /// don't count.
    ///
    /// The page is rendered with Bootstrap's markup for an open item (its panel has `show`, its button has
    /// `aria-expanded="true"` and no `collapsed` class), so it shows open before any script runs and the
    /// first click closes it. Several items can be opened this way, also in an accordion that isn't
    /// `alwaysOpen`.
    ///
    /// An index with no item changes nothing. Closing it (`expanded: false`) is silent, because an item
    /// that doesn't exist is already closed. Opening an item of an accordion that has no items is silent
    /// too: an accordion built from an empty list is a normal page. Opening a negative index, or an index
    /// past the last item of an accordion that has items, is reported as builder misuse.
    @discardableResult
    func expandItem(at index: Int, expanded: Bool = true) -> Self {
        let items = ownItems()
        guard items.indices.contains(index) else {
            if expanded && (index < 0 || items.isEmpty == false) {
                builder?.misuse("Accordion expandItem(at: \(index)) is out of range: the accordion has \(items.count) item(s), so no item is expanded or collapsed")
            }
            return self
        }
        items[index].setExpanded(expanded)
        return self
    }

    /// This accordion's items in document order, looking through wrappers but not into nested accordions.
    internal func ownItems() -> [WebAccordionItemElement] {
        var items: [WebAccordionItemElement] = []
        func visit(_ element: WebElement) {
            if let item = element as? WebAccordionItemElement, item.accordion === self {
                items.append(item)
            }
            if element is WebAccordionElement { return }
            element.subElements.forEach(visit)
        }
        subElements.forEach(visit)
        return items
    }
}

// 3) Builder types (DSL via AccordionItem)
public enum AccordionElement {} // no longer used

public extension CoreWebEndpoint {
    /// Internal create overload for accordions
    fileprivate func create(_ `init`: (_ element: WebAccordionElement) -> Void) -> WebAccordionElement {
        let element = WebAccordionElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }

    /// Internal create overload for accordion items
    fileprivate func createItem(_ `init`: (_ element: WebAccordionItemElement) -> Void) -> WebAccordionItemElement {
        let element = WebAccordionItemElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }

    /// Build a Bootstrap accordion using DSL
    @discardableResult
    func Accordion(_ content: WebComposerClosure) -> WebAccordionElement {
        // Outer <div class="accordion" id="..."> (its builderId class comes from populateCreatedObject)
        let accordion: WebAccordionElement = create { el in
            el.elementName = "div"
            el.class("accordion")
            el.class("wsui-accordion")
            el.id(el.builderId)
            el.builder = self
        }
        // User adds AccordionItem() calls here
        return withParent(accordion, content)
    }

    /// Internal create overload for the plain elements inside an accordion item (header, button, collapse
    /// and body). They are plain `WebElement`s, never `WebAccordionElement`s, so an item's own parts are
    /// never mistaken for the accordion it belongs to.
    fileprivate func createPart(_ `init`: (_ element: WebElement) -> Void) -> WebElement {
        let element = WebElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }

    /// Build an accordion item within a parent Accordion. Wrapper elements between the Accordion and the
    /// item are allowed. Anywhere else the mistake is logged, an HTML comment marks the spot and the item
    /// is rendered where it was declared (without a `data-bs-parent`).
    /// The content of `body` is placed inside the item's `<div class="accordion-body">`. The item is
    /// rendered closed; `expandFirst(_:)` / `expandItem(at:expanded:)` on the accordion open it.
    @discardableResult
    func AccordionItem(title: String, _ body: WebComposerClosure) -> WebAccordionItemElement {
        // The accordion this item belongs to
        let parent = requireStructuralParent({ $0 is WebAccordionElement }, among: isAccordionPart,
                                             "AccordionItem must be called within an Accordion { ... } block")

        // <div class="accordion-item">
        let item = createItem { el in
            el.elementName = "div"
            el.class("accordion-item")
            el.class("wsui-accordion-item")
        }
        item.accordion = parent as? WebAccordionElement

        // Ids derived from the builderIds of the accordion and the item, so they are unique in the page and
        // as stable as the builderIds (they used to end in random characters).
        let itemId   = "\(parent?.builderId ?? "wsui-accordion")-item-\(item.builderId)"
        let headerId = "\(itemId)-header"

        return withParent(item) {
            // <h2 class="accordion-header" id="...-header">
            let h2 = createPart { el in
                el.elementName = "h2"
                el.class("accordion-header")
                el.id(headerId)
            }
            withParent(h2) {
                // <button ...>title</button>, closed until expandFirst/expandItem opens it
                item.toggleButton = createPart { el in
                    el.elementName = "button"
                    el.class("accordion-button")
                    el.class("collapsed")
                    el.type("button")
                    el.addAttribute(.custom("data-bs-toggle=\"collapse\""))
                    el.addAttribute(.custom("data-bs-target=\"#\(itemId)\""))
                    el.addAttribute(.pair("aria-expanded", "false"))
                    el.addAttribute(.pair("aria-controls", itemId))
                    el.innerHTML(WebEscape.html(title))
                }
            }

            // <div class="accordion-collapse collapse" ...>
            let collapseDiv = createPart { el in
                el.elementName = "div"
                el.class("accordion-collapse collapse")
                el.id(itemId)
                el.addAttribute(.pair("aria-labelledby", headerId))
                if let parent {
                    el.addAttribute(.custom("data-bs-parent=\"#\(parent.builderId)\""))
                }
            }
            item.collapsePanel = collapseDiv
            withParent(collapseDiv) {
                // <div class="accordion-body">…</div>
                let bodyDiv = createPart { el in
                    el.elementName = "div"
                    el.class("accordion-body")
                }
                withParent(bodyDiv, body)
            }
        }
    }
}

/// The elements that make up an accordion's structure. Anything else on the builder stack is a wrapper.
fileprivate func isAccordionPart(_ element: WebElement) -> Bool {
    return element is WebAccordionElement || element is WebAccordionItemElement
}
