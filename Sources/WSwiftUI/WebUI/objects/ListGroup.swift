//
//  ListGroup.swift
//  SWWebAppServer
//
//  Created by Adrian on 07/07/2025.
//

import Foundation

// 1) Dedicated subclasses for ListGroup container and items
public class WebListGroupElement: WebElement {}
public class WebListGroupItemElement: WebElement {}

// 3) Fluent modifiers for ListGroup container
public extension WebListGroupElement {
    /// Removes borders and rounded corners
    @discardableResult
    func flush(_ on: Bool = true) -> Self {
        if on {
            addAttribute(.class("list-group-flush"))
        }
        return self
    }

    /// Makes list group horizontal
    @discardableResult
    func horizontal(_ on: Bool = true) -> Self {
        if on {
            addAttribute(.class("list-group-horizontal"))
        }
        return self
    }

    /// Use numbered list-group
    @discardableResult
    func numbered(_ on: Bool = true) -> Self {
        if on {
            addAttribute(.class("list-group-numbered"))
        }
        return self
    }
}

// 4) Fluent modifiers for ListGroup items
public extension WebListGroupItemElement {
    /// Applies contextual background (`list-group-item-<variant>`)
    @discardableResult
    func variant(_ variant: BootstrapVariant) -> Self {
        addAttribute(.variant(variant))
        addAttribute(.class("list-group-item-\(variant.rawValue)"))
        return self
    }

    /// Marks item active
    @discardableResult
    func active(_ on: Bool = true) -> Self {
        if on {
            addAttribute(.class("active"))
        }
        return self
    }

    /// Marks item disabled
    @discardableResult
    func disabled(_ on: Bool = true) -> Self {
        if on {
            addAttribute(.class("disabled"))
        }
        return self
    }
}

// 5) DSL factories on BaseWebEndpoint
public extension CoreWebEndpoint {
    /// Creates a <ul class="list-group [flush] [horizontal] [numbered]"> container
    @discardableResult
    func ListGroup(_ content: WebComposerClosure) -> WebListGroupElement {
        let group = WebListGroupElement()
        populateCreatedObject(group)
        group.elementName = "ul"
        group.addAttribute(.class("list-group"))
        group.addAttribute(.class("wsui-list-group"))
        stack.append(group)
        content()
        stack.removeAll(where: { $0.builderId == group.builderId })
        return group
    }

    /// Creates a <li class="list-group-item [variants] [active] [disabled]">title</li>
    @discardableResult
    func ListGroupItem(_ title: String,
                       variant: BootstrapVariant? = nil,
                       active: Bool = false,
                       disabled: Bool = false) -> WebListGroupItemElement {
        guard let _ = stack.last as? WebListGroupElement else {
            fatalError("ListGroupItem must be inside ListGroup { ... } block")
        }
        let item = WebListGroupItemElement()
        populateCreatedObject(item)
        item.elementName = "li"
        item.addAttribute(.class("list-group-item"))
        if let v = variant { item.variant(v) }
        if active { item.active() }
        if disabled { item.disabled() }
        item.innerHTML(WebEscape.html(title))
        return item
    }
}
