//
//  Card.swift
//  SWWebAppServer
//
//  Created by Adrian on 07/07/2025.
//

import Foundation

// 1) Dedicated subclasses for Card and its sub-elements
public class WebCardElement: WebElement {}
public class WebCardHeaderElement: WebElement {}
public class WebCardBodyElement: WebElement {}
public class WebCardFooterElement: WebElement {}
public class WebCardImageElement: WebElement {}

// 2) Fluent modifiers for Card container
public extension WebCardElement {
    /// Base Bootstrap card class
    @discardableResult
    func `default`() -> Self {
        addAttribute(.class("card"))
        return self
    }

    /// Adds a border to the card
    @discardableResult
    func bordered() -> Self {
        addAttribute(.class("border"))
        return self
    }

    /// Adds a shadow to the card
    @discardableResult
    func shadow() -> Self {
        addAttribute(.class("shadow"))
        return self
    }

    /// Aligns text inside the card: 'start' (or 'left'), 'center', 'end' (or 'right'), 'justify'.
    /// 'left'/'right' map to Bootstrap 5's `text-start`/`text-end`; other values pass through as `text-<value>`.
    @discardableResult
    func textAlign(_ alignment: String) -> Self {
        applyTextAlignment(alignment)
        return self
    }
}

// 3) Fluent modifiers for Card images
public extension WebCardImageElement {
    /// Makes image responsive (fluid)
    @discardableResult
    func responsive() -> Self {
        addAttribute(.class("img-fluid"))
        return self
    }

    /// Rounds image corners
    @discardableResult
    func rounded() -> Self {
        addAttribute(.class("rounded"))
        return self
    }
}

// 4) DSL factories on BaseWebEndpoint
public extension CoreWebEndpoint {
    // Internal create overload for Card
    fileprivate func createCard(_ `init`: (_ element: WebCardElement) -> Void) -> WebCardElement {
        let element = WebCardElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }

    // Internal create overload for sub-elements
    fileprivate func createCardHeader(_ `init`: (_ element: WebCardHeaderElement) -> Void) -> WebCardHeaderElement {
        let element = WebCardHeaderElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }
    fileprivate func createCardBody(_ `init`: (_ element: WebCardBodyElement) -> Void) -> WebCardBodyElement {
        let element = WebCardBodyElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }
    fileprivate func createCardFooter(_ `init`: (_ element: WebCardFooterElement) -> Void) -> WebCardFooterElement {
        let element = WebCardFooterElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }
    fileprivate func createCardImage(_ `init`: (_ element: WebCardImageElement) -> Void) -> WebCardImageElement {
        let element = WebCardImageElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }

    /// Builds a `<div class="card">…</div>` container
    @discardableResult
    func Card(_ content: WebComposerClosure) -> WebCardElement {
        let card = createCard { el in
            el.elementName = "div"
            el.class("card")
            el.class("wsui-card")
        }
        // (`.bordered()`, `.shadow()` and the other modifiers can be applied to the result)
        return withParent(card, content)
    }

    /// Builds a `<div class="card-header">…</div>`; must be inside a Card (wrapper elements in between are
    /// allowed). Anywhere else the mistake is logged, an HTML comment marks the spot and the header is
    /// rendered where it was declared.
    @discardableResult
    func CardHeader(_ content: WebComposerClosure) -> WebCardHeaderElement {
        requireStructuralParent({ $0 is WebCardElement }, among: isCardPart,
                                "CardHeader must be used inside a Card { ... } block")
        let header = createCardHeader { el in
            el.elementName = "div"
            el.class("card-header")
        }
        return withParent(header, content)
    }

    /// Builds a `<div class="card-body">…</div>`; must be inside a Card (see `CardHeader`)
    @discardableResult
    func CardBody(_ content: WebComposerClosure) -> WebCardBodyElement {
        requireStructuralParent({ $0 is WebCardElement }, among: isCardPart,
                                "CardBody must be used inside a Card { ... } block")
        let body = createCardBody { el in
            el.elementName = "div"
            el.class("card-body")
        }
        return withParent(body, content)
    }

    /// Builds a `<div class="card-footer">…</div>`; must be inside a Card (see `CardHeader`)
    @discardableResult
    func CardFooter(_ content: WebComposerClosure) -> WebCardFooterElement {
        requireStructuralParent({ $0 is WebCardElement }, among: isCardPart,
                                "CardFooter must be used inside a Card { ... } block")
        let footer = createCardFooter { el in
            el.elementName = "div"
            el.class("card-footer")
        }
        return withParent(footer, content)
    }

    /// Builds an image with class="card-img-top"; can be chained with .responsive(), .rounded()
    @discardableResult
    func CardImageTop(src: String, alt: String = "") -> WebCardImageElement {
        let img = createCardImage { el in
            el.elementName = "img"
            el.class("card-img-top")
            el.src(src)
            if !alt.isEmpty { el.alt(alt) }
        }
        return img
    }

    /// Builds an image with class="card-img-bottom"; can be chained with .responsive(), .rounded()
    @discardableResult
    func CardImageBottom(src: String, alt: String = "") -> WebCardImageElement {
        let img = createCardImage { el in
            el.elementName = "img"
            el.class("card-img-bottom")
            el.src(src)
            if !alt.isEmpty { el.alt(alt) }
        }
        return img
    }
}

/// The elements that make up a card's structure. Anything else on the builder stack is a wrapper.
fileprivate func isCardPart(_ element: WebElement) -> Bool {
    return element is WebCardElement
        || element is WebCardHeaderElement
        || element is WebCardBodyElement
        || element is WebCardFooterElement
}
