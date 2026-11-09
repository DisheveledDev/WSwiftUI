//
//  Accordion.swift
//  SWWebAppServer
//
//  Created by Adrian on 06/07/2025.
//

import Foundation

// 1) Dedicated subclasses for Accordion and AccordionItem
public class WebAccordionElement: WebElement {}
public class WebAccordionItemElement: WebElement {}

// 2) Fluent methods for accordion-specific behaviors
public extension WebAccordionElement {
    /// Keeps all accordion items open at once
    @discardableResult
    func alwaysOpen(_ alwaysOpen: Bool) -> Self {
        addAttribute(.script("\(builderId).classList.toggle('accordion-always-open', \(alwaysOpen));"))
        return self
    }

    /// Expands or collapses the first accordion item
    @discardableResult
    func expandFirst(_ expandFirst: Bool) -> Self {
        addAttribute(.script("document.querySelector('#\(builderId) .accordion-item:first-child .accordion-collapse').classList.toggle('show', \(expandFirst));"))
        return self
    }

    /// Expands or collapses the accordion item at the given index (0-based)
    @discardableResult
    func expandItem(at index: Int, expanded: Bool = true) -> Self {
        // Use nth-child so add 1 to index
        let js = "document.querySelector('#\(builderId) .accordion-item:nth-child(\(index + 1)) .accordion-collapse').classList.toggle('show', \(expanded));"
        addAttribute(.script(js))
        return self
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
        // Outer <div class="accordion" id="...">
        let accordion: WebAccordionElement = create { el in
            el.elementName = "div"
            el.class("accordion")
            el.class("wsui-accordion")
            el.class(el.builderId)
            el.id(el.builderId)
        }
        stack.append(accordion)

        // User adds AccordionItem() calls here
        content()

        // Pop accordion
        stack.removeAll(where: { $0.builderId == accordion.builderId })
        return accordion
    }

    /// Build an accordion item within a parent Accordion
    @discardableResult
    func AccordionItem(title: String, _ body: WebComposerClosure) -> WebAccordionItemElement {
        // Ensure we have a parent accordion on the stack
        guard let parent = stack.last as? WebAccordionElement else {
            fatalError("AccordionItem must be called within an Accordion { ... } block")
        }

        // Unique IDs
        let itemId   = "\(parent.builderId)-item-\(UUID().uuidString.prefix(8))"
        let headerId = "\(itemId)-header"

        // <div class="accordion-item">
        let item = createItem { el in
            el.elementName = "div"
            el.class("accordion-item")
            el.class("wsui-accordion-item")
        }
        stack.append(item)

        // <h2 class="accordion-header" id="...-header">
        let h2 = create { el in
            el.elementName = "h2"
            el.class("accordion-header")
            el.id(headerId)
        }
        stack.append(h2)

        // <button ...>title</button>
        _ = create { el in
            el.elementName = "button"
            el.class("accordion-button collapsed")
            el.type("button")
            el.addAttribute(.custom("data-bs-toggle=\"collapse\""))
            el.addAttribute(.custom("data-bs-target=\"#\(itemId)\""))
            el.addAttribute(.pair("aria-expanded", "false"))
            el.addAttribute(.pair("aria-controls", itemId))
            el.innerHTML(WebEscape.html(title))
        }
        stack.removeAll(where: { $0.builderId == h2.builderId })

        // <div class="accordion-collapse collapse" ...>
        let collapseDiv = create { el in
            el.elementName = "div"
            el.class("accordion-collapse collapse")
            el.id(itemId)
            el.addAttribute(.pair("aria-labelledby", headerId))
            el.addAttribute(.custom("data-bs-parent=\"#\(parent.builderId)\""))
        }
        stack.append(collapseDiv)

        // <div class="accordion-body">…</div>
        _ = create { el in
            el.elementName = "div"
            el.class("accordion-body")
            body()
        }

        // Pop collapseDiv and item
        stack.removeAll(where: { $0.builderId == collapseDiv.builderId })
        stack.removeAll(where: { $0.builderId == item.builderId })
        return item
    }
}
